#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BUNNY_ROOT="$ROOT"
export BUNNY_VERSION="1.1-linux"
export BUNNY_TOOLS="$ROOT/.local/bin"
export BUNNY_PATCH="$ROOT/.local/patch"
export BUNNY_CACHE="$ROOT/cache"
export BUNNY_WORK="$ROOT/work"
export BUNNY_BOOTCHAIN="$ROOT/bootchain"
export BUNNY_RESOURCES="$ROOT/resources"
export BUNNY_THIRD_PARTY="$ROOT/third_party"
export BUNNY_LAST="$ROOT/.last_bootchain"
export PATH="$BUNNY_TOOLS:$BUNNY_PATCH:$HOME/.local/bin:$HOME/go/bin:$PATH"

mkdir -p "$BUNNY_TOOLS" "$BUNNY_PATCH" "$BUNNY_CACHE" "$BUNNY_WORK" "$BUNNY_BOOTCHAIN"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command '$1'; run ./setup_dependencies.sh"
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

python_bin() {
  if [[ -x "$ROOT/.venv/bin/python" ]]; then
    printf '%s\n' "$ROOT/.venv/bin/python"
  else
    printf '%s\n' "$(command -v python3 || command -v python)"
  fi
}

LAST_BOOTCHAIN=""
if [[ -s "$BUNNY_LAST" ]]; then
  LAST_BOOTCHAIN="$(<"$BUNNY_LAST")"
fi
