# zero-internet

Phase 5 (`CLAUDE.md` §5): the full integration test, the sync load
test, and the security pass — run together, `run-week.sh`, against
real hub and pocket code from Phases 1-4, not a re-derived stand-in.

## What it actually does

1. Stands up two real, separate network namespaces linked by a real
   WireGuard tunnel (`infra/wireguard-poc/`'s pattern, Phase 1) — the
   only way either namespace can reach the other at all.
2. Locks down egress in **both** namespaces with `iptables`: only
   loopback and the WireGuard tunnel's own traffic may leave. A canary
   check first proves this actually catches a bypass attempt (a direct
   call to the peer's veth address instead of through the tunnel) —
   without that, a "0 rejects" result at the end wouldn't mean much.
3. Runs a 7-"day" simulated week (`CLAUDE.md`'s "full week of simulated
   real use"):
   - the hub answers local questions, adds/lists notes, and gets/sets
     mock smart-home device state (`hub/apps/notes/`,
     `hub/apps/smart-home/` — new this phase, see their READMEs) —
     real MCP tool calls, not relabeled Q&A
   - the hub's nightly dreaming consolidation runs each day
     (`hub/dreaming/`, Phase 3)
   - the phone goes through two separate offline-answer-then-reconnect
     cycles, this time syncing over the **real WireGuard tunnel**
     rather than loopback (Phase 4 proved the queue and merge logic;
     this exercises the same logic over the real transport Phase 1
     built)
   - one day is a dedicated load test: 100 rapid, concurrent writes to
     the *same* Automerge field, hub and phone both connected and
     writing at once (not offline-then-reconnect) — both sides must
     converge on the identical final value
4. Mirrors every phone-synced interaction into the hub's real event log
   (`hub/memory/eventlog.py`) — same gap-closing this phase's own week
   exercises again, on top of what Phase 4 already fixed once.
5. Checks the egress-reject counters one last time: if anything, ever,
   tried to leave either namespace by any path except loopback or the
   tunnel, this fails the build — not because a route happened to be
   missing, but because it was actively caught.

## What's honestly not exercised

- **Voice interactions.** No Faster-Whisper integration exists
  (`pocket/README.md` already discloses this Phase 4 gap). The week's
  "voice" slots are plain text questions — not claimed as voice.
- **Calendar.** No real calendar backend. "What is on my calendar
  today?" is answered by the plain local-model path, same as any other
  question — there's no calendar data behind it.
- **Home automation** is a real MCP tool call, but against a mock
  backend (`hub/apps/smart-home/`), not a real Home Assistant
  integration — `hub/README.md` already discloses that gap; this phase
  gives it a genuine (if mock) tool to call instead of skipping the
  category.
- **Real hardware, in every sense already established:** no real
  Jetson/Sophon dev board, no real Android device — see `hub/README.md`
  and `pocket/README.md`.

## Running it

```sh
sudo infra/zero-internet/run-week.sh
```

Needs root (namespaces, WireGuard, iptables). Reuses llama.cpp, the
synthetic model, and `pocket/sync`'s built CLI from earlier phases if
they already exist at their default paths (`LLAMA_CPP_DIR`, `VENV_DIR`,
`MODEL_PATH` env vars override); builds them otherwise. Set
`NEX_ZI_KEEP_LOGS=1` to keep the run's working directory (namespace
logs, saved Automerge docs, event log) after a failure instead of
deleting it.
