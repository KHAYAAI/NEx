# infra/multi-hub-mesh

Phase 7 (`CLAUDE.md` §5, **stretch goal, not required for v0 ship**):
"Evaluate `exo` (exo-explore/exo) for pooling compute across multiple
hub units in the same household... Only start this once Phases 1-6 are
stable and shipping." Phases 1-6 are done (see the root `README.md`
Status section), so this is that evaluation — hands-on, not a reading
of exo's docs. `exo-evaluation.sh` reproduces every step below for
real; rerun it to re-verify these findings rather than take them on
faith.

Evaluated at exo commit `21a54c5ea0230a3bec1e1a786d200126c7e34ec6`
(2026-08-25). exo moves fast (it's a live Rust+Python rewrite with a
Svelte dashboard, RDMA-over-Thunderbolt work in flight); these findings
are dated and may not hold against a later commit — re-run the script
against current `main` if this evaluation is revisited.

## What's real here

- A real, from-scratch clone of exo-explore/exo.
- A real build of its dashboard (`dashboard/`, SvelteKit) via
  `npm install && npm run build` — this actually completed and
  produced a working static build.
- A real Rust nightly toolchain install (exo's Rust bindings need it).
- A real, complete dependency resolution and install via
  `uv sync --extra mlx-cpu` — exo's own documented path for "Linux,
  CPU-only" (its README states GPU support for Linux is still under
  development, so CPU is the intended Linux story today). This pulled
  and installed exo's entire real dependency graph: MLX, mlx-lm,
  mlx-vlm, transformers, torch (CPU wheels), zenoh's Python bindings,
  and more — over 150 packages, several from pinned fork commits exo
  itself depends on (e.g. `mlx-lm` from a `rltakashige/mlx-lm` fork
  branch). This alone is a meaningful, verified finding: exo's Linux
  build story is real and current, not vestigial next to its
  Apple-Silicon-first marketing.

## What's broken, found and diagnosed by actually running it

### 1. `uv sync --extra mlx-cpu` installs an MLX build that can't import, on Linux

exo's `pyproject.toml` defines a separate `mlx-cpu==0.31.2` PyPI
package for the CPU extra, but the actual `mlx` package it depends on
(the one whose `mlx.core` the code imports) is pinned via a
`[tool.uv.sources]` override to a **direct wheel URL**, with the same
URL selected regardless of which extra (`mlx-cpu`, `mlx-cuda12`,
`mlx-cuda13`) was requested:

```toml
mlx = [
  { url = ".../mlx-0.32.0-cp313-cp313-manylinux_2_35_x86_64.whl", marker = "sys_platform == 'linux' and platform_machine != 'aarch64'" },
]
```

That wheel is built for CUDA (its release path is literally named
`mlx_cuda`). So on a genuinely CPU-only Linux machine with `mlx-cpu`
requested, the environment ends up with both `mlx-cpu-0.31.2` (a real
CPU-compatible shared-lib package) *and* `mlx-0.32.0` (the CUDA build)
installed side by side — and the CUDA build is the one Python actually
imports as `mlx.core`. Importing it fails outright:

```
ImportError: .../mlx/core.cpython-313-x86_64-linux-gnu.so: undefined symbol:
_ZN3mlx4core6linalg3detERKNS0_5arrayESt7variantIJSt9monostateNS0_6StreamENS0_17ThreadLocalStreamENS0_6DeviceEEE
```

Confirmed this isn't a local-environment fluke: no CUDA runtime or
GPU exists in this container at all (`nvidia-smi` not found, no
`/usr/local/cuda*`), so there is no way that wheel could have worked
here even with the right symbols present — the wheel itself is simply
the wrong build for a CPU-only Linux install, as pinned in exo's own
`pyproject.toml` at this commit.

### 2. Coordinator-only mode (`--no-worker`) avoids MLX, but hits a second, sandbox-specific blocker

exo documents `--no-worker` as the mode "for machines without
sufficient GPU resources but with good network connectivity." Running
with it confirmed that MLX is genuinely never imported in this mode —
progress past finding #1 entirely. It then failed differently, at the
networking layer:

```
RuntimeError: Can not create a new TCP listener bound to tcp/[::]:55001:
[Os { code: 97, kind: Uncategorized, message: "Address family not supported by protocol" }]
```

Traced to `rust/networking/src/lib.rs`:

```rust
cfg.insert_json5("listen/endpoints", &format!("[\"tcp/[::]:{listen_port}\"]"))?;
```

exo's zenoh transport listener is hardcoded to the IPv6 wildcard
address, with no CLI flag or environment variable to force an IPv4
bind instead. This container has **no IPv6 support at the kernel
level at all** — confirmed directly: there's no `/proc/net/if_inet6`,
and even a bare `socket.socket(socket.AF_INET6, ...)` raises
`OSError: [Errno 97] Address family not supported by protocol` before
exo is involved at all. That's a property of this specific sandbox,
not a general claim about NEx's real target hardware (Jetson, Sophon
SE9, an ordinary dev box) — those almost certainly have IPv6 at least
on loopback. But it does mean **no live two-node discovery or mesh
demo could be produced in this evaluation environment**, and that gap
is disclosed here rather than faked with a mocked "peers discovered"
message.

## What this means for NEx

exo solves a genuinely different problem than Phase 1's CRDT sync (as
`CLAUDE.md` already says): compute *partitioning* for models too big
for one hub unit, not state *consistency* for the event log. That
framing holds up — nothing found here contradicts it. But two things
argue for leaving exo out of the v0 architecture and revisiting only
if/when a real multi-hub household actually needs bigger-than-one-box
models:

1. Its CPU-only Linux path — the one relevant to NEx's actual target
   tiers (Sophon SE9/RK3588, no GPU; even Jetson isn't x86_64 CUDA
   the way exo's own CUDA wheel assumes) — is broken *today*, upstream,
   independent of anything in NEx. Integrating it now would mean
   carrying a fork or a pinned patch of someone else's dependency
   resolution, which cuts against `CLAUDE.md`'s own reasoning for
   avoiding OpenClaw/Hermes in D4: less auditable, more moving parts
   NEx doesn't control.
2. exo's actual maturity, resource model, and primary use case (Apple
   Silicon clusters, RDMA over Thunderbolt, pooling *very* large
   models like DeepSeek/Kimi-K2) don't match NEx's dev-phase hardware
   tiers (Decision D3) at all. It's aimed at a different hardware
   profile than the one this project is actually building toward.

**Recommendation:** stay with `CLAUDE.md`'s own framing — additive,
deferred, not required for v0. Revisit once (a) exo's upstream CPU
wheel resolution is fixed (a small, well-understood, reportable bug —
worth filing upstream separately from this repo) and (b) real
Sophon/Jetson dev-board hardware exists to test against, where the
IPv6 blocker found here is unlikely to even apply.

## Why this isn't in CI

Both real blockers found are either an upstream bug in someone else's
repo or a property of this evaluation sandbox specifically — gating
this project's CI on either would mean failing every build over a bug
`exo-explore/exo` owns, or over an IPv6 quirk of this particular
container that has nothing to do with NEx's own code. Neither is what
"acceptance test" should mean here. The script stays runnable and
reproducible (`./exo-evaluation.sh`) for the next time this evaluation
needs revisiting, but it's not wired into
`.github/workflows/acceptance-tests.yml`.

## Running it

```sh
./exo-evaluation.sh
```

Needs `git`, `npm`/`node`, `rustup`, and `uv` on `PATH`. Takes several
minutes (clones exo fresh, builds its dashboard, installs its full
dependency graph). No root required.
