#!/usr/bin/env python3
"""yq-shim helper: a minimal yq-compatible subset for eval-harness.

The stdlib parser exists for locked-down or air-gapped environments where the
project's documented shell + jq + python3 stdlib toolchain is available but
installing PyYAML or a yq binary is not. It is intentionally not a general YAML
implementation. It supports the subset used by eval-harness config and case
files: space-indented mappings and lists, null/bool/number/string scalars,
inline arrays/maps, comments, and literal/folded block scalars. It does not
support anchors, aliases, tags, multi-document streams, or arbitrary YAML 1.2
features. When PyYAML is available and EVAL_YQ_FORCE_STDLIB is not set, PyYAML
remains the default parser.

Reads YAML from stdin or a file arg, applies a tiny expression language,
prints scalars (with -r) or JSON / YAML output.
"""
import sys
import json
import re
import argparse
import ast
import os

if os.environ.get("EVAL_YQ_FORCE_STDLIB") == "1":
    _pyyaml = None
else:
    try:
        import yaml as _pyyaml
    except ModuleNotFoundError:
        _pyyaml = None


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def next_content(lines, i):
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped and not stripped.startswith("#"):
            return i
        i += 1
    return i


def split_top_level(text, delimiter=","):
    parts = []
    buf = ""
    quote = None
    escape = False
    depth = 0
    for ch in text:
        if quote:
            buf += ch
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            buf += ch
            continue
        if ch in "[{(":
            depth += 1
        elif ch in "]})" and depth > 0:
            depth -= 1
        if ch == delimiter and depth == 0:
            parts.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip() or text.endswith(delimiter):
        parts.append(buf.strip())
    return parts


def split_key_value(text):
    quote = None
    escape = False
    depth = 0
    for i, ch in enumerate(text):
        if quote:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            continue
        if ch in "[{(":
            depth += 1
            continue
        if ch in "]})" and depth > 0:
            depth -= 1
            continue
        if ch == ":" and depth == 0:
            return text[:i].strip(), text[i + 1 :].strip()
    return None, None


def strip_inline_comment(raw):
    quote = None
    escape = False
    depth = 0
    for i, ch in enumerate(raw):
        if quote:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            continue
        if ch in "[{(":
            depth += 1
            continue
        if ch in "]})" and depth > 0:
            depth -= 1
            continue
        if ch == "#" and depth == 0 and (i == 0 or raw[i - 1].isspace()):
            return raw[:i].rstrip()
    return raw


def parse_scalar(raw):
    value = strip_inline_comment(raw.strip())
    if value == "":
        return ""
    if value in ("[]", "{}"):
        return json.loads(value)
    if value in ("null", "~"):
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        try:
            return ast.literal_eval(value)
        except (SyntaxError, ValueError):
            return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return [parse_scalar(part) for part in split_top_level(inner)]
    if value.startswith("{") and value.endswith("}"):
        inner = value[1:-1].strip()
        if not inner:
            return {}
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            out = {}
            for part in split_top_level(inner):
                key, val = split_key_value(part)
                if key is not None:
                    out[str(parse_scalar(key))] = parse_scalar(val)
            return out
    if re.match(r"^-?[0-9]+$", value):
        try:
            return int(value)
        except ValueError:
            pass
    if re.match(r"^-?[0-9]+\.[0-9]+$", value):
        try:
            return float(value)
        except ValueError:
            pass
    return value


def parse_block_scalar(lines, i, parent_indent, style):
    start = i
    block_indent = None
    while i < len(lines):
        raw = lines[i]
        if raw.strip():
            ind = indent_of(raw)
            if ind <= parent_indent:
                break
            block_indent = ind if block_indent is None else min(block_indent, ind)
        i += 1
    if block_indent is None:
        return "", i

    out_lines = []
    for raw in lines[start:i]:
        if not raw.strip():
            out_lines.append("")
        else:
            out_lines.append(raw[block_indent:])
    if style == ">":
        return " ".join(line.strip() for line in out_lines).rstrip() + "\n", i
    return "\n".join(out_lines).rstrip("\n") + "\n", i


