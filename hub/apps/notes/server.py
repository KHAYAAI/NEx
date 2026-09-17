#!/usr/bin/env python3
"""A second real MCP "App": a plain-text notes store — add_note and
list_notes — persisted to a JSON file.

Built for Phase 5's "full week of simulated real use" (CLAUDE.md §5):
that week's activity mix names "notes" as one of the interaction types
to exercise, and a real tool beats labeling plain Q&A "a note" and
hoping nobody checks. Same shape as hub/apps/file-search/: real MCP
protocol over stdio, narrowly scoped, no network access of its own.
"""
import argparse
import json
import sys
import time
from pathlib import Path

from mcp.server.mcpserver import MCPServer

server = MCPServer("nex-notes")
_store_path: Path = Path("notes.json")


def _load() -> list[dict]:
    if not _store_path.exists():
        return []
    return json.loads(_store_path.read_text())


def _save(notes: list[dict]) -> None:
    _store_path.write_text(json.dumps(notes, indent=2))


@server.tool()
def add_note(text: str) -> str:
    """Add a plain-text note.

    Args:
        text: the note's content.
    """
    notes = _load()
    note = {"id": len(notes) + 1, "text": text, "ts_ms": int(time.time() * 1000)}
    notes.append(note)
    _save(notes)
    return f"saved note #{note['id']}"


@server.tool()
def list_notes(max_results: int = 10) -> str:
    """List the most recent notes, newest first.

    Args:
        max_results: maximum number of notes to return.
    """
    notes = _load()
    if not notes:
        return "no notes yet"
    recent = list(reversed(notes))[:max_results]
    return "\n".join(f"#{n['id']}: {n['text']}" for n in recent)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, default=Path("notes.json"))
    args = parser.parse_args()
    _store_path = args.store
    if not _store_path.parent.is_dir():
        print(f"--store's parent directory {_store_path.parent} does not exist", file=sys.stderr)
        sys.exit(1)
    server.run(transport="stdio")
