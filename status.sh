#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"

echo "=== BUNNY RAMDISK BUILDER ==="
echo "version: $BUNNY_VERSION"
echo "root:    $BUNNY_ROOT"
echo "kernel:  $(uname -r)"
echo "arch:    $(uname -m)"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "OS:      ${PRETTY_NAME:-unknown}"
fi

echo
echo "=== tools ==="
for c in python3 ipsw irecovery iproxy trustcache mkapfs jq curl ssh; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '  %-12s OK\n' "$c"
  else
    printf '  %-12s MISS\n' "$c"
  fi
done

echo
echo "=== APFS backend ==="
[[ -f "$BUNNY_THIRD_PARTY/linux-apfs-rw/apfs.ko" ]] && echo "  apfs.ko: present" || echo "  apfs.ko: missing"
grep -qw '^apfs ' /proc/modules 2>/dev/null && echo "  module: loaded" || echo "  module: not loaded"

echo
echo "=== device ==="
if command -v irecovery >/dev/null 2>&1; then
  irecovery -q 2>/dev/null || echo "  no recovery/DFU device"
fi

echo
if [[ -n "$LAST_BOOTCHAIN" && -d "$BUNNY_BOOTCHAIN/$LAST_BOOTCHAIN" ]]; then
  echo "last bootchain: $LAST_BOOTCHAIN"
else
  echo "last bootchain: none"
fi
