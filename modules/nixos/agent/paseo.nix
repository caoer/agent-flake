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

  # Agents spawned by the daemon need the user's tools: ucc-installed
  # claude/ccc-statusd (~/.local/bin, ucc bin), then HM/system profiles.
  agentPath =
    name: home:
    builtins.concatStringsSep ":" [
      "${home}/.local/bin"
      "${home}/.local/share/ucc/bin"
      "/etc/profiles/per-user/${name}/bin"
      "/run/current-system/sw/bin"
      "/run/wrappers/bin"
      "/nix/var/nix/profiles/default/bin"
    ];

  # config.json rendered into the store with the per-user ucc bin dir injected
  # in place of the consumer JSON's @UCC_BIN@ placeholder. The JSON source is
  # the consumer-supplied paseoConfigFile (REQUIRED), so the flake owns the
  # render mechanism while each repo owns its own config content.
  renderPaseoConfig =
    name: home: configFile:
    pkgs.writeText "paseo-config-${name}.json" (
      builtins.replaceStrings [ "@UCC_BIN@" ] [ "${home}/.local/share/ucc/bin" ] (
        builtins.readFile configFile
      )
    );
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
