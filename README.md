# agent-flake

Standalone flake for the **agent profile** — UCC (ccc-statusd + Claude Code), the `claude → ucc-auto` link, nix-defined Claude Code settings, the system prompt, the **paseo** daemon, and the OpenAI **codex** CLI. One source of truth for osfiles and the semi-managed member fleet (yangming, xu-lax, cos-ucc).

## Outputs

| Output | For |
|---|---|
| `nixosModules.agent` | Full NixOS hosts. Per-user ucc installer + claude settings sync + paseo daemon + codex. Configure via `osf.agent`. |
| `systemManagerModules.agent` | Foreign (non-NixOS, [system-manager](https://github.com/numtide/system-manager)) hosts. The SYSTEM layer only (paseo daemon + ucc installer). Configure via `osf.agentForeign`. |
| `homeModules.agentHome` | The platform-neutral home-manager fragment (`osf.agentHome`: ucc PATH, claude link, system prompt, paseo config, codex). Both platforms import it. |
| `packages.<sys>.paseo` | The central paseo pin, re-exported (Foreign/HM consumers get the same paseo with no own input). |
| `packages.<sys>.paseo-speech` | `paseo` + the local-speech-worker trace patch (dictation/voice). Set `paseoPackage = …paseo-speech` instead of carrying the patch. *(x86_64-linux only.)* |
| `packages.<sys>.codex` | OpenAI codex CLI pinned ahead of nixpkgs — the fleet's agent provider. *(x86_64-linux only.)* |

The NixOS and Foreign modules share their installer-script / paseo-config render / default uccVersion via `modules/agent/lib.nix` — ONE source across both platforms.

## Use — NixOS host

```nix
inputs.agent = {
  url = "github:caoer/agent-flake";       # public — any box fetches at build, no forge SSH
  inputs.nixpkgs.follows = "nixpkgs";      # REQUIRED — avoids a duplicate nixpkgs/paseo closure
};

imports = [ inputs.agent.nixosModules.agent ];  # needs sops-nix + home-manager already imported

osf.agent = {
  enable = true;
  repoRoot = "/home/<user>/<checkout>";
  # paseoPackage = inputs.agent.packages.${pkgs.stdenv.hostPlatform.system}.paseo-speech;  # opt into speech
  users.<user> = {
    paseoConfigFile = ../../config/agent/paseo/<user>.json;  # REQUIRED (R3) — consumer-owned providers
    # systemPromptSource defaults to the flake's canonical asset (immutable store
    # copy); set a STRING absolute path for a live-edit symlink (escape hatch).
    # codex.enable (default true → flake-pinned codex), paseo.environment, claudeSettings …
  };
};
```

## Use — Foreign (system-manager) host

```nix
inputs.agent.url = "github:caoer/agent-flake";  # + inputs.nixpkgs.follows = "nixpkgs";

# import systemManagerModules.agent at the flake level (where `inputs` is in scope —
# referencing it from a host's `imports` recurses through _module.args), e.g. in your
# makeSystemConfig modules list. HM layer: import homeModules.agentHome in home.nix.

osf.agentForeign = {
  enable = true;
  inherit username homeDirectory;
  paseoConfigFile = ../../config/agent/paseo/<user>.json;
  # extraEnvironment = [ "CLAUDE_CONFIG_DIR=${homeDirectory}/.local/share/ucc/shared" ];
  # installerUrlPath / encryptionPasswordPath default to /etc/secrets/ucc_* — the consumer
  # delivers the secrets there (its own mechanism; the module only reads the paths).
};
```

## What the flake owns vs. what the consumer owns

| Owned by the flake | Owned by the consumer |
|---|---|
| The modules + shared `agent/lib.nix` | Host `osf.agent` / `osf.agentForeign` declarations |
| `assets/SYSTEM_PROMPT.md` (canonical; per-host override via the option) | The paseo config JSON content (`paseoConfigFile` — providers) |
| `packages/codex.nix` (fleet codex version) + the speech patch | sops/secret material (only the secret *paths/names* are a contract) |
| The central **paseo** pin + the fleet-default `uccVersion` | — |

## Central pins

`paseo` is pinned once in `flake.nix`; `codex` in `packages/codex.nix`; `uccVersion` in `modules/agent/lib.nix`. One bump in each reaches every consumer. Override per host via the options.
