#!/usr/bin/env bash
set -euo pipefail

ROOT="${BUNNY_ROOT:?BUNNY_ROOT must be set by env.sh}"

# RestoreRamDisk files are disk images.  Do not identify a filesystem by a
# loose string match: random H+/HX/NXSB bytes inside a DMG can produce a
# completely bogus offset.  APFS is validated from the NXSB fields instead.
detect_fs() {
  "$ROOT/.venv/bin/python" - "$1" <<'PY'
from pathlib import Path
import mmap
import os
import struct
import sys

p = Path(sys.argv[1])
size = p.stat().st_size
if size == 0:
    raise SystemExit("unknown")

with p.open("rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    pos = mm.find(b"NXSB")
    while pos >= 0:
        start = pos - 0x20
        if start >= 0 and start % 4096 == 0 and start + 0x30 <= size:
            block_size = struct.unpack_from("<I", mm, start + 0x24)[0]
            block_count = struct.unpack_from("<Q", mm, start + 0x28)[0]
            if (
                block_size in (4096, 8192, 16384, 32768, 65536)
                and block_count > 0
                and block_count <= (size - start) // block_size + 1
            ):
                print(f"apfs {start}")
                mm.close()
                raise SystemExit
        pos = mm.find(b"NXSB", pos + 1)

    # HFS+ is retained only as an explicit legacy fallback. Modern iOS builds
    # therefore cannot silently become HFS+ after a failed APFS probe.
    if os.environ.get("BUNNY_ALLOW_HFSPLUS") == "1":
        for sig in (b"H+", b"HX"):
            pos = mm.find(sig)
            while pos >= 0:
                start = pos - 1024
                if start >= 0 and start % 512 == 0 and start + 1028 <= size:
                    version = struct.unpack_from(">H", mm, start + 1026)[0]
                    if version == 4:
                        print(f"hfsplus {start}")
                        mm.close()
                        raise SystemExit
                pos = mm.find(sig, pos + 1)

    mm.close()

raise SystemExit("unknown")
PY
}

load_apfs() {
  local mod="$BUNNY_THIRD_PARTY/linux-apfs-rw/apfs.ko"
  local kernel vermagic deps signer errlog

  kernel="$(uname -r)"

  if grep -qw '^apfs ' /proc/modules 2>/dev/null; then
    return 0
  fi

  [[ -f "$mod" ]] || die "Linux APFS module not found: $mod"

  echo "==> Loading Linux APFS module"
  echo "    kernel: $kernel"
  echo "    module: $mod"

  vermagic="$(modinfo -F vermagic "$mod" 2>/dev/null || true)"
  deps="$(modinfo -F depends "$mod" 2>/dev/null || true)"
  signer="$(modinfo -F signer "$mod" 2>/dev/null || true)"
  echo "    vermagic: ${vermagic:-unknown}"
  echo "    depends:  ${deps:-none}"
  echo "    signer:   ${signer:-none}"

  if [[ -n "$vermagic" && "$vermagic" != "$kernel"* ]]; then
    echo "[x] APFS module vermagic does not match running kernel." >&2
    die "rebuild apfs.ko with the current kernel headers"
  fi

  rm -f /tmp/bunny-apfs-*.err
  sudo modprobe libcrc32c 2>/tmp/bunny-apfs-libcrc32c.err || true
  sudo modprobe crc32c 2>/tmp/bunny-apfs-crc32c.err || true

  if sudo modprobe "$mod" 2>/tmp/bunny-apfs-modprobe.err; then
    grep -qw '^apfs ' /proc/modules && return 0
  fi

  errlog="$(mktemp /tmp/bunny-apfs-load.XXXXXX)"
  if sudo insmod "$mod" 2>"$errlog"; then
    rm -f "$errlog"
    grep -qw '^apfs ' /proc/modules && return 0
  fi

  echo "[x] APFS module load failed." >&2
  echo "    insmod:" >&2
  cat "$errlog" >&2 || true
  echo "    modprobe libcrc32c:" >&2
  cat /tmp/bunny-apfs-libcrc32c.err >&2 2>/dev/null || true
  echo "    modprobe crc32c:" >&2
  cat /tmp/bunny-apfs-crc32c.err >&2 2>/dev/null || true
  echo "    kernel log:" >&2
  dmesg | tail -n 40 >&2 2>/dev/null || true

  rm -f "$errlog" /tmp/bunny-apfs-*.err
  die "could not load Linux APFS module for kernel $kernel"
}

mount_image() {
  local image="$1" mountpoint="$2" mode="$3" fstype="$4" offset="$5"
  local loopdev="" statefile="${mountpoint}.bunny-loopdev"

  mkdir -p "$mountpoint"
  rm -f "$statefile"

  # Explicit losetup makes the DMG/container offset observable and avoids
  # depending on mount(8)'s implicit loop-device handling.
  if [[ "$offset" != 0 ]]; then
    if [[ "$mode" == ro ]]; then
      loopdev="$(sudo losetup --find --show --read-only --offset "$offset" "$image")"
    else
      loopdev="$(sudo losetup --find --show --offset "$offset" "$image")"
    fi
  else
    if [[ "$mode" == ro ]]; then
      loopdev="$(sudo losetup --find --show --read-only "$image")"
    else
      loopdev="$(sudo losetup --find --show "$image")"
    fi
  fi

  if [[ "$fstype" == apfs ]]; then
    if [[ "$mode" == rw ]]; then
      if ! sudo mount -t apfs -o readwrite "$loopdev" "$mountpoint"; then
        sudo losetup -d "$loopdev" 2>/dev/null || true
        die "failed to mount APFS image: $image (offset=$offset)"
      fi
    else
      if ! sudo mount -t apfs -o ro "$loopdev" "$mountpoint"; then
        sudo losetup -d "$loopdev" 2>/dev/null || true
        die "failed to mount APFS image read-only: $image (offset=$offset)"
      fi
    fi
  elif [[ "$fstype" == hfsplus ]]; then
    if [[ "$mode" == rw ]]; then
      if ! sudo mount -t hfsplus -o rw "$loopdev" "$mountpoint"; then
        sudo losetup -d "$loopdev" 2>/dev/null || true
        die "failed to mount HFS+ image: $image (offset=$offset)"
      fi
    else
      if ! sudo mount -t hfsplus -o ro "$loopdev" "$mountpoint"; then
        sudo losetup -d "$loopdev" 2>/dev/null || true
        die "failed to mount HFS+ image read-only: $image (offset=$offset)"
      fi
    fi
  else
    sudo losetup -d "$loopdev" 2>/dev/null || true
    die "unsupported filesystem: $fstype"
  fi

  # State must live beside the mountpoint, never inside the mounted APFS
  # volume. This also means read-only mounts remain genuinely read-only.
  printf '%s\n' "$loopdev" > "$statefile"
}

unmount_image() {
  local mp="$1"
  local statefile="${mp}.bunny-loopdev"
  local loopdev=""

  [[ -f "$statefile" ]] && loopdev="$(<"$statefile")"
  sudo umount "$mp" 2>/dev/null || true
  if [[ -n "$loopdev" ]]; then
    sudo losetup -d "$loopdev" 2>/dev/null || true
  fi
  rm -f "$statefile"
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

  [[ -s "${dst_mp}.bunny-loopdev" ]] || die "APFS destination loop device missing"
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
    echo "[x] Could not validate a supported ramdisk filesystem." >&2
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
