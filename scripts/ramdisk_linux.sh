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

  is_apfs_registered() {
    [[ -d /sys/module/apfs ]] && return 0
    grep -Eq '(^|[[:space:]])apfs([[:space:]]|$)' /proc/filesystems 2>/dev/null && return 0
    grep -Eq '^apfs[[:space:]]' /proc/modules 2>/dev/null && return 0
    return 1
  }

  if is_apfs_registered; then
    echo "==> Linux APFS filesystem driver already registered"
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
    die "APFS module vermagic does not match running kernel: $vermagic"
  fi

  if [[ -n "$deps" ]]; then
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      sudo modprobe "$dep" || die "could not load APFS dependency: $dep"
    done < <(tr ',' '
' <<<"$deps")
  fi

  errlog="$(mktemp /tmp/bunny-apfs-load.XXXXXX)"
  if sudo insmod "$mod" 2>"$errlog"; then
    rm -f "$errlog"
  else
    if grep -qiE 'File exists|already exists|already loaded' "$errlog"; then
      echo "==> APFS module is already registered; continuing"
    else
      echo "[x] APFS module load failed." >&2
      cat "$errlog" >&2 || true
      echo "    kernel log:" >&2
      dmesg | tail -n 40 >&2 2>/dev/null || true
      rm -f "$errlog"
      die "could not load Linux APFS module for kernel $kernel"
    fi
    rm -f "$errlog"
  fi

  if is_apfs_registered; then
    echo "==> Linux APFS filesystem driver ready"
    return 0
  fi

  echo "[x] insmod returned, but APFS is not visible as a loaded/registered filesystem." >&2
  echo "    /sys/module/apfs:" >&2
  [[ -d /sys/module/apfs ]] && echo "      present" >&2 || echo "      absent" >&2
  echo "    /proc/filesystems:" >&2
  grep -E 'apfs' /proc/filesystems >&2 2>/dev/null || true
  die "APFS filesystem driver was not registered"
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

  # idevicerestore advertises a 0x20000000 (512 MiB) RestoreRamDisk
  # workspace for this generation. The compressed IMG4 payload is much
  # smaller, so sizing a new APFS filesystem from stat(1) + 128 MiB can
  # under-allocate the filesystem badly. Use the restore ramdisk capacity
  # as the deterministic destination size.
  target=$((0x20000000))
  if (( target <= size )); then
    target=$((size + 64 * 1024 * 1024))
  fi

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

  local available
  available="$(df -B1 --output=avail "$dst_mp" | tail -n1 | tr -d '[:space:]')"
  [[ "$available" =~ ^[0-9]+$ ]] || die "could not determine free space on new APFS ramdisk"
  echo "    available: $available bytes"

  if (( available < size / 2 )); then
    echo "[x] New APFS ramdisk has unexpectedly little free space." >&2
    df -h "$dst_mp" >&2 || true
    die "APFS destination capacity is insufficient"
  fi

  log "Copying stock APFS ramdisk"
  # Do not copy xattrs/ACLs through linux-apfs-rw. The driver can report
  # oversized/unsupported xattr lists (E2BIG) and reproducing them is neither
  # required for the builder's injected ramdisk nor reliable on Linux.
  if ! (cd "$src_mp" && sudo tar --sparse --no-acls --no-xattrs --numeric-owner -cpf - .) |
     (cd "$dst_mp" && sudo tar --sparse --no-acls --no-xattrs --numeric-owner -xpf -); then
    die "failed to copy stock APFS ramdisk"
  fi

  available="$(df -B1 --output=avail "$dst_mp" | tail -n1 | tr -d '[:space:]')"
  echo "    available after copy: $available bytes"
  [[ "$available" =~ ^[0-9]+$ ]] || die "could not determine APFS free space after copy"

  log "Injecting SSH"
  sudo tar --sparse --no-acls --no-xattrs --numeric-owner -xpf "$ssh_tar" -C "$dst_mp"
  sync

  if ! sudo find "$dst_mp" -type f \( -name ssh -o -name dropbear -o -name sshd \) -print -quit | grep -q .; then
    echo "[x] SSH payload was extracted, but no SSH executable was found in the ramdisk." >&2
    die "SSH payload verification failed"
  fi

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
