# pocket/sync

The pocket node's store-and-forward queue (`CLAUDE.md` Phase 4): real
Kotlin/JVM, SQLite-backed, unit-tested. See `pocket/README.md` for how
this fits into the rest of Phase 4, including what it deliberately
doesn't do (the actual on-device CRDT merge).

Deliberately **pure JVM** — no Android Gradle Plugin dependency, so it
builds and tests with plain `gradle`, no Android SDK required. This
environment has neither (`dl.google.com` is blocked — see
`pocket/README.md`), so this is the one piece of Phase 4 that's fully
buildable, testable, and verified here, and it's kept that way on
purpose: `pocket/client/` depends on this module's real, tested API,
not the other way around.

## Files

- `OfflineQueue.kt` — the queue itself: `enqueue`, `pending` (oldest
  first — order matters per the exit criteria), `markSynced`.
- `Cli.kt` — a thin CLI wrapper (`enqueue` / `pending` / `mark-synced`
  subcommands) so `pocket/scripts/pocket-demo.sh` can drive it from a
  shell script without a JVM↔shell binding library.
- `OfflineQueueTest.kt` — JUnit 5 tests: ordering, marking synced,
  surviving a reopen against the same file, empty-list no-op.

## Running it

```sh
gradle test              # unit tests
gradle installDist       # builds the CLI at build/install/nex-pocket-sync/bin/
```

## Known gap: this exact persistence layer doesn't run on Android

`org.xerial:sqlite-jdbc` gives this module real, working, JDBC-based
SQLite on the desktop JVM — genuinely tested here — but it's a native
JNI driver built for desktop platforms, not Android's runtime. A real
Android build needs `OfflineQueue`'s same public API backed by
`androidx.room` or `android.database.sqlite` instead. That's a
swap-the-implementation-behind-the-interface job, not a rewrite of the
logic this module already gets right — but it hasn't been done, and
`pocket/client/build.gradle.kts` says so rather than assuming it works.
