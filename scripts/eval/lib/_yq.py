#!/usr/bin/env python3
"""yq-shim helper: a minimal yq-compatible subset for eval-harness.

Reads YAML from stdin or a file arg, applies a tiny expression language,
prints scalars (with -r) or JSON / YAML output.
"""
import sys
import json
import re
import argparse

import yaml


def navigate(data, expr):
    expr = expr.strip()
    if expr in (".", ""):
        return data
    if expr.startswith("."):
        expr = expr[1:]

    parts = []
    buf = ""
    i = 0
    while i < len(expr):
        c = expr[i]
        if c == ".":
            if buf:
                parts.append(buf)
                buf = ""
        elif c == "[":
            if buf:
                parts.append(buf)
                buf = ""
            j = expr.index("]", i)
            parts.append("[" + expr[i + 1 : j] + "]")
            i = j
        else:
            buf += c
        i += 1
    if buf:
        parts.append(buf)

    cur = data
    for part in parts:
        if part.startswith("["):
            inner = part[1:-1]
            if inner == "":
                if isinstance(cur, list):
                    continue
                return None
            try:
                cur = cur[int(inner)]
            except (ValueError, IndexError, TypeError, KeyError):
                return None
        else:
            if isinstance(cur, dict):
                cur = cur.get(part)
            else:
                return None
        if cur is None:
            return None
    return cur


def evaluate(data, expr):
    expr = expr.strip()

    m = re.match(r"^(.+?)\s*//\s*(.+)$", expr)
    if m:
        primary = m.group(1).strip()
        fallback_raw = m.group(2).strip()
        val = evaluate(data, primary)
        if val is None or val == "":
            if fallback_raw in ("empty", "null"):
                return None
            if fallback_raw.startswith('"') and fallback_raw.endswith('"'):
                return fallback_raw[1:-1]
            if fallback_raw in ("false", "true"):
                return fallback_raw == "true"
            if fallback_raw in ("[]", "{}"):
                return json.loads(fallback_raw)
            try:
                return json.loads(fallback_raw)
            except Exception:
                return fallback_raw
        return val

    if expr.endswith("| length"):
        base = evaluate(data, expr.replace("| length", "").strip())
        if base is None:
            return 0
        return len(base) if hasattr(base, "__len__") else 0

    if expr.endswith("[]"):
        base = evaluate(data, expr[:-2])
        if base is None:
            return []
        if isinstance(base, list):
            return base
        if isinstance(base, dict):
            return list(base.values())
        return [base]

    return navigate(data, expr)


def emit(result, raw, out_format, is_iter):
    if is_iter and isinstance(result, list):
        for item in result:
            if raw and isinstance(item, str):
                print(item)
            elif raw and item is None:
                pass
            elif raw and isinstance(item, bool):
                print("true" if item else "false")
            elif raw and isinstance(item, (int, float)):
                print(item)
            else:
                print(json.dumps(item, ensure_ascii=False))
        return

    if raw:
        if result is None:
            return
        if isinstance(result, bool):
            print("true" if result else "false")
        elif isinstance(result, (str, int, float)):
            print(result)
        else:
            print(json.dumps(result, ensure_ascii=False))
        return

    if out_format == "json":
        print(json.dumps(result, ensure_ascii=False))
    else:
        if result is None:
            print("null")
        else:
            print(yaml.safe_dump(result, default_flow_style=False, sort_keys=False).rstrip())


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-r", action="store_true", dest="raw")
    ap.add_argument("-o", dest="out_format", default="yaml")
    ap.add_argument("--output-format", dest="out_format")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("expr", nargs="?", default=".")
    ap.add_argument("file", nargs="?", default=None)
    args, _ = ap.parse_known_args()

    if args.version:
        print("python-yq-shim 0.1.0")
        return 0

    out_fmt = args.out_format
    if out_fmt and "=" in out_fmt:
        out_fmt = out_fmt.split("=", 1)[1]

    if args.file:
        with open(args.file) as f:
            data = yaml.safe_load(f)
    else:
        data = yaml.safe_load(sys.stdin)

    result = evaluate(data, args.expr)
    is_iter = args.expr.strip().endswith("[]")
    emit(result, args.raw, out_fmt, is_iter)
    return 0


if __name__ == "__main__":
    sys.exit(main())
