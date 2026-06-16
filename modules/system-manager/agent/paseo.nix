# modules/system-manager/agent/paseo.nix — Foreign paseo daemon (system-manager).
#
# The hand-rolled equivalent of the NixOS paseo unit, using only serviceConfig
# directives (no NixOS systemd-module conveniences). The paseo PACKAGE comes
# from osf.agentForeign.paseoPackage (the flake pin by default); config.json is
# rendered via the shared agentLib.renderPaseoConfig and materialized as a
# WRITABLE copy by ExecStartPre — identical mechanics to the NixOS path: it is
# NOT a store symlink (paseo's onboard / config-save writeFileSync's the path,
# which EROFS-crashes a read-only store symlink). ExecStartPre first rm -f's any
# stale read-only HM symlink so `install` can't write THROUGH it back into the
# store, then installs the copy — silent mechanics, loud failure. Daemon identity
# (~/.paseo/server-id, daemon-keypair.json) is generated on first start and left
# alone — identity = host, back it up across reinstalls.
#
# Clean restart: system-manager honours serviceConfig."X-RestartIfChanged" in
# [Service] and SKIPS the unit restart on `system-manager switch`, so a switch
# triggered by an agent running INSIDE paseo doesn't kill the agent + its
# in-flight switch. New version/config applies on the next deliberate
# `systemctl restart paseo` or reboot. (The NixOS path uses restartIfChanged=false.)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agentForeign;
  agentLib = import ../../agent/lib.nix { inherit pkgs; };
  home = cfg.homeDirectory;
  paseoHome = "${home}/.paseo";

  configJson = agentLib.renderPaseoConfig {
    name = "foreign";
    uccBinDir = "${home}/.local/share/ucc/bin";
    configFile = cfg.paseoConfigFile;
  };

  # Foreign/Debian agent PATH: ucc-installed tools (~/.local/bin, ucc bin), the
  # HM toolchain (~/.nix-profile/bin: git, node, go…), nix default profile, then
  # Debian system paths. (The NixOS path uses /etc/profiles/per-user +
  # /run/wrappers + /run/current-system instead — those don't exist on Foreign.)
  agentPath = builtins.concatStringsSep ":" [
    "${home}/.local/bin"
    "${home}/.local/share/ucc/bin"
    "${home}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.paseo = {
      description = "Paseo - self-hosted daemon for AI coding agents";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.username;

        Environment = [
          "NODE_ENV=production"
          "PASEO_HOME=${paseoHome}"
          "PASEO_LISTEN=${cfg.paseoListen}"
          "PATH=${agentPath}"
        ]
        ++ cfg.extraEnvironment;

        # Writable config.json (see file doc-comment).
        ExecStartPre = [
          "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
          "${pkgs.coreutils}/bin/install -D -m 0600 ${configJson} ${paseoHome}/config.json"
        ];
        ExecStart = "${cfg.paseoPackage}/bin/paseo-server";

        # Clean restart — system-manager honours this raw [Service] directive.
        "X-RestartIfChanged" = "false";

        Restart = "on-failure";
        RestartSec = 5;
        KillSignal = "SIGTERM";
        TimeoutStopSec = 15;
      };
    };
  };
}
