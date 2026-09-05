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


prepare_ssh_tree() {
  local ssh_tar="$1" list="$2" out="$3"
  [[ -s "$ssh_tar" ]] || die "missing SSH payload: $ssh_tar"
  [[ -s "$list" ]] || die "missing SSH payload allowlist: $list"

  rm -rf "$out"
  mkdir -p "$out"

  # ssh.tar.gz is a project archive; sshtarlist.txt contains project-root
  # paths such as work/sshtar/usr/local/bin/dropbear. For injection we must
  # extract only those files, not the whole archive. The stock RestoreRamDisk
  # already contains the normal /usr/lib, /usr/share, etc. Copying the whole
  # archive can exhaust the small APFS ramdisk and also asks the Linux APFS
  # driver to reproduce metadata it does not support.
  local tar_list="$out/.tar-members"
  : > "$tar_list"

  local entry rel member
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="$(printf '%s\n' "$entry" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$entry" ]] || continue

    case "$entry" in
      work/sshtar/*)
        rel="$(printf '%s\n' "$entry" | sed 's#^work/sshtar/##')"
        ;;
      /*|../*|*/../*|*/..)
        die "unsafe SSH allowlist path: $entry"
        ;;
      *)
        rel="$entry"
        ;;
    esac

    [[ -n "$rel" ]] || continue
    case "$rel" in
      /*|../*|*/../*|*/..) die "unsafe SSH archive member: $rel" ;;
    esac
    printf '%s\n' "$rel" >> "$tar_list"
  done < "$list"

  [[ -s "$tar_list" ]] || die "SSH allowlist contains no usable paths"

  # Check that every requested file exists in the archive before touching the
  # ramdisk. GNU tar's --keep-old-files is deliberately not used: several
  # SSH payload paths intentionally replace stock utilities.
  if ! tar -tzf "$ssh_tar" --verbatim-files-from -T "$tar_list" >/dev/null 2>&1; then
    die "SSH archive does not contain one or more allowlisted files"
  fi

  sudo tar -xzf "$ssh_tar"     -C "$out"     --verbatim-files-from     --no-same-owner     --no-acls     --no-xattrs     --numeric-owner     --no-overwrite-dir     -T "$tar_list" ||
    die "could not selectively extract SSH payload"

  # The archive may use project-root paths (work/sshtar/...). Normalize the
  # extracted tree to the ramdisk root expected by the injection code.
  if [[ -d "$out/work/sshtar" ]]; then
    cp -a "$out/work/sshtar/." "$out/" || die "failed to normalize work/sshtar"
    rm -rf "$out/work"
  fi
  if [[ -d "$out/sshtar" && ! -d "$out/usr" && ! -d "$out/bin" && ! -d "$out/sbin" ]]; then
    cp -a "$out/sshtar/." "$out/" || die "failed to normalize sshtar"
    rm -rf "$out/sshtar"
  fi

  rm -f "$tar_list"
  [[ -d "$out/usr" || -d "$out/bin" || -d "$out/sbin" ]] ||
    die "SSH payload has no expected Unix tree after normalization"
}

