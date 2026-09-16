#!/usr/bin/env python3
"""The Phase 2 "App": a minimal, low-stakes MCP server exposing one tool
— search_files — that greps a directory tree for a query string and
returns matching file paths with a snippet of context.

This is the "start with something low-stakes" MCP integration CLAUDE.md
calls for in Phase 2. It talks the real MCP protocol over stdio (JSON-RPC
per the spec, via the official `mcp` Python SDK) — hub/agent/agent.py is
a real MCP client, not a function pretending to be one.

Deliberately read-only and confined to a root directory passed on the
command line (defaults to the current directory) — no writes, no
arbitrary paths, no shell execution. A hub's tool ecosystem eventually
grows to touch real user data and real IoT devices (CLAUDE.md's "Apps"),
so the first one is scoped as narrowly as it can be while still being
useful, on purpose.
"""
import argparse
import sys
from pathlib import Path

from mcp.server.mcpserver import MCPServer

server = MCPServer("nex-file-search")
_root: Path = Path(".")


@server.tool()
def search_files(query: str, max_results: int = 5) -> str:
    """Search text files under the configured root for a literal substring.

    Args:
        query: the literal text to search for (case-insensitive).
        max_results: maximum number of matches to return.
    """
    if not query.strip():
        return "empty query"

    needle = query.lower()
    hits = []
    for path in sorted(_root.rglob("*")):
        if len(hits) >= max_results:
            break
        if not path.is_file() or path.stat().st_size > 2_000_000:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if needle in line.lower():
                rel = path.relative_to(_root)
                hits.append(f"{rel}:{lineno}: {line.strip()[:200]}")
                break

    if not hits:
        return f"no matches for {query!r} under {_root}"
    return "\n".join(hits)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    _root = args.root.resolve()
    if not _root.is_dir():
        print(f"--root {args.root} is not a directory", file=sys.stderr)
        sys.exit(1)
    server.run(transport="stdio")
