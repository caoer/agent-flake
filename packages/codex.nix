# Codex — OpenAI Codex CLI. Prebuilt static musl binaries from GitHub releases.
# Pinned ahead of nixpkgs (which lags upstream). Bump: update version + sha256
# (nix-prefetch-url the new tarball URL).
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.139.0";

  assets = {
    "x86_64-linux" = {
      target = "x86_64-unknown-linux-musl";
      sha256 = "10803293vjwq42dwxs0ppc9d3kgawysjm4b230333j0xyh6zgsqj";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "codex: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${asset.target}.tar.gz";
    inherit (asset) sha256;
  };

  sourceRoot = ".";

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 codex-${asset.target} $out/bin/codex
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenAI Codex CLI — coding agent";
    homepage = "https://github.com/openai/codex";
    changelog = "https://github.com/openai/codex/releases/tag/rust-v${version}";
    license = licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames assets;
  };
}