verify_ssh_allowlist() {
  local root="$1" list="$2"
  [[ -s "$list" ]] || die "missing SSH payload allowlist: $list"

  local entry rel
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="$(printf '%s\n' "$entry" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$entry" ]] || continue

    case "$entry" in
      work/sshtar/*) rel="$(printf '%s\n' "$entry" | sed 's#^work/sshtar/##')" ;;
      *) rel="$entry" ;;
    esac

    [[ -f "$root/$rel" || -L "$root/$rel" ]] ||
      die "SSH payload missing allowlisted file: $rel"
  done < "$list"
}

inject_apfs() {
  local stock="$1" ssh_tar="$2" out="$3" stock_offset="$4"
  load_apfs

  local src_mp src size free_before free_after
  src_mp="$ROOT/work/apfs-src.$$"
  rm -f "$out"
  mkdir -p "$src_mp"

  # Do not reconstruct an Apple APFS ramdisk with tar. The filesystem contains
  # sparse/cloned extents and a large firmware tree; copying it file-by-file
  # can require several times the on-disk image size. Copy the original image
  # byte-for-byte, then modify the APFS volume in place.
  cp --reflink=auto --sparse=always "$stock" "$out"
  size="$(stat -c %s "$out")"
  echo "    APFS image size: $size bytes"

  mount_image "$out" "$src_mp" rw apfs "$stock_offset"

  free_before="$(df -B1 --output=avail "$src_mp" | tail -n1 | tr -d '[:space:]')"
  [[ "$free_before" =~ ^[0-9]+$ ]] || die "could not determine APFS free space"
  echo "    free before injection: $free_before bytes"


  log "Injecting SSH into APFS ramdisk"
  local ssh_list="$BUNNY_RESOURCES/sshtarlist.txt"
  local ssh_stage="$ROOT/work/ssh-stage-apfs.$"
  prepare_ssh_tree "$ssh_tar" "$BUNNY_RESOURCES/sshtarlist.txt" "$ssh_stage"
  verify_ssh_allowlist "$ssh_stage" "$ssh_list"

  sudo cp -a "$ssh_stage/." "$src_mp/" ||
    { rm -rf "$ssh_stage"; die "SSH payload injection failed while copying into APFS"; }
  rm -rf "$ssh_stage"

  if [[ -n "${BUNNY_RESTORED_EXTERNAL:-}" && -s "$BUNNY_RESTORED_EXTERNAL" ]]; then
    sudo install -D -m 0755 "$BUNNY_RESTORED_EXTERNAL"       "$src_mp/usr/local/bin/restored_external" ||
      die "failed to install restored_external"
    echo "    installed ICH restored_external"
  fi
  free_after="$(df -B1 --output=avail "$src_mp" | tail -n1 | tr -d '[:space:]')"
  [[ "$free_after" =~ ^[0-9]+$ ]] || die "could not determine APFS free space after injection"
  echo "    free after injection: $free_after bytes"

  if (( free_after >= free_before )); then
    echo "[x] APFS free space did not decrease after SSH injection." >&2
    die "SSH injection verification failed"
  fi

  if ! sudo find "$src_mp" -type f \( -name ssh -o -name dropbear -o -name sshd \) -print -quit | grep -q .; then
    die "SSH payload verification failed: no SSH executable found"
  fi

  unmount_image "$src_mp"
  rmdir "$src_mp" 2>/dev/null || true

  # Re-open the image read-only as a final filesystem integrity check.
  local check_mp="$ROOT/work/apfs-check.$"
  mkdir -p "$check_mp"
  mount_image "$out" "$check_mp" ro apfs "$stock_offset"
  sudo test -d "$check_mp/usr" || die "APFS integrity check failed: /usr is missing"
  sudo test -d "$check_mp/private" || die "APFS integrity check failed: /private is missing"
  unmount_image "$check_mp"
  rmdir "$check_mp" 2>/dev/null || true
}

inject_hfsplus() {
  local stock="$1" ssh_tar="$2" out="$3" stock_offset="$4"
  local mp="$ROOT/work/hfs.$$"
  mkdir -p "$mp"

  cp --reflink=auto "$stock" "$out"
  log "Mounting stock HFS+ ramdisk (offset=$stock_offset)"
  mount_image "$out" "$mp" rw hfsplus "$stock_offset"


  log "Injecting SSH"
  local ssh_stage="$ROOT/work/ssh-stage-hfs.$$"
  prepare_ssh_tree "$ssh_tar" "$BUNNY_RESOURCES/sshtarlist.txt" "$ssh_stage"
  verify_ssh_allowlist "$ssh_stage" "$BUNNY_RESOURCES/sshtarlist.txt"
  sudo cp -a "$ssh_stage/." "$mp/" || die "SSH payload injection failed"
  rm -rf "$ssh_stage"

  if [[ -n "${BUNNY_RESTORED_EXTERNAL:-}" && -s "$BUNNY_RESTORED_EXTERNAL" ]]; then
    sudo install -D -m 0755 "$BUNNY_RESTORED_EXTERNAL" \
      "$mp/usr/local/bin/restored_external" ||
      die "failed to install restored_external"
  fi
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
