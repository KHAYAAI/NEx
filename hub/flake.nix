/*
  Hub OS declarative config — Decision D2 (docs/DECISIONS.md): NixOS
  native generations/rollback, no OSTree/RAUC on the hub.

  Status: written, NOT validated. This environment has no `nix`
  installed, so `nix flake check` / `nixos-rebuild build` have not been
  run against this file — unlike everything else committed so far in
  Phase 1/2, which was built and actually executed. Treat this as a
  reviewable draft of the intended module structure, not as proven
  working config. It should be the first thing checked with real Nix
  tooling once real dev-board hardware (Decision D3) is available.

  What it declares:
    - llama-server as a systemd service, serving the model at
      hub/models/ (swap the synthetic model for a real Qwen3 GGUF once
      one exists — see hub/models/README.md).
    - the agent CLI's Python environment (mcp, httpx) reproducibly,
      instead of the ad-hoc venv used to develop/test it in this
      environment.
    - the event log's data directory.

  Deliberately NOT yet declared: Letta/Qdrant, Home Assistant, the
  Headscale/WireGuard tunnel service (infra/headscale/,
  infra/wireguard-poc/) — those are still their own untracked-by-Nix
  pieces per their own READMEs, and folding them into this flake is
  follow-up work, not done here.
*/
{
  description = "NEx hub node — Phase 2 software stack (CLAUDE.md)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux"; # swap for aarch64-linux on the real Jetson/Sophon dev boards (Decision D3)
      pkgs = nixpkgs.legacyPackages.${system};

      hubPython = pkgs.python3.withPackages (ps: [
        ps.httpx
        # `mcp` (the Model Context Protocol SDK) isn't in nixpkgs as of
        # this writing; package it via poetry2nix/buildPythonPackage once
        # this flake is actually built against real Nix tooling. Tracked
        # here rather than silently omitted.
      ]);
    in
    {
      nixosModules.hub = { config, lib, pkgs, ... }: {
        options.nex.hub = {
          enable = lib.mkEnableOption "the NEx hub stack";
          modelPath = lib.mkOption {
            type = lib.types.path;
            description = "Path to the GGUF model llama-server should load.";
          };
          dataDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/nex-hub";
            description = "Where the event log and other hub state live.";
          };
        };

        config = lib.mkIf config.nex.hub.enable {
          systemd.services.nex-llama-server = {
            description = "NEx hub — local model server (llama.cpp)";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              # llama.cpp isn't packaged in nixpkgs in a form pinned to
              # this repo's build (Phase 1/2 built it from source under
              # /tmp for testing) — real deployment should package it as
              # its own derivation (pkgs.callPackage) rather than assume
              # a pre-built binary lives at this literal path.
              ExecStart = "/run/current-system/sw/bin/llama-server "
                + "-m ${config.nex.hub.modelPath} "
                + "--host 127.0.0.1 --port 8090";
              Restart = "on-failure";
              DynamicUser = true;
              StateDirectory = "nex-hub";
            };
          };

          systemd.tmpfiles.rules = [
            "d ${config.nex.hub.dataDir} 0750 root root -"
          ];

          environment.systemPackages = [ hubPython ];
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ hubPython pkgs.sqlite ];
      };
    };
}
