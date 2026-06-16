# modules/nixos/agent/paseo.nix — per-user paseo daemon.
#
# Hand-rolled per-user units (paseo-<user>.service) instead of the upstream
# single-instance NixOS module — uniform across the fleet and multi-user
# capable. The paseo PACKAGE comes from `osf.agent.paseoPackage` (the flake's
# central pin by default; per-host overridable, R2).
#
# config.json is rendered into the store from the CONSUMER-SUPPLIED JSON
# (`osf.agent.users.<name>.paseoConfigFile`, REQUIRED — R3) with the @UCC_BIN@
# placeholder replaced by the user's ucc bin dir, then materialized as a
# WRITABLE copy at ~/.paseo/config.json by a systemd ExecStartPre `install` —
# re-laid on every daemon start, so declarative content still wins. It is NOT a
# store symlink: paseo's onboard / config-save does an unconditional
# writeFileSync to that path, which EROFS-crashes against a read-only nix-store
# symlink — the writable copy fixes that while staying declarative. The file
# carries daemon.listen; multi-user hosts need a distinct port per user.
# ExecStartPre first rm -f's any stale read-only HM symlink (so `install` can't
# write THROUGH it back into the store), then installs the copy — silent
# mechanics, loud failure.
#
# Daemon identity (~/.paseo/server-id, daemon-keypair.json) is generated on
# first start and left alone — identity = host, back it up across reinstalls.
#
# Agent providers authenticate as the user — log in once interactively
# before relying on the daemon (BYOK).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agent;
  paseoUsers = lib.filterAttrs (_: ucfg: ucfg.paseo.enable) cfg.users;
  paseoPkg = cfg.paseoPackage;

  # Shared render — same builder the Foreign system-manager module uses.
  agentLib = import ../../agent/lib.nix { inherit pkgs; };

  # Agents spawned by the daemon need the user's tools: ucc-installed
  # claude/ccc-statusd (~/.local/bin, ucc bin), then HM/system profiles.
  #
  # /run/wrappers/bin MUST precede /run/current-system/sw/bin: the setuid
  # wrappers (sudo, mount, ping…) live there, while sw/bin holds the plain
  # non-setuid store binaries. With sw/bin first, `sudo` from an agent shell
  # resolves to the store copy and dies with "must be owned by uid 0 and have
  # the setuid bit set". Wrappers first = sudo works from agent shells
  # (xu-lax hard-won finding, preserved on extraction).
  agentPath =
    name: home:
    builtins.concatStringsSep ":" [
      "${home}/.local/bin"
      "${home}/.local/share/ucc/bin"
      "/etc/profiles/per-user/${name}/bin"
      "/run/wrappers/bin"
      "/run/current-system/sw/bin"
      "/nix/var/nix/profiles/default/bin"
    ];

  # config.json rendered into the store with the per-user ucc bin dir injected
  # in place of the consumer JSON's @UCC_BIN@ placeholder. The JSON source is
  # the consumer-supplied paseoConfigFile (REQUIRED), so the flake owns the
  # render mechanism while each repo owns its own config content.
  renderPaseoConfig =
    name: home: configFile:
    agentLib.renderPaseoConfig {
      inherit name configFile;
      uccBinDir = "${home}/.local/share/ucc/bin";
    };
in
{
  config = lib.mkIf (cfg.enable && paseoUsers != { }) {
    systemd.services = lib.mapAttrs' (
      name: ucfg:
      let
        inherit (config.users.users.${name}) home;
        paseoHome = "${home}/.paseo";
        configJson = renderPaseoConfig name home ucfg.paseoConfigFile;
      in
      lib.nameValuePair "paseo-${name}" {
        description = "Paseo daemon for ${name} - self-hosted daemon for AI coding agents";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        # Clean restart (fleet stability). paseo runs its agents as DIRECT
        # CHILD PROCESSES in this unit's cgroup — there is no session reattach
        # (upstream 0.1.96). So an agent that runs `nixos-rebuild switch` from
        # inside paseo would, by systemd default (restartIfChanged=true,
        # KillMode=control-group), watch the switch SIGTERM the whole cgroup and
        # kill itself + its in-flight rebuild. Decouple the daemon restart from
        # the switch: a switch activates the new generation but leaves the
        # RUNNING daemon (and its agents) untouched. The new paseo version /
        # config.json applies on the next DELIBERATE restart (when no session is
        # mid-flight: `systemctl restart paseo-${name}`) or on reboot.
        # Crash-recovery is unaffected — `Restart = on-failure` still applies.
        restartIfChanged = false;
        stopIfChanged = false;

        environment = {
          NODE_ENV = "production";
          PASEO_HOME = paseoHome;
          # mkForce overrides the default PATH from NixOS's systemd module.
          PATH = lib.mkForce (agentPath name home);
        }
        // ucfg.paseo.environment;

        serviceConfig = {
          Type = "simple";
          User = name;

          # Writable config.json. paseo's onboard / config-save writeFileSync's
          # to this path; a read-only store symlink would EROFS-crash it.
          ExecStartPre = [
            # migration + idempotence: drop any stale read-only HM symlink so
            # `install` cannot write THROUGH it into the read-only store (that
            # re-creates the EROFS).
            "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
            # writable copy from the store — re-laid on every start, declarative wins.
            "${pkgs.coreutils}/bin/install -D -m 0600 ${configJson} ${paseoHome}/config.json"
          ];
          ExecStart = "${paseoPkg}/bin/paseo-server";

          Restart = "on-failure";
          RestartSec = 5;

          # Graceful shutdown (server handles SIGTERM with a 10s timeout)
          KillSignal = "SIGTERM";
          TimeoutStopSec = 15;
        };
      }
    ) paseoUsers;

    home-manager.users = lib.mapAttrs (_name: _ucfg: {
      # paseo CLI on the user's PATH (talks to the daemon).
      # config.json is no longer HM-managed — the systemd ExecStartPre install
      # (above) lays a writable copy, so HM drops its old read-only symlink.
      home.packages = [ paseoPkg ];
    }) paseoUsers;
  };
}
