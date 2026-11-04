#!/usr/bin/env python3
"""Invoke the discovery oracle adapter through QA Factory's own ``qa_factory.hooks.command_hook``.

This is a consumer smoke helper, not a second QA runtime: it imports the real ``command_hook`` and
``HookSpec`` from a QA Factory checkout, so the executable-allowlist check, the scrubbed environment, the
64 KiB input/output boundaries, the deadline and the namespace check are all QA Factory's own.

    <qa-factory-python> command_hook_smoke.py --qa-src <qa-agents-factory>/src \
        --hook-command-json '["/abs/discovery.py","--config","/abs/config.json"]' \
        --payload-json '{"operation_id":"op-1","namespace":"ns-1","oracle_id":"collision-boundary"}' \
        [--hook-seconds 3600]

Run it with an interpreter that has QA Factory's dependencies (for example its ``.venv``). It prints the
hook result JSON on stdout, or exits non-zero with QA Factory's own error.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from types import SimpleNamespace


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qa-src", required=True, help="directory that contains the qa_factory package")
    parser.add_argument("--hook-command-json", required=True)
    parser.add_argument("--payload-json", required=True)
    parser.add_argument("--hook-name", default="atd-discovery")
    parser.add_argument("--hook-seconds", type=float, default=3600.0)
    parser.add_argument("--secret-env", action="append", default=[])
    args = parser.parse_args()

    sys.path.insert(0, args.qa_src)
    from qa_factory.hooks import command_hook  # noqa: PLC0415 — imported after sys.path setup
    from qa_factory.models import HookSpec  # noqa: PLC0415

    spec = HookSpec(name=args.hook_name, command=json.loads(args.hook_command_json), purpose="oracle")
    # command_hook reads only budgets.hook_seconds and secret_envs from the campaign configuration.
    config = SimpleNamespace(budgets=SimpleNamespace(hook_seconds=args.hook_seconds), secret_envs=args.secret_env)
    result = asyncio.run(command_hook(spec, config, json.loads(args.payload_json)))
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
