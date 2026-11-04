#!/usr/bin/env python3
"""QA Factory oracle command-hook adapter for Autonomous Test Discovery.

QA Factory's existing ``hooks.command_hook`` launches an allowlisted absolute executable with a
scrubbed environment (PATH, LANG, HOME, TMPDIR + declared secret envs), writes ONE bounded JSON document
(<= 64 KiB) to stdin and expects ONE bounded JSON object (<= 64 KiB) on stdout whose ``namespace`` equals
the request's. This executable is that hook. Register it as a hook with ``purpose: "oracle"``::

    {"name": "atd-discovery", "purpose": "oracle",
     "command": ["/abs/path/eval-harness/integrations/qa-factory/discovery.py",
                 "--config", "/abs/path/qa-discovery.config.json"]}

Request (stdin)  : {"namespace": str, "operation_id": str, "oracle_id": <profile name>,
                    "base": <commit-ish, optional>, "candidate": <commit-ish, optional>}
Everything else (repository, spec, dependencies, model limits, trust inputs) comes from the trusted
``--config`` file; the request can only select a configured profile and two commit-ish values.

Result (stdout)  : {"namespace", "operation_id", "oracle_id", "status", "verdict", "classification",
                    "reviewRequired", "reviewReasons", "findings", "recommendations", "errors",
                    "counts", "evidence", "note", ...}
  verdict        : QA Factory's Verdict vocabulary. FAIL only with a CONFIRMED_DEFECT; PASS only when generated
                   tests ran and none produced a finding, a non-PASS status or an unverifiable case;
                   INCONCLUSIVE for suspected, inconclusive, unverifiable or erroring runs; NOT_RUN when nothing
                   was executed.
  classification : Findings are NEVER taken from results.json. Every finding/non-PASS case is replayed through the
                   existing grade.sh on its preserved grading manifest (repair-request.mjs). CONFIRMED_DEFECT needs
                   a RECOMPUTED VERIFIED_REGRESSION (signed, 3 fresh stable sandbox executions, spec support) from
                   an independent signer (ci-secret or separate-user; provide ATD_TRUST, ATD_SIGNING_KEY_FILE and
                   ATD_ALLOWED_SIGNERS_FILE through the campaign's secret_envs and the config's passEnv). A
                   local-same-user VERIFIED finding is reporting-only: it is SUSPECTED_DEFECT with
                   reviewRequired. A case that cannot be replayed, or whose raw result disagrees with the replay,
                   is INCONCLUSIVE with a review reason. The raw discovery class stays visible separately
                   (rawDiscoveryClassification / counts.byRawDiscoveryClassification).

The hook is synchronous: it blocks until the pipeline finishes, so the campaign's
``budgets.hook_seconds`` must exceed the pipeline runtime (it is configurable; QA's default is 30s). If
the pipeline exceeds the adapter's own ``timeoutSeconds`` the whole process group receives SIGTERM (the
sandbox runner force-removes its containers on SIGTERM) and, after a grace period, SIGKILL; the result is
then an honest INCONCLUSIVE error, and everything already written under the operation directory is kept.
Operations are idempotent per ``operation_id``: a repeated call returns the stored result without a new
pipeline round. No QA database or framework is duplicated; evidence stays under the configured
``outputRoot``.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
from collections import deque
from pathlib import Path

MAX_INPUT = 65536
MAX_OUTPUT = 60000  # leave room under QA's 65536-byte output boundary
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
SAFE_REF = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/@~^{}+-]{0,199}$")
BASE_ENV = ("PATH", "LANG", "HOME", "TMPDIR")
FORWARDABLE_ENV = {
    "ATD_TRUST", "ATD_SIGNING_KEY_FILE", "ATD_ALLOWED_SIGNERS_FILE", "DOCKER_HOST", "DOCKER_CONFIG",
    "PI_CODING_AGENT_DIR", "OMP_PROFILE", "ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN",
}
QA_CLASSIFICATION = {"VERIFIED_REGRESSION": "CONFIRMED_DEFECT", "SUSPECTED_REGRESSION": "SUSPECTED_DEFECT"}
ERROR_STATUSES = {"harness_error", "preflight_failed", "generation_failed", "usage_error"}
INDEPENDENT_TRUST = {"ci-secret", "separate-user"}


class ProtocolError(Exception):
    """The request or configuration is invalid; the hook exits non-zero (QA reports 'Hook failed')."""


def _abs(value: object, label: str, *, must_exist: bool = True, directory: bool | None = None) -> Path:
    if not isinstance(value, str) or not value or "\0" in value or not os.path.isabs(value):
        raise ProtocolError(f"config {label} must be an absolute path")
    path = Path(value)
    if must_exist and not path.exists():
        raise ProtocolError(f"config {label} does not exist: {value}")
    if directory is True and must_exist and not path.is_dir():
        raise ProtocolError(f"config {label} must be a directory")
    if directory is False and must_exist and not path.is_file():
        raise ProtocolError(f"config {label} must be a file")
    return path


def load_config(path: str) -> dict:
    try:
        raw = Path(path).read_bytes()
    except OSError as error:
        raise ProtocolError(f"cannot read config: {error}") from error
    if len(raw) > 262144:
        raise ProtocolError("config exceeds size bound")
    config = json.loads(raw)
    if not isinstance(config, dict) or config.get("schema") != "atd.qa-hook-config/v1":
        raise ProtocolError("config schema must be atd.qa-hook-config/v1")
    root = _abs(config.get("evalHarnessRoot"), "evalHarnessRoot", directory=True)
    if not (root / "scripts" / "eval" / "discovery" / "run.mjs").is_file():
        raise ProtocolError("evalHarnessRoot does not contain scripts/eval/discovery/run.mjs")
    _abs(config.get("outputRoot"), "outputRoot", must_exist=False)
    if config.get("stateDir") is not None:
        _abs(config["stateDir"], "stateDir", must_exist=False)
    if config.get("node") is not None:
        _abs(config["node"], "node", directory=False)
    timeout = config.get("timeoutSeconds", 3300)
    if not isinstance(timeout, int) or not 30 <= timeout <= 7200:
        raise ProtocolError("config timeoutSeconds must be an integer between 30 and 7200")
    profiles = config.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise ProtocolError("config profiles must be a non-empty object")
    for name, profile in profiles.items():
        if not SAFE_ID.match(name) or not isinstance(profile, dict):
            raise ProtocolError(f"invalid profile {name!r}")
        _abs(profile.get("repository"), f"profiles.{name}.repository", directory=True)
        _abs(profile.get("spec"), f"profiles.{name}.spec", directory=False)
        if profile.get("dependencies") is not None:
            _abs(profile["dependencies"], f"profiles.{name}.dependencies", directory=True)
        if profile.get("approvalDir") is not None:
            _abs(profile["approvalDir"], f"profiles.{name}.approvalDir", directory=True)
        if profile.get("framework", "vitest") not in ("vitest", "node:test"):
            raise ProtocolError(f"profiles.{name}.framework must be vitest or node:test")
    for name in config.get("passEnv", []):
        if name not in FORWARDABLE_ENV:
            raise ProtocolError(f"passEnv {name!r} is not on the forwardable allowlist")
    return config


def read_request() -> dict:
    data = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(data) > MAX_INPUT:
        raise ProtocolError("hook input exceeds schema boundary")
    try:
        request = json.loads(data)
    except json.JSONDecodeError as error:
        raise ProtocolError(f"request is not JSON: {error}") from error
    if not isinstance(request, dict):
        raise ProtocolError("request must be a JSON object")
    namespace = request.get("namespace")
    if not isinstance(namespace, str) or not namespace or len(namespace) > 200:
        raise ProtocolError("request.namespace is required")
    if not isinstance(request.get("operation_id"), str) or not SAFE_ID.match(request["operation_id"]):
        raise ProtocolError("request.operation_id must match " + SAFE_ID.pattern)
    if not isinstance(request.get("oracle_id"), str):
        raise ProtocolError("request.oracle_id must name a configured discovery profile")
    for key in ("base", "candidate"):
        if key in request and request[key] is not None and (not isinstance(request[key], str) or not SAFE_REF.match(request[key])):
            raise ProtocolError(f"request.{key} must be a commit-ish")
    return request


def child_env(config: dict) -> dict:
    env = {key: os.environ[key] for key in BASE_ENV if key in os.environ}
    for key in config.get("passEnv", []):
        if key in os.environ:
            env[key] = os.environ[key]
    if config.get("stateDir"):
        env["EVAL_STATE_DIR"] = config["stateDir"]
    return env


def trunc(value, limit=300):
    if isinstance(value, str) and len(value) > limit:
        return value[:limit] + "..."
    return value


TERM_GRACE_SECONDS = 20
TAIL_BYTES = 65536
_active: list = []  # process groups started by this hook, so a signal can take them down


def _signal_group(pid: int, sig: int) -> None:
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def terminate_active_group() -> None:
    for proc in list(_active):
        _signal_group(proc.pid, signal.SIGTERM)
    deadline = TERM_GRACE_SECONDS
    for proc in list(_active):
        try:
            proc.wait(timeout=deadline)
        except subprocess.TimeoutExpired:
            _signal_group(proc.pid, signal.SIGKILL)


def _drain(stream, tail: deque) -> None:
    """Keep only the last TAIL_BYTES of a stream while it is read, so memory stays bounded."""
    size = 0
    for chunk in iter(lambda: stream.read(8192), b""):
        tail.append(chunk)
        size += len(chunk)
        while size > TAIL_BYTES and len(tail) > 1:
            size -= len(tail.popleft())


def run_bounded(argv: list[str], env: dict, timeout: float) -> tuple[int | None, str, str, bool]:
    """Run argv in its own process group with bounded output. On timeout the whole group gets SIGTERM (the sandbox
    runner force-removes its containers on SIGTERM), SIGKILL after a grace period, and stragglers are swept."""
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    _active.append(proc)
    tails = (deque(), deque())
    readers = [threading.Thread(target=_drain, args=(stream, tail), daemon=True) for stream, tail in ((proc.stdout, tails[0]), (proc.stderr, tails[1]))]
    for reader in readers:
        reader.start()
    timed_out = False
    try:
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            _signal_group(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=TERM_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                _signal_group(proc.pid, signal.SIGKILL)
                proc.wait()
    finally:
        _signal_group(proc.pid, signal.SIGKILL)  # sweep any descendants that outlived the leader
        for reader in readers:
            reader.join(timeout=5)
        _active.remove(proc)
    return proc.returncode, b"".join(tails[0]).decode("utf-8", "replace"), b"".join(tails[1]).decode("utf-8", "replace"), timed_out


def run_pipeline(config: dict, profile_name: str, request: dict, op_dir: Path) -> dict:
    profile = config["profiles"][profile_name]
    root = Path(config["evalHarnessRoot"])
    node = config.get("node") or "node"
    env = child_env(config)
    base = request.get("base") or profile.get("defaultBase")
    candidate = request.get("candidate") or profile.get("defaultCandidate", "HEAD")
    if not base:
        raise ProtocolError("request.base (or profile.defaultBase) is required")
    argv = [
        node, str(root / "scripts" / "eval" / "discovery" / "run.mjs"), "run",
        f"--repo={profile['repository']}", f"--base={base}", f"--candidate={candidate}",
        f"--spec={profile['spec']}", f"--out={op_dir / 'discovery'}",
        f"--framework={profile.get('framework', 'vitest')}",
        f"--max-model-calls={int(profile.get('maxModelCalls', 1))}",
        f"--max-candidates={int(profile.get('maxCandidates', 12))}",
    ]
    if profile.get("dependencies"):
        argv.append(f"--dependencies={profile['dependencies']}")
    if profile.get("approvalDir"):
        argv.append(f"--approval-dir={profile['approvalDir']}")
    if profile.get("model"):
        argv.append(f"--model={profile['model']}")
    if profile.get("requireModel"):
        argv.append(f"--require-model={profile['requireModel']}")
    if config.get("stateDir"):
        argv.append(f"--state-dir={config['stateDir']}")
    errors: list[dict] = []
    summary: dict | None = None
    timeout = config.get("timeoutSeconds", 3300)
    try:
        code, stdout, stderr, timed_out = run_bounded(argv, env, timeout)
        (op_dir / "run.stdout.log").write_text(stdout)
        (op_dir / "run.stderr.log").write_text(stderr)
        if timed_out:
            errors.append({"stage": "pipeline", "code": "timeout", "message": f"pipeline exceeded {timeout}s and its process group was terminated; earlier evidence under the operation directory was kept"})
        match = re.search(r"^ATD_SUMMARY=(.+)$", stdout, re.M)
        if match:
            summary_path = Path(match.group(1).strip()).resolve()
            if (op_dir / "discovery").resolve() not in summary_path.parents:
                errors.append({"stage": "adapter", "code": "summary_outside_operation", "message": "round summary path escaped the operation directory"})
            else:
                summary = json.loads(summary_path.read_text())
        elif not timed_out:
            errors.append({"stage": "pipeline", "code": "no_summary", "message": f"run.mjs exit {code} without a round summary"})
    except OSError as error:
        errors.append({"stage": "pipeline", "code": "spawn_failed", "message": trunc(str(error))})

    # Independent recomputation: repair-request.mjs replays every finding/non-PASS case through the existing
    # grade.sh on its preserved grading manifest. Only its answer can produce CONFIRMED_DEFECT.
    recommendation = None
    if summary and (summary.get("harness") or {}).get("resultsPath"):
        round_dir = Path(summary["roundDir"])
        results = round_dir / "results.json"
        if results.is_file():
            ledger = Path(config["outputRoot"]) / "repair-ledger" / profile_name
            rec_argv = [node, str(root / "scripts" / "eval" / "discovery" / "repair-request.mjs"), f"--results={results}", f"--ledger-dir={ledger}",
                        f"--candidate-commit={summary.get('candidateCommit')}"]
            state_dir = (summary.get("harness") or {}).get("stateDir")
            if state_dir:
                rec_argv.append(f"--state-dir={state_dir}")
            # The operator's original expectation reviews live in the TRUSTED config directory, never in evidence.
            if profile.get("approvalDir"):
                rec_argv.append(f"--approval-dir={profile['approvalDir']}")
            try:
                rec_code, rec_out, rec_err, rec_timed_out = run_bounded(rec_argv, env, 900)
                if rec_timed_out or rec_code != 0:
                    errors.append({"stage": "verification", "code": "failed", "message": trunc(rec_err or "independent verification did not complete")})
                else:
                    recommendation = json.loads(rec_out)
            except (OSError, json.JSONDecodeError) as error:
                errors.append({"stage": "verification", "code": "failed", "message": trunc(str(error))})
    return build_result(request, profile_name, summary, recommendation, errors)


def build_result(request: dict, profile_name: str, summary: dict | None, recommendation: dict | None, errors: list[dict]) -> dict:
    result: dict = {"namespace": request["namespace"], "operation_id": request["operation_id"], "oracle_id": profile_name}
    status = summary.get("status") if summary else "pipeline_error"
    errors = list(errors) + [{"stage": e.get("stage"), "code": e.get("code"), "message": trunc(e.get("message"))} for e in (summary or {}).get("errors", [])]
    raw_classes = dict((summary or {}).get("classificationCounts") or {})
    non_pass = (summary or {}).get("nonPass", [])
    verification = (recommendation or {}).get("verification") or {}
    replayed = verification.get("cases") or []
    findings = []
    recomputed_classes: dict = {}
    unverified: list[str] = []
    local_only = 0
    unconfirmed_review = 0
    for item in replayed:
        if not item.get("recomputed"):
            unverified.append(f"{item.get('caseId')}: {trunc(item.get('reason'), 160)}")
            continue
        cls = item.get("classification")
        recomputed_classes[cls or "NO_FINDING"] = recomputed_classes.get(cls or "NO_FINDING", 0) + 1
        if not item.get("consistent"):
            unverified.append(f"{item.get('caseId')}: {trunc(item.get('reason'), 160)}")
            continue
        detail = item.get("finding") or {}
        # CONFIRMED_DEFECT needs a RECOMPUTED VERIFIED_REGRESSION from an independent signer. A local-same-user
        # signature is reporting-only evidence, so even a verified finding stays a reviewable suspicion.
        if item.get("independent"):
            qa = "CONFIRMED_DEFECT"
        elif cls in ("VERIFIED_REGRESSION", "SUSPECTED_REGRESSION"):
            qa = "SUSPECTED_DEFECT"
            if cls == "VERIFIED_REGRESSION":
                if item.get("trust") in INDEPENDENT_TRUST:
                    unconfirmed_review += 1
                else:
                    local_only += 1
        else:
            continue
        findings.append({
            "findingId": detail.get("findingId"), "qaClassification": qa, "recomputedDiscoveryClassification": cls,
            "rawDiscoveryClassification": item.get("rawClassification"), "attestationTrust": item.get("trust"),
            "severity": detail.get("severity"), "targetFile": detail.get("targetFile"), "testFile": detail.get("testFile"),
            "matrix": detail.get("matrix"), "reproducible": detail.get("reproducible"), "requirementSupported": detail.get("requirementSupported"),
            "explanation": trunc(detail.get("explanation"), 400), "reproducer": detail.get("reproducer"), "evidenceUris": (detail.get("evidenceUris") or [])[:5],
        })
    nothing_replayed_but_expected = bool(non_pass) and not replayed
    if nothing_replayed_but_expected:
        unverified.append("non-PASS cases were reported but none could be independently replayed")
    confirmed = [f for f in findings if f["qaClassification"] == "CONFIRMED_DEFECT"]
    suspected = [f for f in findings if f["qaClassification"] == "SUSPECTED_DEFECT"]
    inconclusive = recomputed_classes.get("INCONCLUSIVE", 0)
    reasons: list[str] = []
    if suspected:
        reasons.append(f"{len(suspected)} suspected regression(s) need review")
    if local_only:
        reasons.append(f"{local_only} verified finding(s) carry only a local-same-user attestation (reporting-only trust; not CONFIRMED)")
    if unconfirmed_review:
        reasons.append(f"{unconfirmed_review} verified finding(s) have an independent signer but the operator review is not confirmed against the trusted approvalDir (not CONFIRMED)")
    if inconclusive:
        reasons.append(f"{inconclusive} inconclusive case(s)")
    if unverified:
        reasons.append(f"{len(unverified)} case(s) could not be independently verified or disagree with their recomputation: " + "; ".join(unverified[:3]))
    if errors or status in ERROR_STATUSES or status == "pipeline_error":
        reasons.append("pipeline errors present; no conclusion may be drawn from this run")
    unclassified = [n for n in non_pass if n.get("classification") == "UNCLASSIFIED_NON_PASS"]
    if unclassified:
        reasons.append(f"{len(unclassified)} non-PASS case(s) without a classification")

    if confirmed:
        verdict, classification = "FAIL", "CONFIRMED_DEFECT"
    elif status in ("no_targets", "no_candidates") and not errors:
        verdict, classification = "NOT_RUN", None
    elif errors or unverified or status != "completed" or suspected or inconclusive or non_pass:
        verdict, classification = "INCONCLUSIVE", ("SUSPECTED_DEFECT" if suspected else None)
    else:
        verdict, classification = "PASS", None
    harness = (summary or {}).get("harness") or {}
    result.update({
        "status": status, "verdict": verdict, "classification": classification,
        "reviewRequired": bool(reasons), "reviewReasons": reasons, "findings": findings[:10],
        "counts": {
            "byRawDiscoveryClassification": raw_classes, "byRecomputedClassification": recomputed_classes,
            "unverifiedOrInconsistent": len(unverified), "nonPass": len(non_pass), "casesRun": len((summary or {}).get("cases", [])),
        },
        "errors": errors[:5],
        "evidence": {
            "roundSummary": (summary or {}).get("roundDir") and str(Path(summary["roundDir"]) / "round-summary.json"),
            "resultsPath": harness.get("resultsPath"), "resultsSha256": harness.get("resultsSha256"), "evalHarnessVerdict": harness.get("verdict"),
        },
        "generation": None if not summary or not summary.get("generation") else {
            "transport": summary["generation"].get("transport"), "real": summary["generation"].get("real"),
            "servedModels": summary["generation"].get("servedModels"), "modelCalls": summary["generation"].get("modelCalls"),
            "usage": summary["generation"].get("usage"),
        },
    })
    recs = []
    for item in (recommendation or {}).get("requests", []):
        request_body = item.get("request", {})
        recs.append({"type": "repair_request", "findingId": request_body.get("findingId"), "attempt": request_body.get("attempt"),
                     "maxAttempts": request_body.get("maxAttempts"), "targetFile": request_body.get("targetFile"),
                     "requestPath": item.get("path"), "instruction": trunc(request_body.get("instruction"), 400)})
    for item in (recommendation or {}).get("advisories", []):
        recs.append({"type": "human_review", "findingId": item.get("findingId"), "reason": trunc(item.get("reason"), 300)})
    for item in (recommendation or {}).get("exhausted", []):
        recs.append({"type": "human_review", "findingId": item.get("findingId"), "reason": item.get("reason")})
    result["recommendations"] = recs[:10]
    result["note"] = ("PASS means generated tests ran and showed no observed regression; it does not mean the change is bug-free."
                      if verdict == "PASS" else "Not a pass: see reviewReasons/errors.")
    return bound_output(result)


def bound_output(result: dict) -> dict:
    """Keep the serialized result under QA's output boundary by shedding detail, never by hiding state."""
    for _ in range(6):
        if len(json.dumps(result, separators=(",", ":")).encode()) <= MAX_OUTPUT:
            return result
        for key in ("findings", "recommendations", "errors"):
            if len(result.get(key, [])) > 1:
                result[key] = result[key][: max(1, len(result[key]) // 2)]
                result["truncated"] = True
        for finding in result.get("findings", []):
            finding["explanation"] = trunc(finding.get("explanation"), 80)
            finding["evidenceUris"] = (finding.get("evidenceUris") or [])[:1]
            finding.pop("reproducer", None)
    result["findings"] = [{k: f.get(k) for k in ("findingId", "qaClassification", "targetFile")} for f in result.get("findings", [])]
    result["truncated"] = True
    return result


def operation_dir(config: dict, profile_name: str, request: dict) -> Path:
    return Path(config["outputRoot"]) / "operations" / profile_name / request["operation_id"]


def atomic_write(path: Path, value: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle)
    os.replace(tmp, path)


def stored_result(op_dir: Path) -> dict | None:
    """Latest finished result for this operation (idempotence); interrupted attempts have none."""
    candidates = sorted(op_dir.parent.glob(op_dir.name + ".retry*")) + [op_dir]
    for directory in reversed(candidates):
        result_file = directory / "result.json"
        if result_file.is_file():
            return json.loads(result_file.read_text())
    return None


def new_attempt_dir(op_dir: Path) -> Path:
    """Fresh directory for this attempt; a directory left by an interrupted attempt is preserved, never reused."""
    if not op_dir.exists():
        op_dir.mkdir(parents=True, mode=0o700)
        return op_dir
    for n in range(1, 100):
        retry = op_dir.parent / f"{op_dir.name}.retry{n}"
        if not retry.exists():
            retry.mkdir(mode=0o700)
            return retry
    raise ProtocolError("too many interrupted attempts for this operation_id")


def handle(config: dict, request: dict) -> dict:
    profile_name = request["oracle_id"]
    if profile_name not in config["profiles"]:
        raise ProtocolError(f"oracle_id {profile_name!r} is not a configured discovery profile")
    op_dir = operation_dir(config, profile_name, request)
    op_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    existing = stored_result(op_dir)
    if existing is not None:
        return existing
    attempt_dir = new_attempt_dir(op_dir)
    atomic_write(attempt_dir / "request.json", request)
    result = run_pipeline(config, profile_name, request, attempt_dir)
    atomic_write(attempt_dir / "result.json", result)
    return result


def main(argv: list[str]) -> int:
    config_path = None
    args = list(argv)
    while args:
        flag = args.pop(0)
        if flag == "--config" and args:
            config_path = args.pop(0)
        else:
            sys.stderr.write("usage: discovery.py --config <abs config.json>\n")
            return 2
    if not config_path or not os.path.isabs(config_path):
        sys.stderr.write("discovery.py: --config must be an absolute path\n")
        return 2
    try:
        config = load_config(config_path)
        request = read_request()
        result = handle(config, request)
        if result.get("namespace") != request["namespace"]:
            raise ProtocolError("namespace mismatch")
        sys.stdout.write(json.dumps(bound_output(result)))
        return 0
    except ProtocolError as error:
        sys.stderr.write(f"discovery.py: {error}\n")
        return 2
    except Exception as error:  # noqa: BLE001 — surface as a hook failure, never a fabricated result
        sys.stderr.write(f"discovery.py: unexpected failure: {type(error).__name__}: {error}\n")
        return 1


def _terminate_on_signal(signum, _frame):
    """QA (or an operator) asked us to stop: take the pipeline's process group down first."""
    terminate_active_group()
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, _terminate_on_signal)
    signal.signal(signal.SIGINT, _terminate_on_signal)
    sys.exit(main(sys.argv[1:]))
