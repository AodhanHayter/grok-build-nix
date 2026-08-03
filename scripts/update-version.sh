#!/usr/bin/env bash
#
# Sync sources.json to the newest grok release on the tracked channel.
#
#   update-version.sh                 # update to latest, then verify the build
#   update-version.sh --check         # print current/latest/update as key=value, change nothing
#   update-version.sh --version X.Y.Z # pin a specific version
#   update-version.sh --no-verify     # skip the `nix build` check
#
# --check writes GITHUB_OUTPUT-shaped lines and always exits 0, so CI can do:
#   ./scripts/update-version.sh --check >> "$GITHUB_OUTPUT"

set -euo pipefail

readonly PRIMARY_BASE="https://x.ai/cli"
readonly FALLBACK_BASE="https://storage.googleapis.com/grok-build-public-artifacts/cli"
readonly SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$'
readonly MAX_ATTEMPTS=3

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SOURCES="$repo_root/sources.json"

log() { printf '\033[0;32m[update]\033[0m %s\n' "$1" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1" >&2; }
die() {
  printf '\033[0;31m[error]\033[0m %s\n' "$1" >&2
  exit 1
}

require_tools() {
  local missing=""
  for tool in curl jq nix; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] || die "missing required tools:$missing"
  [ -f "$SOURCES" ] || die "sources.json not found at $SOURCES"
}

# Run "$@" up to MAX_ATTEMPTS times, treating empty stdout as failure.
retry() {
  local attempt result
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if result=$("$@") && [ -n "$result" ]; then
      printf '%s' "$result"
      return 0
    fi
    if ((attempt < MAX_ATTEMPTS)); then
      warn "attempt $attempt/$MAX_ATTEMPTS failed, retrying in $((attempt * 2))s..."
      sleep $((attempt * 2))
    fi
  done
  return 1
}

channel() { jq -r '.channel' "$SOURCES"; }
current_version() { jq -r '.version' "$SOURCES"; }
platforms() { jq -r '.platforms | keys[]' "$SOURCES"; }

fetch_pointer() {
  local ch="$1" base
  for base in "$PRIMARY_BASE" "$FALLBACK_BASE"; do
    local value
    value=$(curl -fsSL --max-time 20 "$base/$ch" 2>/dev/null | tr -d '[:space:]') || continue
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

latest_version() {
  local ch="$1" value
  value=$(retry fetch_pointer "$ch") ||
    die "could not read the $ch channel pointer from $PRIMARY_BASE or $FALLBACK_BASE"
  [[ "$value" =~ $SEMVER_RE ]] ||
    die "channel pointer returned '$value', which is not a version"
  printf '%s' "$value"
}

# Echo the SRI hash of one platform artifact, trying both hosts.
prefetch_hash() {
  local version="$1" platform="$2" base hash
  for base in "$PRIMARY_BASE" "$FALLBACK_BASE"; do
    hash=$(nix store prefetch-file --json "$base/grok-$version-$platform" 2>/dev/null |
      jq -r '.hash') || continue
    if [[ "$hash" == sha256-* ]]; then
      printf '%s' "$hash"
      return 0
    fi
  done
  return 1
}

write_sources() {
  local version="$1" platforms_json="$2" tmp
  tmp="$(mktemp)"
  jq --arg v "$version" --argjson p "$platforms_json" \
    '.version = $v | .platforms = $p' "$SOURCES" >"$tmp"
  mv "$tmp" "$SOURCES"
}

update_to() {
  local version="$1" platform hash platform_list
  local platforms_json='{}'

  # Read the list up front rather than piping into the loop: a failing jq behind
  # a process substitution would run the loop zero times and silently write back
  # an empty platform map.
  platform_list=$(platforms) || die "could not read .platforms from $SOURCES"
  [ -n "$platform_list" ] || die ".platforms in $SOURCES is empty"

  log "fetching artifact hashes for $version..."
  while read -r platform; do
    hash=$(retry prefetch_hash "$version" "$platform") ||
      die "no artifact for $platform at version $version (upstream may not have published it yet)"
    log "  $platform  $hash"
    platforms_json=$(jq -c --arg k "$platform" --arg v "$hash" '.[$k] = $v' <<<"$platforms_json")
  done <<<"$platform_list"

  write_sources "$version" "$platforms_json"
  log "sources.json updated to $version"
}

verify_build() {
  log "verifying: nix build .#grok"
  (cd "$repo_root" && nix build .#grok --no-link --print-build-logs) ||
    die "build verification failed"
  log "build ok"
}

main() {
  local target="" check_only=false verify=true

  while (($# > 0)); do
    case "$1" in
      --check)
        check_only=true
        shift
        ;;
      --version)
        [ $# -ge 2 ] || die "--version needs an argument"
        target="$2"
        shift 2
        ;;
      --no-verify)
        verify=false
        shift
        ;;
      -h | --help)
        sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
  done

  require_tools

  local ch current latest
  ch="$(channel)"
  current="$(current_version)"

  if [ -n "$target" ]; then
    [[ "$target" =~ $SEMVER_RE ]] || die "invalid version: $target"
    latest="$target"
  else
    latest="$(latest_version "$ch")"
  fi

  if [ "$check_only" = true ]; then
    local update=false
    if [ "$current" != "$latest" ]; then
      update=true
    fi
    printf 'channel=%s\ncurrent=%s\nlatest=%s\nupdate=%s\n' "$ch" "$current" "$latest" "$update"
    exit 0
  fi

  log "channel=$ch current=$current latest=$latest"
  if [ "$current" = "$latest" ]; then
    log "already up to date"
    exit 0
  fi

  update_to "$latest"
  if [ "$verify" = true ]; then
    verify_build
  fi
  log "grok $current -> $latest"
}

main "$@"
