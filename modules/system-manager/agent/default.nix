# modules/system-manager/agent — Foreign (non-NixOS) agent profile SYSTEM layer.
#
# The system-manager equivalent of nixosModules.agent's system layer: a
# version-gated ucc installer + a paseo daemon, as system-manager systemd units
# (Foreign hosts have no NixOS users / sops / home-manager options). Shares the
# installer-script and paseo-config render with the NixOS module via
# modules/agent/lib.nix — ONE source of truth across both platforms.
#
# What this module does NOT own (Foreign-specific; stays with the consumer):
#   - secret DELIVERY: the consumer declares its own foreign.secrets (which
#     sopsFile/key) and passes the resulting on-host paths here. The module
#     reads those paths; it never references the foreign.secrets option (which
#     lives in the consumer, not agent-flake).
#   - the HM layer (system prompt, codex, claude settings, paseo CLI): the
#     consumer imports homeModules.agentHome in its home.nix, like any host.
#
# Factory form `{ paseoFlake }: <module>` mirrors nixosModules.agent: paseo is
# captured from THIS flake's pin, overridable via osf.agentForeign.paseoPackage.
{ paseoFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentLib = import ../../agent/lib.nix { inherit pkgs; };
in
{
  imports = [
    ./ucc.nix
    ./paseo.nix
  ];

  options.osf.agentForeign = {
    enable = lib.mkEnableOption "Foreign (system-manager) agent profile system layer (ucc installer + paseo daemon)";

    username = lib.mkOption {
      type = lib.types.str;
      description = "Existing system username that owns the agent profile units.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      description = "Absolute home directory of `username` on the target host.";
    };

    uccVersion = lib.mkOption {
      type = lib.types.str;
      default = agentLib.defaultUccVersion;
      defaultText = lib.literalExpression "agent-flake's central defaultUccVersion (modules/agent/lib.nix)";
      description = ''
        Desired ccc-statusd version. Shares the fleet-wide central default with
        the NixOS module (modules/agent/lib.nix). Bump → deploy → installer
        re-runs (nix as updater); same version → skips in <1s.
      '';
    };

    paseoPackage = lib.mkOption {
      type = lib.types.package;
      default = paseoFlake.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
      defaultText = lib.literalExpression "agent-flake's pinned paseo.packages.\${system}.paseo";
      description = ''
        Paseo package for the daemon + CLI. Defaults to the flake's central pin;
        override for a patched build (e.g. inputs.agent.packages.<system>.paseo-speech).
      '';
    };

    paseoConfigFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to this host's paseo config JSON (with the @UCC_BIN@ placeholder).
        REQUIRED. Rendered into the store with the ucc bin dir injected; a
        WRITABLE copy is installed at ~/.paseo/config.json on every daemon start
        (paseo writeFileSync's that path; a read-only store symlink EROFS-crashes).
      '';
    };

    paseoListen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:6767";
      description = "PASEO_LISTEN for the daemon (loopback by default — no daemon password needed).";
    };

    installerUrlPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/ucc_installer_url";
      description = "On-host path where the consumer's secret delivery places the user+token-scoped UCC installer URL.";
    };

    encryptionPasswordPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/ucc_encryption_password";
      description = "On-host path where the consumer's secret delivery places the UCC ENCRYPTION_PASSWORD.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "CLAUDE_CONFIG_DIR=/home/cos-user/.local/share/ucc/shared" ];
      description = ''
        Extra systemd Environment= lines for the paseo daemon (and so every
        agent it spawns), e.g. a shared CLAUDE_CONFIG_DIR. A per-provider env in
        config.json does NOT propagate to agents — it must live on the unit.
      '';
    };
  };
}
