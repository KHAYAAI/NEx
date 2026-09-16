MCP server integrations ("Apps") — Phase 2.

Each subdirectory is one MCP server, standalone and independently
runnable, following `CLAUDE.md` §5 Phase 2's guidance to "start with
something low-stakes." `hub/agent/agent.py` is the (currently only) MCP
client that talks to these.

- `file-search/` — the first one: read-only file search, scoped to a
  single root directory.

Phase 6's F-Droid-style app distribution (`DEPENDENCIES.md`) is how
these eventually reach users as installable packages; nothing here
implements that yet — these are plain scripts run directly.
