# pocket

Phase 4 client (`CLAUDE.md` §5): the "body" — a store-and-forward queue,
an offline local model, and CRDT sync on reconnect. Exit criteria
verified end to end (`pocket/scripts/pocket-demo.sh`, wired into CI,
reran clean across repeated runs): five questions answered fully
offline (real network namespace, no WAN route), queued locally, then
synced to the hub within seconds of reconnecting — well inside the
60-second budget — arriving in correct order, traceable, and mirrored
into the hub's real event log.

## What's real

- **`pocket/sync/`** — a real Kotlin/JVM module (plain `gradle test`,
  no Android SDK needed), SQLite-backed, unit-tested. This is the
  store-and-forward queue itself: durable, ordered, and it's what a
  real Android build would actually ship.
- **`pocket/local-model/offline_answer.py`** — a real offline answer
  from the hub's own llama-server, exercised entirely inside a network
  namespace with no WAN route.
- **CRDT merge on reconnect** — the queued interactions get replayed as
  real Automerge events via `sync-protocol/`'s already-proven `Peer`
  (Phase 1), synced with a hub peer, and verified to arrive complete,
  in order, within the 60-second budget.
- **The hub/phone event-log gap, closed** — Phase 2 built the hub's
  interaction log (`hub/memory/eventlog.py`) as plain SQLite, without
  ever wiring it to Phase 1's CRDT sync layer. This demo closes that
  gap for real: synced events get mirrored into that same real SQLite
  log, tagged `pocket-relayed`, so a synced interaction is queryable
  the same way a locally-asked one is.

## What isn't built, and why

**No real Android build.** `pocket/client/` is real Kotlin/Compose
source — written, reviewable, depends on `pocket/sync/`'s actual public
API — but it does not compile in this environment. Verified, not
assumed: the Android Gradle Plugin itself fails to resolve (`gradle
projects` on that module fails at plugin resolution, searching Google's
repository among others) because `dl.google.com` is blocked by this
environment's network policy, the same restriction that blocks
huggingface.co (`hub/models/README.md`) and Docker Hub
(`hub/dreaming/README.md`). No Android SDK, no emulator (no `/dev/kvm`
either), so nothing Android-specific here has run.

**No on-device CRDT binding.** A real phone needs the Automerge merge
logic running natively on-device — in practice, a JNI binding to
`automerge-rs`. Building that binding is a real, substantial project of
its own, not something to fake with a thin wrapper. This demo uses
`sync-protocol/`'s existing Node.js `Peer` as the reconnect-time merge
engine instead, standing in for that binding. `pocket/sync/`'s
`OfflineQueue` — the part that *is* built for real — hands off to it
through a CLI seam, the same integration pattern used everywhere else
in this repo (`hub/agent/agent.py`, `hub/dreaming/consolidate.py`).

**`OfflineQueue`'s persistence doesn't run on Android as-is.**
`org.xerial:sqlite-jdbc` is a desktop/JVM JDBC driver; Android has its
own SQLite bindings. A real Android build needs the same public
interface backed by `androidx.room` or `android.database.sqlite`
instead — noted in `pocket/client/build.gradle.kts`, not silently
assumed to work.

**MLC LLM substituted with llama.cpp.** `DEPENDENCIES.md` names MLC LLM
for the phone's offline fallback. The offline model here reuses
llama.cpp + the hub's synthetic-weight Qwen2 GGUF instead
(`hub/models/README.md` explains the synthetic weights) — real
trained weights for a phone-sized model hit the exact same
network-policy wall as the hub's. Benchmarking MLC LLM/NCNN/MNN once
real weights and a real phone exist is tracked as follow-up, not
skipped silently.

**Voice input not implemented.** Faster-Whisper integration is a named
Phase 4 bring-up item; this session built the text path and the
exit-criteria test, which don't require it. `pocket/client/MainActivity.kt`
has no working microphone button — it doesn't pretend to.

**Modem kill switch — UI only, no hardware.** `pocket/client/ModemKillSwitch.kt`
models the state as a first-class UI element per the plan, but there is
no phone and no modem in this environment to read a real signal from —
same "no real hardware" caveat that applies to the Jetson/Sophon dev
boards throughout this project.

## Running it

```sh
sudo pocket/scripts/pocket-demo.sh
```

Needs root (the airplane-mode network namespace). Builds `pocket/sync`,
llama.cpp, and the synthetic model on first run if they don't already
exist. `pocket/sync/`'s own tests can be run independently with no
root and no other dependencies:

```sh
cd pocket/sync && gradle test
```
