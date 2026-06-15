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
    inputs@{ self, paseo, ... }:
    {
      # nixosModules.agent — the per-user agent profile. paseo is captured from
      # THIS flake's pin (not the consumer's inputs), so a consumer needs no
      # paseo input of its own. Override the package per-host via
      # `osf.agent.paseoPackage` (see default.nix, R2).
      nixosModules.agent = import ./modules/nixos/agent { paseoFlake = paseo; };
      nixosModules.default = self.nixosModules.agent;
    };
}
