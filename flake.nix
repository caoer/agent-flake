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
    # Pinned to the rev osfiles currently runs (e446d900) so the first-diff
    # re-import is byte-equivalent; bump this single line to move the fleet.
    paseo = {
      url = "github:getpaseo/paseo/e446d9009f05b5e69d7bd076196dd523ade2df61";
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

      # homeModules.agentHome — the platform-neutral home-manager fragment
      # (option `osf.agentHome`: ucc PATH wiring, claude→launcher link, system
      # prompt, paseo config, codex). Foreign / HM-standalone consumers that
      # CANNOT use the full NixOS module import this directly (e.g. osfiles
      # Foreign hosts' hosts/<host>/home.nix). The NixOS module imports the
      # same file in-tree, so both paths share one source of truth.
      homeModules.agentHome = import ./modules/agent/hm.nix;
      homeModules.default = self.homeModules.agentHome;

      # packages.<system>.paseo — the central paseo pin, re-exported so a
      # Foreign / HM consumer (no NixOS module; hand-rolled systemd) gets the
      # SAME paseo as the fleet without declaring its own paseo input.
      packages = forAllSystems (system: {
        paseo = paseo.packages.${system}.paseo;
        default = paseo.packages.${system}.paseo;
      });
    };
}
