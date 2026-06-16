# modules/system-manager/agent/ucc.nix — Foreign ucc installer (system-manager).
#
# Version-gated ucc installer as a oneshot system-manager unit. The installer
# SCRIPT is the shared agentLib.mkInstallerScript (identical to the NixOS path);
# Foreign-specific wiring only: Debian-native deps on PATH (no nix-ld — Debian
# is a normal glibc distro, the downloaded node/ccc-statusd run natively),
# secrets read from the consumer-wired on-host paths, and a ConditionPathExists
# guard that keeps the unit green until the operator's post-activation secret
# push lands.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.agentForeign;
  agentLib = import ../../agent/lib.nix { inherit pkgs; };

  installerDeps = lib.makeBinPath (
    with pkgs;
    [
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
    ]
  );
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.ucc-update = {
      description = "UCC installer (version-gated)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Stay green until the operator pushes the secrets post-activation; the
      # consumer's push-secrets path restarts this unit once they land.
      unitConfig.ConditionPathExists = [
        cfg.installerUrlPath
        cfg.encryptionPasswordPath
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.username;
        Environment = [ "PATH=${installerDeps}:/usr/local/bin:/usr/bin:/bin" ];
        ExecStart = agentLib.mkInstallerScript {
          name = cfg.username;
          version = cfg.uccVersion;
          home = cfg.homeDirectory;
          urlSecretPath = cfg.installerUrlPath;
          passwordSecretPath = cfg.encryptionPasswordPath;
        };
        RemainAfterExit = true;
      };
    };
  };
}
