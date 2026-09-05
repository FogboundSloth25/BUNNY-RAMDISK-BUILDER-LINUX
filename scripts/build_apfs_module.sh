#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?source directory}"
OUT="${2:?output module path}"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"

[[ -d "$SRC" ]] || { echo "APFS source not found: $SRC" >&2; exit 1; }
[[ -d "$KDIR" ]] || { echo "Kernel build directory not found: $KDIR" >&2; exit 1; }

# Kbuild rejects whitespace in KBUILD_EXTMOD. The source checkout may live in
# a directory such as "~/iPhone XS/...", so stage the module in /tmp instead.
STAGE="$(mktemp -d /tmp/bunny-apfs-rw-build.XXXXXX)"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

command -v rsync >/dev/null 2>&1 || {
  echo "rsync is required to build linux-apfs-rw" >&2
  exit 1
}

rsync -a --exclude='.git' "$SRC/" "$STAGE/"
printf '#define GIT_COMMIT\t"bunny-linux"\n' > "$STAGE/version.h"

echo "==> KDIR=$KDIR"
echo "==> STAGE=$STAGE"

make -C "$KDIR" M="$STAGE" modules

[[ -s "$STAGE/apfs.ko" ]] || {
  echo "APFS build completed without $STAGE/apfs.ko" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
cp -f "$STAGE/apfs.ko" "$OUT"

if command -v modinfo >/dev/null 2>&1; then
  modinfo "$OUT" >/dev/null
fi

echo "APFS module built successfully: $OUT"
file "$OUT" 2>/dev/null || true
sha256sum "$OUT"
