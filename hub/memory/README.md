# hub/memory

`eventlog.py` — the hub's event log (`CLAUDE.md` §5, Phase 2's "log the
full interaction to the event log" requirement, and Phase 2's exit
criterion that a logged interaction appears within 1 second).

Plain SQLite, per `DEPENDENCIES.md`'s "SQLite + sqlite-vec — raw
event-log substrate": one row per interaction (question, answer, which
MCP tool if any, latency, model), no server process, inspectable with
the standard `sqlite3` CLI or any DB browser. That inspectability isn't
incidental — it's the "auditable down to the schematic" principle from
`CLAUDE.md` §1 applied to a user's own data: they should be able to open
this file themselves and see exactly what's been logged, not have to
trust a client's rendering of it.

Pruning/decay is explicitly out of scope here — that's the Phase 3
"dreaming" pipeline's job, operating on this log as its input, not this
module's.

## Usage

```python
from eventlog import EventLog
log = EventLog("hub-events.db")
log.log_interaction(question="...", answer="...", model="...", latency_ms=42.0)
log.recent(10)
```

Or from the CLI: `python3 eventlog.py hub-events.db -n 10`.
