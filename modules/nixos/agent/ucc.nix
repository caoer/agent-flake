# modules/nixos/agent/ucc.nix — per-user UCC + Claude Code profile config.
#
# Extracted from hosts/zt-agent-v2/ucc.nix, generalized to N users.
# Per user:
#   ucc-update-<user>          version-gated UCC installer (nix as updater:
#                              bump osf.agent.uccVersion → rebuild → installer
#                              runs; same version → skips in <1s)
#   agent-claude-settings-<user>  syncs the nix-defined settings.json (+
#                              .claude.json patch) into every UCC profile —
#                              the declarative "claude code profile config"
#                              (preset-activate pattern from locus
#                              wiki/outbox/presets.nix)
#   ~/.local/bin/claude        → ~/.local/share/ucc/bin/ucc-auto
#   ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
#                              → flake-canonical store copy by default
#                              (osf.agent.users.<n>.systemPromptSource; consumed
#                              by ucc-auto via --system-prompt-file). A string
#                              source switches it to a live-edit symlink.
#   codex CLI (flake-pinned)   when codex.enable (paseo's native provider)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agent;
  homeOf = name: config.users.users.${name}.home;

  # Shared installer/render builders — same source the Foreign system-manager
  # module uses, so both platforms run byte-identical ucc-installer logic.
  agentLib = import ../../agent/lib.nix { inherit pkgs; };

  # --- Claude Code profile settings (mirrors locus presets.nix baseSettings) ---
  statusdHook =
    localBin:
    {
      matcher ? "",
      timeout ? null,
    }:
    let
      hookBase = {
        type = "command";
        command = "${localBin}/ccc-statusd hook";
      };
      hookEntry = if timeout != null then hookBase // { inherit timeout; } else hookBase;
    in
    [
      {
        inherit matcher;
        hooks = [ hookEntry ];
      }
    ];

  baseClaudeSettings =
    name:
    let
      home = homeOf name;
      localBin = "${home}/.local/bin";
      uccData = "${home}/.local/share/ucc";
      hook = statusdHook localBin;
    in
    {
      cleanupPeriodDays = 9999;
      env = {
        BASH_MAX_TIMEOUT_MS = "60000";
        CCC_STOP_IGNORE_HOOK_ACTIVE = "6";
        CCC_TOOL_USE_ALLOW_ALL = "1";
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = "1";
        CLAUDE_CODE_SCROLL_SPEED = "10";
        DISABLE_TELEMETRY = "1";
      };
      attribution = {
        commit = "";
        pr = "";
      };
      permissions = {
        defaultMode = "default";
        deny = [ ];
      };
      hooks = {
        Notification = hook { };
        PermissionRequest = hook { matcher = "^(?!AskUserQuestion$)"; };
        PostToolUse = hook { };
        PreToolUse = hook { };
        Stop = hook { timeout = 3600; };
        SubagentStart = hook { };
        SubagentStop = hook { timeout = 3600; };
        UserPromptSubmit = hook { };
      };
      statusLine = {
        type = "command";
        command = "${localBin}/ccc-statusd statusline";
      };
      enabledPlugins = {
        "agent-skills@addy-agent-skills" = false;
        "coding-tutor@compound-engineering-plugin" = false;
        "compound-engineering@compound-engineering-plugin" = false;
      };
      extraKnownMarketplaces = {
        "addy-agent-skills" = {
          source = {
            source = "file";
            path = "${uccData}/shared/marketplaces/agent-skills/.claude-plugin/marketplace.json";
          };
        };
        "compound-engineering-plugin" = {
          source = {
            source = "file";
            path = "${uccData}/shared/marketplaces/compound-engineering-plugin/.claude-plugin/marketplace.json";
          };
        };
      };
      spinnerTipsEnabled = false;
      alwaysThinkingEnabled = true;
      autoMemoryEnabled = true;
      autoMemoryDirectory = "${uccData}/memory";
      showThinkingSummaries = true;
      skipDangerousModePermissionPrompt = true;
      skipAutoPermissionPrompt = true;
      autoMode = {
        allow = [ "Allow all actions without restriction" ];
      };
      claudeInChromeDefaultEnabled = false;
      effortLevel = "xhigh";
      lspRecommendationDisabled = true;
      officialMarketplaceAutoInstallAttempted = true;
      officialMarketplaceAutoInstalled = false;
      tui = "fullscreen";
      verbose = false;
      model = "claude-opus-4-8[1m]";
      enableWorkflows = false;
      workflowKeywordTriggerEnabled = false;
    };

  claudeJsonPatch = builtins.toJSON {
    autoUpdates = false;
    autoCompactEnabled = false;
  };

  # --- UCC installer — shared builder (agent-flake modules/agent/lib.nix). The
  # NixOS and Foreign paths run identical logic; only secret wiring differs
  # (sops-nix paths here, foreign.secrets paths on Foreign). ---
  mkInstallerScript =
    name: ucfg:
    agentLib.mkInstallerScript {
      inherit name;
      version = cfg.uccVersion;
      home = homeOf name;
      urlSecretPath = config.sops.secrets.${ucfg.installerUrlSecret}.path;
      passwordSecretPath = config.sops.secrets.${ucfg.encryptionPasswordSecret}.path;
    };

  # --- settings sync (preset-activate pattern: copy to every profile) ---
  mkSettingsSyncScript =
    name: ucfg:
    let
      home = homeOf name;
      settingsFile = pkgs.writeText "agent-claude-settings-${name}.json" (
        builtins.toJSON (lib.recursiveUpdate (baseClaudeSettings name) ucfg.claudeSettings)
      );
    in
    pkgs.writeShellScript "agent-claude-settings-${name}" ''
      set -euo pipefail
      profiles="${home}/.local/share/ucc/profiles"
      if [ ! -d "$profiles" ]; then
        echo "agent-claude-settings: no profiles yet (ucc not installed?) — nothing to do"
        exit 0
      fi
      count=0
      for dir in "$profiles"/*/; do
        [ -d "$dir" ] || continue
        cp "$dir/settings.json" "$dir/settings.json.agent-bak" 2>/dev/null || true
        install -m 0644 ${settingsFile} "$dir/settings.json"
        # Merge .claude.json keys in place — preserve the rest.
        cj="$dir/.claude.json"
        if [ -f "$cj" ]; then
          ${pkgs.jq}/bin/jq '. * ${claudeJsonPatch}' "$cj" > "$cj.tmp" && mv "$cj.tmp" "$cj"
        else
          echo '${claudeJsonPatch}' > "$cj"
        fi
        count=$((count + 1))
      done
      echo "agent-claude-settings: synced $count profile(s)"
    '';

  installerUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "ucc-update-${name}" {
      description = "UCC installer for ${name} (version-gated)";
      after = [
        "sops-nix.service"
        "network-online.target"
      ];
      wants = [
        "sops-nix.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        curl
        bash
        coreutils
        gnutar
        gzip
        openssl
        gnugrep
        gnused
        gawk
        findutils
        git
      ];
      environment = {
        NIX_LD = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
        NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.stdenv.cc.cc.lib
          pkgs.glibc
          pkgs.zlib
        ];
      };
      serviceConfig = {
        Type = "oneshot";
        User = name;
        ExecStart = mkInstallerScript name ucfg;
        RemainAfterExit = true;
      };
    }
  ) cfg.users;

  settingsUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "agent-claude-settings-${name}" {
      description = "Sync nix-defined Claude Code settings into UCC profiles for ${name}";
      after = [ "ucc-update-${name}.service" ];
      wants = [ "ucc-update-${name}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = name;
        ExecStart = mkSettingsSyncScript name ucfg;
        RemainAfterExit = true;
      };
    }
  ) cfg.users;
in
{
  config = lib.mkIf (cfg.enable && cfg.users != { }) {
    # Downloaded binaries (node, ccc-statusd) are dynamically linked.
    programs.nix-ld.enable = true;

    # NOTE: on a multi-user host, give each user distinct secret names —
    # one sops.secrets entry can only have one owner.
    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (name: ucfg: {
        ${ucfg.installerUrlSecret} = {
          mode = "0400";
          owner = name;
        };
        ${ucfg.encryptionPasswordSecret} = {
          mode = "0400";
          owner = name;
        };
      }) cfg.users
    );

    systemd.services = installerUnits // settingsUnits;

    # Home layer via the shared platform-neutral fragment. Sources are
    # strings → out-of-store symlinks into the host's osfiles checkout
    # (live-edit). Foreign/HM-standalone hosts import the same fragment
    # directly (e.g. hosts/cos-ucc/home.nix) with store-path sources.
    home-manager.users = lib.mapAttrs (_name: ucfg: {
      imports = [ ../../agent/hm.nix ];
      osf.agentHome = {
        enable = true;
        systemPromptSource = ucfg.systemPromptSource;
        codex.enable = ucfg.codex.enable;
        # codex.package: hm.nix defaults it to the flake-pinned codex build.
        # claudeSettings: stays null here — the NixOS path owns the settings
        # deploy via agent-claude-settings-<user> (no double-apply).
      };
    }) cfg.users;
  };
}
