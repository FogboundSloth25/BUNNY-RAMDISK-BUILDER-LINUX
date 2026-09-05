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
if [[ ! -s "$BOOT/logo.img4" && -f "$ROOT/logo.jpg" ]]; then
  log "Building missing boot logo from logo.jpg"
  "$ROOT/scripts/make_logo.sh" "$ROOT/logo.jpg" --out "$BOOT/logo.img4"
fi
require_file "$BOOT/logo.img4"
log "Showing project boot logo"
echo "    logo: $BOOT/logo.img4 ($(stat -c %s "$BOOT/logo.img4") bytes)"
irecovery -f "$BOOT/logo.img4"
if ! irecovery -c "setpicture 1"; then
  die "setpicture 1 failed after logo upload; refusing to continue without verified boot logo"
fi
sleep "${BUNNY_LOGO_HOLD_SECS:-3}"

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

if [[ -s "$BOOT/sep-firmware.img4" ]]; then
  log "Sending RestoreSEP"
  irecovery -f "$BOOT/sep-firmware.img4"
  irecovery -c rsepfirmware
  show_state "AFTER RESTORESEP"
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
BOOTARGS="${BUNNY_BOOTARGS:-rd=md0 -v debug=0x14e serial=3 wdt=-1 keepsyms=1}"
irecovery -c "setenvnp boot-args $BOOTARGS" || \
  irecovery -c "setenv boot-args $BOOTARGS"
# Do not force auto-boot=false here: an explicit bootx is the requested transition.

echo "==> Final boot environment"
irecovery -q 2>&1 || true

log "Booting kernel + kc.bpatch"
# bootx causes iBoot to consume the rkrn payload and apply its krnl/kc.bpatch
# property. Do not call the upload itself proof of handoff.
irecovery -c bootx

log "Waiting for Recovery USB disconnect after bootx"
disconnect_wait_ms="${BUNNY_BOOT_DISCONNECT_WAIT_MS:-15000}"
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
  echo "[x] Device never left USB Recovery after bootx." >&2
  echo "    This means the host still sees iBoot Recovery; the kernel/ramdisk did not reach a normal boot state." >&2
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
