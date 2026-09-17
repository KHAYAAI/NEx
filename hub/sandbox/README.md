# hub/sandbox

Phase 6 (`CLAUDE.md` §5): "Move the agent/tool runtime into gVisor or
Firecracker sandboxing on the hub; Wasmtime for anything lightweight
enough to run in-process." Real tools, real checks
(`sandbox-demo.sh`, reran clean multiple times).

## gVisor

Runs `hub/apps/file-search/` — one of the hub's actual MCP apps, not a
placeholder — inside `runsc` (gVisor's OCI-compatible sandbox runtime).
No Docker needed: `runsc do` starts a sandbox directly. Two checks
prove the sandbox is real rather than a no-op:

1. Reading `/proc/version` from inside returns gVisor's well-known
   fake kernel identity (`Linux version 4.4.0 #1 SMP Sun Jan 10
   15:06:54 PST 2016`) — the sandbox's own sentry answering, never the
   real host's kernel.
2. A file written from inside the sandbox is provably absent from the
   real host filesystem afterward — the write landed on gVisor's
   writable overlay, not the real disk.

Uses `-platform=ptrace`, not the default auto-detection: this
environment has no `/dev/kvm` (same constraint noted throughout this
project — no real hardware anywhere, `hub/README.md`,
`pocket/README.md`), and gVisor's KVM platform needs it. `ptrace`
doesn't.

## Wasmtime

Runs a real WebAssembly module (`add.wat`) through the real Wasmtime
runtime. The module is hand-written WAT, not compiled from one of the
hub's actual apps — there's no WASM toolchain available in this
environment to do that compilation (verified: no `rustc` with a wasm
target, no equivalent). This proves Wasmtime itself works correctly
here; it doesn't prove any specific hub component has been ported to
WASM, and none has.

WASM's capability-based sandboxing (a module has zero ambient
filesystem/network access unless the host explicitly grants it via
WASI preopens) is a property of the format and the Wasmtime runtime
itself, well-established and documented rather than re-demonstrated
live here for the same toolchain reason above — there's no real WASI
program available to exercise it against.

## Not Firecracker

No `/dev/kvm` in this environment; Firecracker needs it. gVisor covers
the "sandbox the tool runtime" half of the plan bullet without it.

## Running it

```sh
apt install runsc  # ships in Ubuntu 24.04's universe repo
# wasmtime: download a release tarball from
# github.com/bytecodealliance/wasmtime/releases (no apt package)
./sandbox-demo.sh
```

No root required.
