#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"

BOOT="${1:-}"
if [[ -z "$BOOT" ]]; then
  [[ -n "$LAST_BOOTCHAIN" ]] || die "No previous bootchain"
  BOOT="$BUNNY_BOOTCHAIN/$LAST_BOOTCHAIN"
fi
[[ -d "$BOOT" ]] || die "bootchain not found: $BOOT"

need_cmd irecovery
need_cmd usbliter8ctl

require_file() {
  local f="$1"
  [[ -s "$f" ]] || die "required bootchain component missing: $f"
}

show_state() {
  local label="$1"
  echo
  echo "===== $label ====="
  irecovery -q 2>&1 || true
}
wait_until_mode_changes() {
  local before="$1"
  local timeout_ms="${2:-8000}"
  local elapsed=0
  local info mode
  while (( elapsed < timeout_ms )); do
    info="$(irecovery -q 2>/dev/null || true)"
    mode="$(awk -F': ' '$1 == "MODE" {print $2; exit}' <<<"$info")"
    if [[ -n "$mode" && "$mode" != "$before" ]]; then
      echo "==> Mode changed: $before -> $mode"
      return 0
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  return 1
}

wait_device() {
  local timeout_ms="${1:-10000}"
  local elapsed=0
  while (( elapsed < timeout_ms )); do
    if irecovery -q >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  return 1
}

wait_mode() {
  local expected="$1"
  local timeout_ms="${2:-10000}"
  local elapsed=0
  local info mode
  while (( elapsed < timeout_ms )); do
    info="$(irecovery -q 2>/dev/null || true)"
    mode="$(awk -F': ' '$1 == "MODE" {print $2; exit}' <<<"$info")"
    [[ "$mode" == "$expected" ]] && return 0
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  return 1
}

require_file "$BOOT/iBSS.patched.raw"
require_file "$BOOT/iBEC.patched.img4"
require_file "$BOOT/devicetree.img4"
require_file "$BOOT/trustcache.img4"
require_file "$BOOT/ramdisk.img4"
require_file "$BOOT/kernelcache.img4.patched"
require_file "$BOOT/chain.info"

USE_SEP="${BUNNY_USE_SEP:-0}"
USE_LOGO=1
while (($#)); do
  case "$1" in
    --sep) USE_SEP=1; shift ;;
    --no-sep) USE_SEP=0; shift ;;
    --no-logo) USE_LOGO=0; shift ;;
    --logo) USE_LOGO=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

log "Loading patched iBSS"
show_state "BEFORE iBSS"
usbliter8ctl boot "$BOOT/iBSS.patched.raw"
wait_mode Recovery 120 || die "iPhone did not enter USB Recovery after iBSS"
show_state "AFTER iBSS"

log "Sending patched iBEC"
irecovery -f "$BOOT/iBEC.patched.img4"
show_state "AFTER iBEC UPLOAD"
log "Starting patched iBEC"
irecovery -c go
wait_mode Recovery 120 || die "iPhone did not enter USB Recovery after iBEC"
show_state "AFTER iBEC GO"

log "Setting display debug background"
irecovery -c "bgcolor 0 0 0" || true

# Show the project boot logo while the kernel/ramdisk is being prepared.
# build.sh normally embeds it as bootchain/logo.img4; if an older bootchain
# lacks it, regenerate it directly from the repository-root logo.jpg.
if (( USE_LOGO )); then
  if [[ ! -s "$BOOT/logo.img4" && -f "$ROOT/logo.jpg" ]]; then
    log "Building missing boot logo from logo.jpg"
    "$BASH" "$ROOT/scripts/make_logo.sh" "$ROOT/logo.jpg" --out "$BOOT/logo.img4"
  fi
  require_file "$BOOT/logo.img4"
  log "Showing project boot logo"
  echo "    logo: $BOOT/logo.img4 ($(stat -c %s "$BOOT/logo.img4") bytes)"
  irecovery -f "$BOOT/logo.img4"
  if irecovery -c "setpicture 1" || irecovery -c "setpicture"; then
    echo "==> setpicture accepted"
    sleep "${BUNNY_LOGO_HOLD_SECS:-3}"
  else
    echo "[!] setpicture failed; continuing without logo" >&2
  fi
else
  echo "==> Project boot logo disabled (--no-logo)"
fi

send_fw() {
  local key="$1" f="$BOOT/$1.img4"
  [[ -s "$f" ]] || return 0
  log "Sending $key"
  irecovery -f "$f"
  irecovery -c firmware
}

