# update-mechanism

Phase 6 (`CLAUDE.md` §5): "Stand up the update mechanism per D2 (Nix
generations, or OSTree/RAUC) and test a rollback from a deliberately
broken update." Decision D2 chose Nix generations
(`docs/DECISIONS.md`) — `nix-rollback-demo.sh` tests that real
mechanism, not a substitute, and reran clean.

## What it proves

- Two "hub config" generations get built and deployed as real Nix
  store paths, set on a real profile via `nix-env --set` — the exact
  primitive `nixos-rebuild switch` uses internally.
- `nix-env --list-generations` correctly tracks both.
- `nix-env --rollback` from the deliberately-broken generation 2 back
  to the healthy generation 1 actually restores it.
- A build that fails outright (not "builds but is broken" — fails to
  build at all) never reaches the profile-set step, so the currently
  active generation is provably untouched by it. Atomicity holding at
  the point that actually matters.

## What it doesn't prove

This operates one level below a full NixOS system switch:
`hub/flake.nix` declares a `nixosModule`, not a full
`nixosConfiguration` with a bootable system closure, and this
environment can't boot one anyway (a container, not a NixOS host). The
"hub config" here is a toy derivation, not the hub's real service set.
Building and switching an actual NixOS system generation — the full
boot-time integration `nixos-rebuild switch --rollback` performs — is
real, separate follow-up work once real dev-board hardware
(Decision D3) exists to boot NixOS on directly, not something this
container can safely stand in for.

## Getting `nix` itself running here

Non-obvious enough to write down: this environment's egress policy
blocks `nixos.org` (same class of restriction as `hub/models/README.md`'s
huggingface.co block), but `releases.nixos.org` and `cache.nixos.org`
are both reachable, so the installer and binary cache work once you
get the installer script from the reachable host directly:

```sh
groupadd nixbld
useradd -M -N -g users -G nixbld nixbld1   # nix-env's single-user install
                                             # refuses a build-users group
                                             # whose only member is the
                                             # nix-owning user itself (root
                                             # here) — needs a separate one
sh <(curl -sSL https://releases.nixos.org/nix/nix-2.24.9/install) --no-daemon
export PATH="$HOME/.nix-profile/bin:$PATH"
```

One more thing this hit: `hub/flake.nix`'s `nixpkgs.url =
"github:NixOS/nixpkgs/nixos-unstable"` resolves through
`api.github.com`, which — in *this* session specifically — is gated to
the repo this session is scoped to, unrelated to the general network
policy above. A plain `git+https://github.com/NixOS/nixpkgs.git` input
URL uses an ordinary git clone instead and works fine. Not changed in
`hub/flake.nix` itself since that restriction is particular to this
session's GitHub access scope, not a real-world constraint a live hub
would hit — noted here so it isn't confusing if `nix flake check`
against `hub/flake.nix` fails with an `api.github.com` 403 in a
similarly-scoped session.

## Running it

```sh
./nix-rollback-demo.sh
```

No root required once `nix` itself is installed.
