#!/usr/bin/env bash
set -euo pipefail

ROOT="${BUNNY_ROOT:?BUNNY_ROOT must be set by env.sh}"

detect_fs() {
  "$ROOT/.venv/bin/python" - "$1" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
limit = min(p.stat().st_size, 32 * 1024 * 1024)
data = p.read_bytes()[:limit]

# APFS: NXSB magic is 0x20 bytes into a 4096-byte container superblock.
for pos in range(0, len(data) - 4):
    if data[pos:pos+4] == b"NXSB":
        start = pos - 0x20
        if start >= 0 and start % 4096 == 0:
            print(f"apfs {start}")
            raise SystemExit

# HFS+/HFSX: signature is at +1024 from volume start.
for sig in (b"H+", b"HX"):
    pos = data.find(sig)
    while pos >= 0:
        start = pos - 1024
        if start >= 0 and start % 512 == 0:
            print(f"hfsplus {start}")
            raise SystemExit
        pos = data.find(sig, pos + 1)

raise SystemExit("unknown")
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

  grep -qw '^apfs ' /proc/modules 2>/dev/null ||
    die "could not load Linux APFS module"
}

mount_image() {
  local image="$1" mountpoint="$2" mode="$3" fstype="$4" offset="$5"

  mkdir -p "$mountpoint"

  local opts="loop"
  [[ "$mode" == ro ]] && opts+=",ro"
  [[ "$offset" != 0 ]] && opts+=",offset=$offset"

  if [[ "$fstype" == apfs ]]; then
    sudo mount -t apfs -o "$opts" "$image" "$mountpoint"
  else
    sudo mount -t hfsplus -o "$opts" "$image" "$mountpoint"
  fi
}

unmount_image() {
  local mp="$1"
  sudo umount "$mp" 2>/dev/null || true
}

inject_apfs() {
  local stock="$1" ssh_tar="$2" out="$3" stock_offset="$4"
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
    unmount_image "$dst_mp"
    unmount_image "$src_mp"
    rm -f "$src"
    rmdir "$src_mp" "$dst_mp" 2>/dev/null || true
  }
  trap cleanup RETURN

  log "Mounting stock APFS ramdisk (offset=$stock_offset)"
  mount_image "$src" "$src_mp" ro apfs "$stock_offset"

  log "Mounting new APFS ramdisk"
  mount_image "$out" "$dst_mp" rw apfs 0

  log "Copying stock APFS ramdisk"
  (cd "$src_mp" && sudo tar --xattrs --acls --numeric-owner -cpf - .) |
    (cd "$dst_mp" && sudo tar --xattrs --acls --numeric-owner -xpf -)

  log "Injecting SSH"
  sudo tar --xattrs --acls --numeric-owner -xpf "$ssh_tar" -C "$dst_mp"
  sync
}

inject_hfsplus() {
  local stock="$1" ssh_tar="$2" out="$3" stock_offset="$4"
  local mp="$ROOT/work/hfs.$$"
  mkdir -p "$mp"

  cp --reflink=auto "$stock" "$out"
  log "Mounting stock HFS+ ramdisk (offset=$stock_offset)"
  mount_image "$out" "$mp" rw hfsplus "$stock_offset"

  log "Injecting SSH"
  sudo tar --xattrs --acls --numeric-owner -xpf "$ssh_tar" -C "$mp"
  sync
  unmount_image "$mp"
  rmdir "$mp" 2>/dev/null || true
}

inject_ssh_ramdisk() {
  local stock="$1" ssh_tar="$2" out="$3"
  [[ -s "$stock" ]] || die "missing ramdisk: $stock"
  [[ -s "$ssh_tar" ]] || die "missing SSH payload: $ssh_tar"

  local detection fs offset
  detection="$(detect_fs "$stock" 2>/dev/null || true)"

  if [[ -z "$detection" || "$detection" == unknown ]]; then
    echo "[x] Could not detect ramdisk filesystem." >&2
    echo "    file: $(file -b "$stock" 2>/dev/null || echo unavailable)" >&2
    echo "    first bytes:" >&2
    od -An -tx1 -N64 "$stock" >&2 || true
    die "unsupported ramdisk filesystem"
  fi

  read -r fs offset <<<"$detection"
  log "Ramdisk filesystem: $fs (offset=$offset)"

  case "$fs" in
    apfs) inject_apfs "$stock" "$ssh_tar" "$out" "$offset" ;;
    hfsplus) inject_hfsplus "$stock" "$ssh_tar" "$out" "$offset" ;;
    *) die "unsupported ramdisk filesystem: $fs" ;;
  esac
}
