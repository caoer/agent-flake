# modules/agent/hm.nix — shared home-manager fragment of the agent profile.
#
# Platform-neutral HM module consumed by BOTH:
#   - modules/nixos/agent (NixOS hosts: imported per user, sources are
#     strings → out-of-store symlinks into the host's osfiles checkout)
#   - Foreign/HM-standalone hosts (e.g. hosts/cos-ucc/home.nix: sources are
#     nix paths → store copies, for hosts without a checkout)
#
# Owns: ucc PATH wiring + UCC_HOME, claude → ucc launcher link, system
# prompt file, paseo config.json, codex CLI. The ucc installer and the
# paseo/settings-sync units are platform-specific and live with the caller.
#
# Source type semantics (systemPromptSource / paseoConfigSource):
#   string   → out-of-store symlink (live-edit; target must exist on host)
#   nix path → copied into the store (immutable; rebuild to change)
#
# force = true on owned files: the ucc installer (claude link) and manual
# setup (system prompt) may have left real files — HM takes them over.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agentHome;
  home = config.home.homeDirectory;

  sourceType = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
  resolve = src: if builtins.isString src then config.lib.file.mkOutOfStoreSymlink src else src;
in
{
  options.osf.agentHome = {
    enable = lib.mkEnableOption "agent profile home layer (ucc paths, claude link, prompts, paseo config, codex)";

    claudeLauncher = lib.mkOption {
      type = lib.types.str;
      default = "ucc-auto";
      description = "ucc launcher (in ~/.local/share/ucc/bin) that ~/.local/bin/claude points at.";
    };

    systemPromptSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        Claude Code system prompt → ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
        (ucc-auto passes it via --system-prompt-file). String = out-of-store
        symlink (live-edit), path = store copy. null = unmanaged.
      '';
    };

    paseoConfigSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        Paseo daemon config → ~/.paseo/config.json. String = out-of-store
        symlink (live-edit), path = store copy. null = unmanaged.
      '';
    };

    codex.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the OpenAI codex CLI (nixpkgs) — paseo's native codex provider drives it.";
    };
  };

  config = lib.mkIf cfg.enable {
    home = {
      sessionPath = [
        "${home}/.local/bin"
        "${home}/.local/share/ucc/bin"
        "${home}/.local/share/ucc/bin/skills-bin"
      ];
      sessionVariables.UCC_HOME = "${home}/.local/share/ucc";

      packages = lib.optional cfg.codex.enable pkgs.codex;

      file = {
        # claude = configured ucc launcher. Dangling until the ucc
        # installer runs; force-restored by rebuild if the installer or a
        # manual `ln -sf` ever repoints it.
        ".local/bin/claude" = {
          source = config.lib.file.mkOutOfStoreSymlink "${home}/.local/share/ucc/bin/${cfg.claudeLauncher}";
          force = true;
        };
      }
      // lib.optionalAttrs (cfg.systemPromptSource != null) {
        ".local/share/ucc/shared/SYSTEM_PROMPT.md" = {
          source = resolve cfg.systemPromptSource;
          force = true;
        };
      }
      // lib.optionalAttrs (cfg.paseoConfigSource != null) {
        ".paseo/config.json" = {
          source = resolve cfg.paseoConfigSource;
          force = true;
        };
      };
    };
  };
}
