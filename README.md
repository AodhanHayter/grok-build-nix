# grok-build-nix

Nix flake for [Grok Build](https://github.com/xai-org/grok-build) (`grok`) — xAI's
terminal-based AI coding agent. Tracks the upstream **stable** channel hourly and
lands each release only after it builds and runs on Linux and macOS.

Packages the signed binary xAI publishes for each release, not a from-source
rebuild, so `grok --version` here is byte-identical to `curl https://x.ai/cli/install.sh | bash`.

## Use it

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    grok-build-nix = {
      url = "github:AodhanHayter/grok-build-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Then either take the package directly:

```nix
environment.systemPackages = [
  inputs.grok-build-nix.packages.${pkgs.stdenv.hostPlatform.system}.grok
];
```

or apply the overlay and use `pkgs.grok` anywhere:

```nix
nixpkgs.overlays = [ inputs.grok-build-nix.overlays.default ];
```

Pin to a release instead of tracking `main` with `?ref=v0.2.118`, or to the
newest verified build with `?ref=latest`.

### Try it without installing

```sh
nix run github:AodhanHayter/grok-build-nix
```

## What the package does

| | |
|---|---|
| Binary | `grok`, plus `.grok-unwrapped` (the raw upstream binary) |
| Completions | bash, zsh and fish, generated from the binary at build time |
| Auto-updater | disabled via `GROK_DISABLE_AUTOUPDATER=1` — the store is read-only, so updates come from bumping this flake |
| `PATH` | suffixed with `git`, `ripgrep`, `procps`, and `bubblewrap` on Linux (grok's sandbox re-execs under `bwrap`) — suffixed, not prefixed, so your own tools still win |
| Platforms | `aarch64-darwin`, `x86_64-darwin`, `x86_64-linux`, `aarch64-linux` |

The macOS builds carry xAI's code signature, so the derivation never strips them.
The Linux builds are statically linked and need no patching.

`binName` is overridable if you want the binary under a different name:

```nix
pkgs.callPackage "${inputs.grok-build-nix}/package.nix" { binName = "grok-build"; }
```

## Automation

| Workflow | Trigger | What it does |
|---|---|---|
| `update.yml` | hourly | Reads `https://x.ai/cli/stable`. On a new version: pins all four platform hashes, **builds and smoke-tests on ubuntu-latest, ubuntu-24.04-arm and macos-latest**, and only then commits to `main` and tags `v<version>` + moves `latest` |
| `ci.yml` | push / PR | Same build matrix plus `nix flake check` |
| `update-flake-lock.yml` | weekly | Opens a PR bumping `nixpkgs` |
| `dependabot.yml` | weekly | Pins for GitHub Actions |

Nothing is committed before it is known to build, so `main` is always a working
flake — that is why there is no PR-and-auto-merge dance.

`update-flake-lock` PRs are opened with `GITHUB_TOKEN`, which by GitHub's design
does not trigger CI. Add a PAT with `repo` scope as the `FLAKE_LOCK_PAT` secret
if you want CI to run on them.

### Updating by hand

```sh
./scripts/update-version.sh                 # sync to the channel pointer, then verify the build
./scripts/update-version.sh --check         # report only, changes nothing
./scripts/update-version.sh --version 0.2.118  # pin a specific version
```

`sources.json` is the only file a version bump touches: the tracked channel, the
version, and one SRI hash per platform.

## Licensing

The `grok` source is Apache-2.0 (see [xai-org/grok-build](https://github.com/xai-org/grok-build));
this package installs the binary xAI builds from it and marks it
`sourceProvenance = binaryNativeCode`. The Nix expressions in this repo are MIT.
