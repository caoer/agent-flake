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
#                              → out-of-store symlink (live-edit; consumed by
#                              ucc-auto via --system-prompt-file)
#   codex CLI (nixpkgs)        when codex.enable (paseo's native provider)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agent;
  homeOf = name: config.users.users.${name}.home;

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
      model = "claude-fable-5[1m]";
      enableWorkflows = false;
      workflowKeywordTriggerEnabled = false;
    };

  claudeJsonPatch = builtins.toJSON {
    autoUpdates = false;
    autoCompactEnabled = false;
  };

  # --- UCC installer (verbatim zt-agent-v2 logic, parameterized) ---
  mkInstallerScript =
    name: ucfg:
    let
      home = homeOf name;
      localBin = "${home}/.local/bin";
      uccShare = "${home}/.local/share/ucc/shared";
    in
    pkgs.writeShellScript "ucc-update-${name}" ''
      set -euo pipefail
      DESIRED="${cfg.uccVersion}"

      UCC_INSTALLER_URL=$(cat ${config.sops.secrets.${ucfg.installerUrlSecret}.path})
      ENCRYPTION_PASSWORD=$(cat ${config.sops.secrets.${ucfg.encryptionPasswordSecret}.path})

      CURRENT=""
      if [ -x "${localBin}/ccc-statusd" ]; then
        CURRENT=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
      fi

      # Full-stack check: ccc-statusd version match AND node binary works.
      if [ "$CURRENT" = "$DESIRED" ] && [ -x "${uccShare}/node/bin/node" ] \
         && "${uccShare}/node/bin/node" --version >/dev/null 2>&1; then
        echo "ucc: v$DESIRED already installed, skipping"
        exit 0
      fi

      echo "ucc: updating $CURRENT → $DESIRED"
      export ENCRYPTION_PASSWORD

      # .zshrc is a read-only HM symlink on NixOS; the installer appends
      # PATH/source lines to it. Replace with a writable copy so the
      # installer doesn't fail at the shell RC step.
      if [ -L "${home}/.zshrc" ]; then
        cp -L "${home}/.zshrc" "${home}/.zshrc.tmp"
        mv "${home}/.zshrc.tmp" "${home}/.zshrc"
      fi
      # cp -L preserves the store file's 444 mode — the copy is read-only
      # even for its owner and the installer's RC append fails. Make writable.
      if [ -f "${home}/.zshrc" ]; then
        chmod u+w "${home}/.zshrc"
      fi

      # Download then execute — avoids curl|bash where pipe exit codes get lost.
      TMPSCRIPT=$(mktemp /tmp/ucc-install.XXXXXX)
      trap 'rm -f "$TMPSCRIPT"' EXIT
      ${pkgs.curl}/bin/curl -fsSL "$UCC_INSTALLER_URL" -o "$TMPSCRIPT"
      ${pkgs.bash}/bin/bash "$TMPSCRIPT"

      # Verify ccc-statusd.
      if [ ! -x "${localBin}/ccc-statusd" ]; then
        echo "ucc: FATAL: ccc-statusd not found after install" >&2
        exit 1
      fi
      INSTALLED=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
      if [ "$INSTALLED" != "$DESIRED" ]; then
        echo "ucc: FATAL: expected v$DESIRED but got v$INSTALLED" >&2
        exit 1
      fi

      # Verify node runs (catches nix-ld / dynamic linking failures).
      if ! "${uccShare}/node/bin/node" --version >/dev/null 2>&1; then
        echo "ucc: FATAL: node binary at ${uccShare}/node/bin/node cannot execute (dynamic linking?)" >&2
        exit 1
      fi

      echo "ucc: v$DESIRED installed successfully"
    '';

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
        systemPromptSource = ucfg.systemPromptFile;
        codex.enable = ucfg.codex.enable;
      };
    }) cfg.users;
  };
}
