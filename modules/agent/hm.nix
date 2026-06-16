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

  # Claude settings.json deploy (osf.agentHome.claudeSettings) — the Foreign /
  # HM-standalone analogue of the NixOS path's agent-claude-settings-<user>
  # systemd unit (ucc.nix) and of locus `just preset`: write one settings.json
  # into every ucc profile + merge a small .claude.json patch. Profiles are
  # created by the ucc installer at runtime, so a glob-loop in an activation
  # step (not home.file) is the only way to reach them; preset-bak mirrors the
  # locus backup. On NixOS hosts this stays null (the systemd unit owns the
  # deploy) — no double-apply.
  settingsFile = pkgs.writeText "claude-settings.json" (builtins.toJSON cfg.claudeSettings);
  claudeJsonPatch = builtins.toJSON {
    autoUpdates = false;
    autoCompactEnabled = false;
  };
  applyClaudeSettings = pkgs.writeShellScript "apply-claude-settings" ''
    set -euo pipefail
    profiles="${home}/.local/share/ucc/profiles"
    [ -d "$profiles" ] || { echo "ucc profiles dir absent — skipping settings deploy"; exit 0; }
    count=0
    for pf in "$profiles"/*/settings.json; do
      [ -f "$pf" ] || continue
      dir=$(dirname "$pf")
      cp "$pf" "$dir/settings.json.preset-bak" 2>/dev/null || true
      cp ${settingsFile} "$pf"
      # Merge keys into .claude.json, preserve the rest (create if missing).
      cj="$dir/.claude.json"
      if [ -f "$cj" ]; then
        ${pkgs.jq}/bin/jq '. * ${claudeJsonPatch}' "$cj" > "$cj.tmp" && mv "$cj.tmp" "$cj"
      else
        echo '${claudeJsonPatch}' > "$cj"
      fi
      count=$((count + 1))
    done
    echo "claude settings: applied to $count profile(s)"
  '';
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
      description = "Install the codex CLI (osf.agentHome.codex.package) — paseo's native codex provider drives it.";
    };

    codex.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/codex.nix { };
      defaultText = lib.literalExpression "agent-flake's pinned packages/codex.nix (ahead of nixpkgs)";
      description = ''
        codex CLI package. Defaults to agent-flake's pinned build (one fleet
        version, bumped centrally in packages/codex.nix). Override per-host for
        an outlier (e.g. pkgs.codex from nixpkgs).
      '';
    };

    codexConfigSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        codex config → ~/.codex/config.toml. String = out-of-store symlink
        (live-edit), path = store copy. null = unmanaged. Only config.toml is
        declarative — codex's runtime state (goals/state/memories/logs sqlite,
        installation_id, OAuth) stays mutable per-host, never in the nix store.
      '';
    };

    claudeSettings = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = ''
        Claude Code settings.json content (attrset). When set, an HM activation
        applies it to every ~/.local/share/ucc/profiles/*/settings.json (backing
        the prior file up to settings.json.preset-bak) and merges
        {autoUpdates, autoCompactEnabled} = false into each profile's
        .claude.json. The Foreign / HM-standalone analogue of the NixOS path's
        agent-claude-settings-<user> systemd unit (which owns this deploy on
        NixOS hosts — leave this null there to avoid a double-apply). The ucc
        installer creates profiles at runtime, so this runs on each HM switch
        over whatever profiles exist. null = unmanaged.
      '';
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

      packages = lib.optional cfg.codex.enable cfg.codex.package;

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
      }
      // lib.optionalAttrs (cfg.codexConfigSource != null) {
        # config.toml only — siblings (the *.sqlite runtime DBs) are left alone.
        ".codex/config.toml" = {
          source = resolve cfg.codexConfigSource;
          force = true;
        };
      };

      # Settings deploy — runtime ucc profiles can't be reached by home.file, so
      # apply over the glob in an activation step (after the writeBoundary, where
      # mutating the live home is allowed). $DRY_RUN_CMD keeps `build`/dry-run
      # side-effect-free.
      activation = lib.optionalAttrs (cfg.claudeSettings != null) {
        deployClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD ${applyClaudeSettings}
        '';
      };
    };
  };
}
