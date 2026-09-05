#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?source directory}"
OUT="${2:?output module path}"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
ROOT="${BUNNY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STAGE="${BUNNY_APFS_STAGE:-$ROOT/work/linux-apfs-rw-build}"

[[ -d "$SRC" ]] || { echo "APFS source not found: $SRC" >&2; exit 1; }
[[ -d "$KDIR" ]] || { echo "Kernel build directory not found: $KDIR" >&2; exit 1; }

case "$STAGE" in
  *\ *|$'\t'*) echo "APFS staging path contains whitespace: $STAGE" >&2; exit 1 ;;
esac

rm -rf "$STAGE"
mkdir -p "$STAGE"
rsync -a --exclude='.git' "$SRC/" "$STAGE/"

# linux-apfs-rw/genver.sh expects git metadata. A shallow copy intentionally
# has none, so provide a deterministic build identifier.
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