# Match the proven iBSS/Option-B sequence used by ICH/BUNNY:
# SPTM/TXM (when present) -> DeviceTree -> TrustCache -> RestoreRamDisk
# -> coprocessor firmware -> kernel -> setenvnp boot-args -> bootx.
if [[ -f "$BOOT/sptm.img4" ]]; then
  send_fw "sptm"
fi
if [[ -f "$BOOT/txm.img4" ]]; then
  send_fw "txm"
fi

if (( USE_SEP )); then
  require_file "$BOOT/sep-firmware.img4"
  log "Sending RestoreSEP (explicit --sep)"
  irecovery -f "$BOOT/sep-firmware.img4"
  irecovery -c rsepfirmware
  show_state "AFTER RESTORESEP"
else
  echo "==> RestoreSEP skipped (default; use --sep to load it)"
fi

log "Sending DeviceTree"
irecovery -f "$BOOT/devicetree.img4"
irecovery -c devicetree
show_state "AFTER DEVICETREE"

log "Sending TrustCache"
irecovery -f "$BOOT/trustcache.img4"
irecovery -c firmware
show_state "AFTER TRUSTCACHE"

log "Sending RestoreRamDisk"
irecovery -f "$BOOT/ramdisk.img4"
irecovery -c ramdisk
show_state "AFTER RAMDISK"

# With iBSS/Option-B, firmware is loaded after the ramdisk and before kernel.
for key in AOP ANE AVE ISP GFX SIO; do
  [[ -s "$BOOT/$key.img4" ]] && send_fw "$key"
done

log "Sending KernelCache"
irecovery -f "$BOOT/kernelcache.img4.patched"
show_state "AFTER KERNELCACHE UPLOAD"

log "Setting boot args"
BOOTARGS="${BUNNY_BOOTARGS:-rd=md0 -v debug=0x2014e serial=3 wdt=-1 keepsyms=1}"
if irecovery -c "setenvnp boot-args $BOOTARGS"; then
  echo "==> setenvnp accepted"
else
  echo "[!] setenvnp failed; trying legacy setenv" >&2
  irecovery -c "setenv boot-args $BOOTARGS"
fi
BOOTARGS_READBACK="$(irecovery -c "getenv boot-args" 2>/dev/null || true)"
echo "    boot-args readback: ${BOOTARGS_READBACK:-<unavailable>}"
if ! grep -Fq "rd=md0" <<<"$BOOTARGS_READBACK"; then
  echo "[x] boot-args readback does not contain rd=md0; refusing blind bootx" >&2
  exit 1
fi

echo "==> Final boot environment"
irecovery -q 2>&1 || true

log "Booting kernel + kc.bpatch"
# bootx causes iBoot to consume the rkrn payload and apply its krnl/kc.bpatch
# property. Do not call the upload itself proof of handoff.
irecovery -c bootx

log "Waiting for Recovery USB disconnect after bootx"
disconnect_wait_ms="${BUNNY_BOOT_DISCONNECT_WAIT_MS:-8000}"
elapsed=0
while (( elapsed < disconnect_wait_ms )); do
  if ! irecovery -q >/dev/null 2>&1; then
    echo "==> Recovery USB disconnected: bootx handed off"
    break
  fi
  sleep 0.1
  elapsed=$((elapsed + 100))
done

if (( elapsed >= disconnect_wait_ms )); then
  echo "[!] First bootx did not leave USB Recovery; retrying once after re-reading iBoot state." >&2
  irecovery -q 2>&1 || true
  irecovery -c bootx || true
  elapsed=0
  while (( elapsed < disconnect_wait_ms )); do
    if ! irecovery -q >/dev/null 2>&1; then
      echo "==> Recovery USB disconnected on bootx retry: handoff occurred"
      break
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
fi

if (( elapsed >= disconnect_wait_ms )); then
  echo "[x] Device never left USB Recovery after bootx/retry." >&2
  echo "    iBoot accepted staging commands but did not hand off to the kernel/ramdisk." >&2
  echo "    Isolation test: rebuild with ./build.sh --kernel stock and run ./boot.sh --no-sep --no-logo." >&2
  irecovery -q 2>&1 || true
  exit 1
fi

echo "==> Waiting for normal USB/usbmuxd or ramdisk SSH (up to 20s)"
for _ in {1..200}; do
  if command -v idevice_id >/dev/null 2>&1 && idevice_id -l 2>/dev/null | grep -q .; then
    echo "==> Device appeared to usbmuxd"
    exit 0
  fi
  sleep 0.1
done

echo "==> Recovery interface did not reappear as usbmuxd within 20s."
echo "    Check ./ssh.sh and USB logs; the important result is that Recovery DID disconnect."
