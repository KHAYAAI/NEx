# pocket/client

The pocket app shell (`CLAUDE.md` Phase 4): real Kotlin/Compose source
— `MainActivity.kt`, `PocketViewModel.kt`, `ModemKillSwitch.kt` — but
**not buildable in this environment**. See `pocket/README.md` for the
full picture; this file covers just this module.

## What was actually verified, and how

Running `gradle projects` against this module fails at plugin
resolution:

```
Plugin [id: 'com.android.application', version: '8.6.0'] was not found in any of the following sources:
...
  Searched in the following repositories:
    Google
    Gradle Central Plugin Repository
    MavenRepo
```

That's `dl.google.com` being blocked by this environment's network
policy — the same class of restriction documented for huggingface.co
(`hub/models/README.md`) and Docker Hub (`hub/dreaming/README.md`).
There's no Android SDK here either, and no `/dev/kvm` for an emulator
even if there were. So: this module's source is real and reviewable,
its dependency on `pocket/sync/`'s actual API is real, but nothing
here has compiled, let alone run.

`pocket/sync/` was originally set up as a Gradle sub-module of this one
(a single multi-project build) so `implementation(project(":sync"))`
would actually resolve. That was reverted: because Gradle configures
every module in a build before running any task, this module's broken
plugin resolution blocked even running `pocket/sync/`'s tests —
verified by trying it. They're two separate Gradle projects now, so
the module that does build and test for real isn't held hostage by the
one that can't.

## UI notes

- The modem kill-switch state renders at the same level as the
  question box, not in a settings menu — CLAUDE.md's "first-class UI
  element, not an afterthought." There's no real hardware signal to
  read (`ModemKillSwitch.kt`'s `UnavailableModemKillSwitchReader`), so
  it always shows `UNKNOWN` here.
- Text Q&A only — no voice input wired up (Faster-Whisper is a named
  Phase 4 bring-up item, not implemented this session).
- The "Ask" button doesn't call a real model — on-device inference
  (llama.cpp's own Android JNI bindings would be the real path) is a
  `TODO` in source, not something faked.