def parse_dict(lines, i, indent):
    out = {}
    while i < len(lines):
        i = next_content(lines, i)
        if i >= len(lines):
            break
        ind = indent_of(lines[i])
        if ind < indent:
            break
        if ind > indent:
            break
        text = lines[i][ind:]
        if text.startswith("- "):
            break
        key, raw_value = split_key_value(text)
        if key is None:
            break
        key = parse_scalar(key)
        raw_value = strip_inline_comment(raw_value)
        if raw_value in ("|", ">"):
            out[key], i = parse_block_scalar(lines, i + 1, ind, raw_value)
            continue
        if raw_value != "":
            out[key] = parse_scalar(raw_value)
            i += 1
            continue

        j = next_content(lines, i + 1)
        if j >= len(lines) or indent_of(lines[j]) <= ind:
            out[key] = None
            i += 1
            continue
        out[key], i = parse_block(lines, j, indent_of(lines[j]))
    return out, i


def parse_list(lines, i, indent):
    out = []
    while i < len(lines):
        i = next_content(lines, i)
        if i >= len(lines):
            break
        ind = indent_of(lines[i])
        if ind < indent:
            break
        if ind != indent:
            break
        text = lines[i][ind:]
        if not text.startswith("- "):
            break
        item_text = strip_inline_comment(text[2:].strip())
        if item_text == "":
            j = next_content(lines, i + 1)
            if j >= len(lines) or indent_of(lines[j]) <= ind:
                out.append(None)
                i += 1
            else:
                item, i = parse_block(lines, j, indent_of(lines[j]))
                out.append(item)
            continue

        key, raw_value = split_key_value(item_text)
        if key is None:
            out.append(parse_scalar(item_text))
            i += 1
            continue

        key = parse_scalar(key)
        raw_value = strip_inline_comment(raw_value)
        i += 1
        j = next_content(lines, i)
        if raw_value == "":
            item = {key: None}
            if j < len(lines) and indent_of(lines[j]) > ind:
                item[key], i = parse_block(lines, j, indent_of(lines[j]))
        else:
            item = {key: parse_scalar(raw_value)}
            if j < len(lines) and indent_of(lines[j]) > ind:
                rest, i = parse_dict(lines, j, indent_of(lines[j]))
                item.update(rest)
        out.append(item)
    return out, i


def parse_block(lines, i, indent):
    i = next_content(lines, i)
    if i >= len(lines):
        return None, i
    ind = indent_of(lines[i])
    if ind < indent:
        return None, i
    text = lines[i][ind:]
    if text.startswith("- "):
        return parse_list(lines, i, ind)
    return parse_dict(lines, i, ind)


def load_document(text):
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    if _pyyaml is not None:
        return _pyyaml.safe_load(text)
    data, _ = parse_block(text.splitlines(), 0, 0)
    return data


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

    if expr.endswith("[]?") or expr.endswith("[]"):
        suffix_len = 3 if expr.endswith("[]?") else 2
        base = evaluate(data, expr[:-suffix_len])
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
        elif _pyyaml is None:
            print(json.dumps(result, ensure_ascii=False))
        else:
            print(_pyyaml.safe_dump(result, default_flow_style=False, sort_keys=False).rstrip())


def main():
    argv = []
    for raw in sys.argv[1:]:
        if raw.startswith("-o="):
            argv.extend(["-o", raw.split("=", 1)[1]])
        elif raw.startswith("--output-format="):
            argv.extend(["--output-format", raw.split("=", 1)[1]])
        else:
            argv.append(raw)

    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-r", action="store_true", dest="raw")
    ap.add_argument("-o", dest="out_format", default="yaml")
    ap.add_argument("--output-format", dest="out_format")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("expr", nargs="?", default=".")
    ap.add_argument("file", nargs="?", default=None)
    args, _ = ap.parse_known_args(argv)

    if args.version:
        print("python-yq-shim 0.1.0")
        return 0

    out_fmt = args.out_format
    if out_fmt and out_fmt.startswith("="):
        out_fmt = out_fmt.lstrip("=")

    if args.file:
        with open(args.file) as f:
            data = load_document(f.read())
    else:
        data = load_document(sys.stdin.read())

    result = evaluate(data, args.expr)
    expr_norm = args.expr.strip()
    is_iter = (expr_norm.endswith("[]") or expr_norm.endswith("[]?")) \
              and "// []" not in expr_norm and "//[]" not in expr_norm
    emit(result, args.raw, out_fmt, is_iter)
    return 0


if __name__ == "__main__":
    sys.exit(main())
