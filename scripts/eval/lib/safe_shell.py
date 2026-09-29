#!/usr/bin/env python3
"""Run a deliberately small, shell-free language for implicit-safe shell checks."""

from __future__ import annotations
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

ALLOWED_JQ_OPTIONS = {
    "-c", "--compact-output", "-e", "--exit-status", "-j", "--join-output",
    "-n", "--null-input", "-r", "--raw-output", "-s", "--slurp",
    "-R", "--raw-input",
}
FORBIDDEN_FILTER = re.compile(
    r"\$ENV\b|\benv\b|(?:^|[|,( ])(?:inputs?|debug|include|import|stderr|halt)(?:$|[|,) ])"
)
MAX_COMMANDS = 4
TIMEOUT_SECONDS = 10


class UnsafeCommand(Exception):
    pass


def parse_pipeline(command: str) -> list[list[str]]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars="|;&<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    if not tokens:
        raise UnsafeCommand("empty command")

    pipeline: list[list[str]] = [[]]
    for token in tokens:
        if token == "|":
            if not pipeline[-1]:
                raise UnsafeCommand("empty pipeline command")
            pipeline.append([])
            continue
        if token in {"&", "&&", ";", "<", "<<", "<<<", ">", ">>", "|&", "||"} or any(
            op in token for op in ("&&", "||", ";", "<", ">", "&")
        ):
            raise UnsafeCommand("shell operators and redirections are not supported")
        pipeline[-1].append(token)
    if not pipeline[-1] or len(pipeline) > MAX_COMMANDS:
        raise UnsafeCommand("invalid or overlong pipeline")
    return pipeline


def validate_jq(argv: list[str], workdir: Path, has_pipe_input: bool) -> list[str]:
    if not argv or argv[0] != "jq":
        raise UnsafeCommand("only jq, printf, and wc -l are supported")
    index = 1
    while index < len(argv) and argv[index] in ALLOWED_JQ_OPTIONS:
        index += 1
    remaining = argv[index:]
    if len(remaining) not in (1, 2) or remaining[0].startswith("-"):
        raise UnsafeCommand("jq requires one expression and at most one workdir file")
    filter_text = remaining[0]
    if FORBIDDEN_FILTER.search(filter_text):
        raise UnsafeCommand("jq environment, input, and module access is not allowed")
    file_arg = remaining[1] if len(remaining) == 2 else None
    if file_arg is not None and file_arg != "-":
        path = Path(file_arg)
        if path.is_absolute():
            raise UnsafeCommand("jq input must be inside the workdir")
        resolved_root = workdir.resolve()
        resolved_file = (workdir / path).resolve()
        try:
            resolved_file.relative_to(resolved_root)
        except ValueError as error:
            raise UnsafeCommand("jq input escapes the workdir") from error
        if resolved_file == resolved_root or not resolved_file.is_file():
            raise UnsafeCommand("jq input file must be a file inside the workdir")
        return ["jq", *argv[1:index], filter_text, str(resolved_file)]
    if file_arg == "-" and not has_pipe_input:
        raise UnsafeCommand("jq stdin is only available from an explicit safe pipeline")
    if file_arg == "-":
        return ["jq", *argv[1:index], filter_text, "-"]
    return ["jq", *argv[1:index], filter_text]


def pin_executable(argv: list[str]) -> list[str]:
    absolute_path = os.pathsep.join(
        entry
        for entry in os.environ.get("PATH", "").split(os.pathsep)
        if entry and Path(entry).is_absolute()
    )
    executable = shutil.which(argv[0], path=absolute_path)
    if executable is None:
        raise UnsafeCommand(f"allowed executable {argv[0]!r} was not found on an absolute PATH")
    return [str(Path(executable).resolve()), *argv[1:]]


def validate_pipeline(commands: list[list[str]], workdir: Path) -> list[list[str]]:
    validated: list[list[str]] = []
    for index, argv in enumerate(commands):
        has_pipe_input = index > 0
        program = argv[0]
        if program == "jq":
            checked = validate_jq(argv, workdir, has_pipe_input)
        elif program == "printf" and index == 0:
            if len(argv) < 2:
                raise UnsafeCommand("printf requires a format string")
            checked = argv
        elif program == "wc" and index > 0 and index == len(commands) - 1 and argv == ["wc", "-l"]:
            checked = argv
        else:
            raise UnsafeCommand("only jq, printf, and terminal wc -l commands are supported")
        validated.append(pin_executable(checked))
    if any(argv[0] == "wc" for argv in validated[:-1]):
        raise UnsafeCommand("wc -l must be the final pipeline command")
    return validated


def run_pipeline(commands: list[list[str]], workdir: Path) -> str:
    input_bytes: bytes | None = b""
    stderr_parts: list[bytes] = []
    for argv in commands:
        completed = subprocess.run(
            argv,
            cwd=workdir,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_SECONDS,
            check=False,
        )
        input_bytes = completed.stdout
        if completed.stderr:
            stderr_parts.append(completed.stderr)
    output = input_bytes or b""
    if stderr_parts:
        output += b"".join(stderr_parts)
    return output.decode("utf-8", errors="replace")


def main() -> int:
    if len(sys.argv) != 3:
        raise UnsafeCommand("usage: safe_shell.py <workdir> <command>")
    workdir = Path(sys.argv[1]).resolve(strict=True)
    if not workdir.is_dir():
        raise UnsafeCommand("workdir is not a directory")
    pipeline = validate_pipeline(parse_pipeline(sys.argv[2]), workdir)
    output = run_pipeline(pipeline, workdir)
    json.dump({"safe": True, "output": output}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, UnsafeCommand, subprocess.TimeoutExpired) as error:
        json.dump({"safe": False, "error": str(error)}, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(0)
