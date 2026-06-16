# modules/agent/lib.nix — shared builders for the agent profile, used by BOTH
# the NixOS module (modules/nixos/agent) and the Foreign system-manager module
# (modules/system-manager/agent). ONE source of truth for the version-gated ucc
# installer and the paseo config render; the platform modules differ only in how
# they wire secrets, PATH, systemd options, and the per-platform agentPath tail
# around these.
{ pkgs }:
{
  # Fleet-wide central default ccc-statusd version. Both module paths (NixOS +
  # Foreign) default osf.agent{,Foreign}.uccVersion to this — ONE bump moves the
  # whole fleet. Override per-host via the option.
  defaultUccVersion = "1.11.14";

  # Version-gated UCC installer (nix as updater): compares the installed
  # ccc-statusd version against `version`, runs the Cloudflare installer when it
  # differs (or node is broken), verifies, and is a <1s no-op when already
  # current. CLI tools (curl, bash, coreutils, gnugrep, …) come from the
  # caller's systemd unit PATH — NixOS via `path`, Foreign via Environment PATH.
  # Secrets are read from on-host paths the caller wires (sops-nix on NixOS,
  # foreign.secrets on Foreign), so this builder is platform-neutral.
  mkInstallerScript =
    {
      name,
      version,
      home,
      urlSecretPath,
      passwordSecretPath,
    }:
    let
      localBin = "${home}/.local/bin";
      uccShare = "${home}/.local/share/ucc/shared";
    in
    pkgs.writeShellScript "ucc-update-${name}" ''
      set -euo pipefail
      DESIRED="${version}"

      UCC_INSTALLER_URL=$(cat ${urlSecretPath})
      ENCRYPTION_PASSWORD=$(cat ${passwordSecretPath})

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
      # PATH/source lines to it. Replace with a writable copy so the installer
      # doesn't fail at the shell RC step.
      if [ -L "${home}/.zshrc" ]; then
        cp -L "${home}/.zshrc" "${home}/.zshrc.tmp"
        mv "${home}/.zshrc.tmp" "${home}/.zshrc"
      fi
      # cp -L preserves the store file's 444 mode — the copy is read-only even
      # for its owner and the installer's RC append fails. Make writable.
      if [ -f "${home}/.zshrc" ]; then
        chmod u+w "${home}/.zshrc"
      fi

      # Download then execute — avoids curl|bash where pipe exit codes get lost.
      TMPSCRIPT=$(mktemp /tmp/ucc-install.XXXXXX)
      trap 'rm -f "$TMPSCRIPT"' EXIT
      curl -fsSL "$UCC_INSTALLER_URL" -o "$TMPSCRIPT"
      bash "$TMPSCRIPT"

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

  # paseo config.json rendered into the store from a consumer-supplied JSON with
  # the @UCC_BIN@ placeholder replaced by the user's ucc bin dir. Both platforms
  # then materialize a WRITABLE copy at ~/.paseo/config.json via a systemd
  # ExecStartPre install (paseo's onboard / config-save writeFileSync's that
  # path; a read-only store symlink would EROFS-crash it).
  renderPaseoConfig =
    {
      name,
      uccBinDir,
      configFile,
    }:
    pkgs.writeText "paseo-config-${name}.json" (
      builtins.replaceStrings [ "@UCC_BIN@" ] [ uccBinDir ] (builtins.readFile configFile)
    );
}
