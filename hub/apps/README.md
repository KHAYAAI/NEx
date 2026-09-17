MCP server integrations ("Apps") — Phase 2.

Each subdirectory is one MCP server, standalone and independently
runnable, following `CLAUDE.md` §5 Phase 2's guidance to "start with
something low-stakes." `hub/agent/agent.py` is the (currently only) MCP
client that talks to these.

- `file-search/` — the first one: read-only file search, scoped to a
  single root directory.
- `notes/` — plain-text notes (add/list), persisted to a JSON file.
- `smart-home/` — mock IoT device state (get/set), persisted to a JSON
  file. Not a real Home Assistant integration — see its own README.

Phase 6's F-Droid-style app distribution (`DEPENDENCIES.md`) is how
these eventually reach users as installable packages; nothing here
implements that yet — these are plain scripts run directly.
