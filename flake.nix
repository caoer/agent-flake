{
  description = "Agent profile (ucc + claude + paseo + codex) as a standalone NixOS module";

  inputs = {
    # Present only so `paseo` can `follows` it. The module never reads nixpkgs
    # directly — it uses the consumer's `pkgs`. Consumers MUST set
    #   inputs.agent.inputs.nixpkgs.follows = "nixpkgs";
    # so paseo builds against the consumer's nixpkgs (no duplicate closure).
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # THE central paseo pin for the whole fleet. One bump here (rev below or
    # `nix flake update paseo`) reaches every consumer that imports this flake.
    # Pinned to a specific rev — bump this single line to move the fleet.
    paseo = {
      url = "github:getpaseo/paseo/d0189f3f65";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, nixpkgs, paseo, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # nixosModules.agent — the per-user agent profile. paseo is captured from
      # THIS flake's pin (not the consumer's inputs), so a consumer needs no
      # paseo input of its own. Override the package per-host via
      # `osf.agent.paseoPackage` (see default.nix, R2).
      nixosModules.agent = import ./modules/nixos/agent { paseoFlake = paseo; };
      nixosModules.default = self.nixosModules.agent;

      # systemManagerModules.agent — the Foreign (non-NixOS, system-manager)
      # equivalent of nixosModules.agent's SYSTEM layer: the per-user paseo
      # daemon + version-gated ucc installer, hand-rolled as system-manager
      # systemd units (no users/sops NixOS options). Shares the installer-script
      # / paseo-config-render / agentPath logic with the NixOS module via
      # modules/agent/lib.nix — ONE source of truth across both platforms. The
      # consumer wires its own secret delivery (foreign.secrets) and passes the
      # resulting on-host paths; the module owns everything else. The HM layer
      # is the same homeModules.agentHome both platforms import.
      systemManagerModules.agent = import ./modules/system-manager/agent { paseoFlake = paseo; };
      systemManagerModules.default = self.systemManagerModules.agent;

      # homeModules.agentHome — the platform-neutral home-manager fragment
      # (option `osf.agentHome`: ucc PATH wiring, claude→launcher link, system
      # prompt, paseo config, codex). Foreign / HM-standalone consumers that
      # CANNOT use the full NixOS module import this directly (e.g. osfiles
      # Foreign hosts' hosts/<host>/home.nix). The NixOS module imports the
      # same file in-tree, so both paths share one source of truth.
      homeModules.agentHome = import ./modules/agent/hm.nix;
      homeModules.default = self.homeModules.agentHome;

      # packages.<system>:
      #   paseo         — the central paseo pin, re-exported so a Foreign / HM
      #                   consumer gets the SAME paseo as the fleet with no own
      #                   paseo input.
      #   codex         — OpenAI codex CLI pinned ahead of nixpkgs (the fleet's
      #                   agent provider). One bump here moves every host.
      #   paseo-speech  — paseo + the local-speech-worker trace patch
      #                   (dictation/voice). Hosts that need speech set
      #                   `osf.agent.paseoPackage = …paseo-speech` instead of
      #                   carrying the patch file + overrideAttrs boilerplate.
      # codex + paseo-speech are x86_64-linux-only (the member fleet's platform:
      # codex ships an x86_64-linux musl binary; the speech patch targets the
      # Linux sherpa-onnx runtime).
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          paseoPkg = paseo.packages.${system}.paseo;
        in
        {
          paseo = paseoPkg;
          default = paseoPkg;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          codex = pkgs.callPackage ./packages/codex.nix { };
          paseo-speech = paseoPkg.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./packages/paseo-speech-worker-trace.patch ];
          });
        }
      );
    };
}
