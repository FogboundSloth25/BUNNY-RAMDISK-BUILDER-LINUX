#!/usr/bin/env bash
set -euo pipefail

# This file is sourced by build.sh. Do not derive the project root from $0:
# when sourced, $0 belongs to the caller (build.sh), not this file.
ROOT="${BUNNY_ROOT:?BUNNY_ROOT must be set by env.sh}"

magic() {
  "$ROOT/.venv/bin/python" - "$1" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
with p.open("rb") as f:
    f.seek(0x20); m=f.read(4)
if m == b"NXSB":
    print("apfs"); raise SystemExit
with p.open("rb") as f:
    f.seek(1024); m=f.read(2)
print("hfsplus" if m in (b"H+", b"HX") else "unknown")
PY
}

load_apfs() {
  local mod="$BUNNY_THIRD_PARTY/linux-apfs-rw/apfs.ko"
  grep -qw '^apfs ' /proc/modules 2>/dev/null && return 0
  sudo modprobe libcrc32c 2>/dev/null || true
  sudo modprobe apfs 2>/dev/null || true
  if ! grep -qw '^apfs ' /proc/modules 2>/dev/null && [[ -f "$mod" ]]; then
    sudo insmod "$mod"
  fi
  grep -qw '^apfs ' /proc/modules 2>/dev/null || die "could not load Linux APFS module"
}

inject_apfs() {
  local stock="$1" ssh_tar="$2" out="$3"
  load_apfs

  local size target src_mp dst_mp src
  size="$(stat -c %s "$stock")"
  target=$((size + 128 * 1024 * 1024))
  (( target < 256 * 1024 * 1024 )) && target=$((256 * 1024 * 1024))

  src="$ROOT/work/ramdisk-source.$$"
  src_mp="$ROOT/work/apfs-src.$$"
  dst_mp="$ROOT/work/apfs-dst.$$"
  rm -f "$src" "$out"
  cp --reflink=auto --sparse=always "$stock" "$src"
  truncate -s "$target" "$out"
  sudo "$BUNNY_TOOLS/mkapfs" "$out"

  mkdir -p "$src_mp" "$dst_mp"
  cleanup() {
    sudo umount "$dst_mp" 2>/dev/null || true
    sudo umount "$src_mp" 2>/dev/null || true
    rm -f "$src"
    rmdir "$src_mp" "$dst_mp" 2>/dev/null || true
  }
  trap cleanup RETURN

  sudo mount -o loop,ro "$src" "$src_mp"
  sudo mount -o loop,rw "$out" "$dst_mp"

  log "Copying stock APFS ramdisk"
  (cd "$src_mp" && sudo tar --xattrs --acls --numeric-owner -cpf - .) |
    (cd "$dst_mp" && sudo tar --xattrs --acls --numeric-owner -xpf -)

  log "Injecting SSH"
  sudo tar --xattrs --acls --numeric-owner -xpf "$ssh_tar" -C "$dst_mp"
  sync
}

inject_hfsplus() {
  local stock="$1" ssh_tar="$2" out="$3"
  local mp="$ROOT/work/hfs.$$"
  mkdir -p "$mp"
  cp --reflink=auto "$stock" "$out"
  sudo mount -t hfsplus -o loop,rw "$out" "$mp"
  sudo tar --xattrs --acls --numeric-owner -xpf "$ssh_tar" -C "$mp"
  sync
  sudo umount "$mp"
  rmdir "$mp"
}

inject_ssh_ramdisk() {
  local stock="$1" ssh_tar="$2" out="$3"
  [[ -s "$stock" ]] || die "missing ramdisk: $stock"
  [[ -s "$ssh_tar" ]] || die "missing SSH payload: $ssh_tar"

  local fs
  fs="$(magic "$stock")"
  log "Ramdisk filesystem: $fs"
  case "$fs" in
    apfs) inject_apfs "$stock" "$ssh_tar" "$out" ;;
    hfsplus) inject_hfsplus "$stock" "$ssh_tar" "$out" ;;
    *) die "unsupported ramdisk filesystem: $fs" ;;
  esac
}
