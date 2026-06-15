# agent-flake

Standalone NixOS module for the **agent profile** — UCC (ccc-statusd + Claude Code), the `claude → ucc-auto` link, nix-defined Claude Code settings, the system prompt, the **paseo** daemon, and the OpenAI codex CLI — extracted from osfiles so osfiles and the semi-managed member fleet import one source of truth.

> Status: FIRST DIFF (build-verify). Destined for the 0xdao forge as `.repos/agent-flake`; not yet pushed.

## Use

```nix
# consumer flake.nix
inputs.agent = {
  url = "github:…/agent-flake";          # or path: for local dev
  inputs.nixpkgs.follows = "nixpkgs";    # REQUIRED — avoids a duplicate nixpkgs/paseo closure
};

# consumer module list (needs sops-nix + home-manager already imported)
imports = [ inputs.agent.nixosModules.agent ];

# per host
osf.agent = {
  enable = true;
  repoRoot = "/home/<user>/<checkout>";           # system-prompt symlink resolves under this
  # uccVersion = "1.11.14";                        # omit → inherit the flake's central default
  # paseoPackage = pkgs.paseo.overrideAttrs (…);   # optional per-host override (R2)
  users.<user> = {
    paseoConfigFile = ../../config/agent/paseo/<user>.json;  # REQUIRED (R3) — consumer-owned JSON
    # systemPromptFile, installerUrlSecret, encryptionPasswordSecret, claudeSettings,
    # codex.enable, paseo.enable, paseo.environment … (see modules/nixos/agent/default.nix)
  };
};
```

## What this flake owns vs. what the consumer owns

| Owned by the flake | Owned by the consumer |
|---|---|
| The module (`default.nix`, `ucc.nix`, `paseo.nix`, `agent/hm.nix`) | Host `osf.agent = {…}` declarations |
| The `@UCC_BIN@` render mechanism | The paseo config JSON content (`paseoConfigFile`) |
| The central **paseo** pin (`flake.nix` input) | `SYSTEM_PROMPT.md` content (live-edit, under `repoRoot`) |
| The fleet-default `uccVersion` | sops secret material (only the secret *names* are a contract) |

## Central version pin

`paseo` is pinned once in `flake.nix` (one bump reaches every consumer). `uccVersion` default lives in `default.nix`. A consumer overrides either per host via the options above.
