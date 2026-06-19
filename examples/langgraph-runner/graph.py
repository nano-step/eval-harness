"""Stubbed LangGraph-compatible graph for the eval-harness example.

Invoked as `python3 -m graph --input <X> --output <Y>` by langgraph-node.sh.
Stays self-contained (no `import langgraph`); U4's test stubs `python3` and
never executes this module, so the @tool decorator is a no-op only present
to exercise the fingerprint's tool-detection path.
"""
import argparse
import json


def tool(fn):  # no-op; matches LangGraph's signature for the fingerprint
    return fn


@tool
def search_docs(query, max_sources=2):
    """Fake doc search. Returns a deterministic list of source labels."""
    base = ["langgraph-docs", "eval-harness"]
    return base[: max(1, min(int(max_sources), len(base)))]


def run(input_data):
    """Main entry point. Returns a dict with `answer` and `sources`."""
    query = input_data.get("query", "")
    max_sources = int(input_data.get("max_sources", 2))
    sources = search_docs(query, max_sources=max_sources)
    return {
        "answer": f"computed for {query}",
        "sources": sources,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    with open(args.input, "r", encoding="utf-8") as f:
        input_data = json.load(f)
    result = run(input_data)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    print(f"graph: wrote {args.output}")


if __name__ == "__main__":
    main()
