# modules/nixos/agent — shared agent profile module set (standalone flake).
#
# One "agent profile" per user: UCC (ccc-statusd + Claude Code profiles),
# claude → ucc-auto link, nix-defined Claude Code profile settings, system
# prompt, paseo daemon, OpenAI codex CLI. Extracted from osfiles
# (modules/nixos/agent) into a standalone flake so osfiles + the semi-managed
# member fleet import ONE source of truth.
#
# Factory form: `{ paseoFlake }: <nixos-module>`. The flake's outputs apply it
# with its own pinned `paseo`, so consumers need no paseo input. The paseo
# PACKAGE is overridable per-host via `osf.agent.paseoPackage` (R2) — an
# outlier (e.g. yangming's speech-worker patch) overrides without forcing the
# patch on everyone.
#
# The system prompt is a live-edit file (out-of-store symlink into the HOST's
# checkout — `osf.agent.repoRoot` must point at a checkout that exists on the
# target). paseo's ~/.paseo/config.json is nix-rendered into the store from a
# CONSUMER-SUPPLIED JSON (`osf.agent.users.<name>.paseoConfigFile`, REQUIRED —
# R3) with the @UCC_BIN@ placeholder injected, then materialized as a writable
# copy by paseo.nix's ExecStartPre install — rebuild to change.
#
# Multi-user: each user gets ucc-update-<user>, agent-claude-settings-<user>,
# paseo-<user> units. On a multi-user host, set distinct sops secret names
# (installerUrlSecret/encryptionPasswordSecret) per user and a distinct
# daemon.listen port in each user's paseo config file.
#
# Consumer requirements: provides `pkgs`, sops-nix, and the home-manager NixOS
# module (ucc.nix wires `home-manager.users`). Guarded by osf.agent.enable.
{ paseoFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agent;
  agentLib = import ../../agent/lib.nix { inherit pkgs; };

  userOpts = lib.types.submodule (_: {
    options = {
      systemPromptSource = lib.mkOption {
        type = lib.types.either lib.types.path lib.types.str;
        default = ../../../assets/SYSTEM_PROMPT.md;
        defaultText = lib.literalExpression "agent-flake's canonical assets/SYSTEM_PROMPT.md (immutable store copy)";
        description = ''
          Claude Code system prompt → ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
          (ucc-auto passes it via --system-prompt-file). Defaults to
          agent-flake's canonical prompt as a nix PATH → an immutable store copy,
          so the fleet stays uniform (rebuild to change). Per-host ESCAPE HATCH:
          set a STRING absolute path (e.g.
          "''${config.osf.agent.repoRoot}/config/agent/SYSTEM_PROMPT.md") for an
          out-of-store live-edit symlink, or another nix path for a different
          store copy.
        '';
      };
      paseoConfigFile = lib.mkOption {
        type = lib.types.path;
        # REQUIRED — no default (R3). Each consumer supplies its OWN paseo
        # config JSON (relay endpoint, providers, daemon.listen port are all
        # consumer-specific). Leaving it unset fails loud at eval ("option …
        # paseoConfigFile is used but not defined") rather than silently
        # inheriting another consumer's relay/providers. The module owns the
        # render mechanism (@UCC_BIN@ → ucc bin dir); the consumer owns the JSON.
        description = ''
          Path to this user's paseo config JSON (with the @UCC_BIN@
          placeholder). REQUIRED when paseo.enable. The module renders it
          into the store and paseo.nix installs a writable copy at
          ~/.paseo/config.json on every daemon start.
        '';
      };
      installerUrlSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_installer_url";
        description = ''
          sops secret name (in the host's defaultSopsFile) holding the
          user+token scoped UCC installer URL. Per-user identity — give
          each user on a multi-user host their own key.
        '';
      };
      encryptionPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_encryption_password";
        description = ''
          sops secret name (in the host's defaultSopsFile) holding the
          UCC ENCRYPTION_PASSWORD. Shared across hosts; duplicated into
          the host yaml (zt-agent-v2 precedent) instead of widening
          common.yaml's recipient list.
        '';
      };
      claudeSettings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Per-user overrides recursively merged over the module's base
          Claude Code settings.json (hooks, statusline, model, env —
          see ucc.nix baseClaudeSettings). The merged result is synced
          into every UCC profile's settings.json by
          agent-claude-settings-<user>.
        '';
      };
      codex.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the OpenAI codex CLI (nixpkgs) for this user (paseo's native codex provider drives it).";
      };
      paseo = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run a paseo daemon for this user (paseo-<user>.service).";
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Extra environment for the paseo daemon (e.g. PASEO_HOSTNAMES).";
        };
      };
    };
  });
in
{
  imports = [
    ./ucc.nix
    ./paseo.nix
  ];

  options.osf.agent = {
    enable = lib.mkEnableOption "agent profile (ucc + claude + paseo + codex) for the configured users";

    repoRoot = lib.mkOption {
      type = lib.types.str;
      default = config.osf.repoRoot;
      description = ''
        osfiles/consumer checkout root ON THE TARGET HOST. The system prompt
        out-of-store symlink target resolves under it (paseo config is
        nix-rendered, not symlinked). Defaults to `config.osf.repoRoot` for
        the osfiles consumer; consumers without that option MUST set this.
      '';
    };

    uccVersion = lib.mkOption {
      type = lib.types.str;
      default = agentLib.defaultUccVersion;
      defaultText = lib.literalExpression "agent-flake's central defaultUccVersion (modules/agent/lib.nix)";
      description = ''
        Desired ccc-statusd version. The fleet-wide central default lives in
        modules/agent/lib.nix (shared with the Foreign module). Bump → rebuild →
        installer re-runs (nix as updater). Override per-host with
        osf.agent.uccVersion.
      '';
    };

    paseoPackage = lib.mkOption {
      type = lib.types.package;
      default = paseoFlake.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
      defaultText = lib.literalExpression "agent-flake's pinned paseo.packages.\${system}.paseo";
      description = ''
        Paseo package for the daemon + CLI. Defaults to the flake's central
        paseo pin. Override per-host (R2) for an outlier that needs a patched
        build, e.g. `pkgs.paseo-or-flake-pkg.overrideAttrs (…)` — without
        forcing that patch on the rest of the fleet.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = { };
      description = "Users that get the agent profile. Key = existing system username.";
    };
  };
}
