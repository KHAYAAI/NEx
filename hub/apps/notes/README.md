# notes

A real MCP "App": plain-text notes, persisted to a JSON file —
`add_note` and `list_notes`. Built for Phase 5's simulated week
(`CLAUDE.md` §5), which names "notes" as an interaction type to
exercise; see `hub/apps/README.md`.

## Running standalone

```sh
python3 server.py --store /path/to/notes.json
```

Speaks MCP over stdio; meant to be launched by `hub/agent/agent.py`
(a `notes: add <text>` or `notes: list` question routes here).
