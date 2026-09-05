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

log "Loading patched iBSS"
show_state "BEFORE iBSS"
usbliter8ctl boot "$BOOT/iBSS.patched.raw"
wait_device 5000 || die "iPhone did not reappear after iBSS"
show_state "AFTER iBSS"

log "Sending patched iBEC"
irecovery -f "$BOOT/iBEC.patched.img4"
show_state "AFTER iBEC UPLOAD"
log "Starting patched iBEC"
irecovery -c go
wait_device 8000 || die "iPhone did not reappear after iBEC"
show_state "AFTER iBEC GO"

log "Setting display debug background"
irecovery -c "bgcolor 0 127 127" || true
log "Sending DeviceTree"
irecovery -f "$BOOT/devicetree.img4"
irecovery -c devicetree
show_state "AFTER DEVICETREE"

for key in SPTM TXM AOP ANE AVE ISP GFX SIO; do
  f="$BOOT/$key.img4"
  [[ -s "$f" ]] || continue
  log "Sending $key"
  irecovery -f "$f"
  irecovery -c firmware
  show_state "AFTER $key"
done

log "Sending TrustCache"
irecovery -f "$BOOT/trustcache.img4"
irecovery -c firmware
show_state "AFTER TRUSTCACHE"

log "Sending RestoreRamDisk"
irecovery -f "$BOOT/ramdisk.img4"
irecovery -c ramdisk
show_state "AFTER RAMDISK"

log "Sending KernelCache"
irecovery -f "$BOOT/kernelcache.img4.patched"
show_state "AFTER KERNELCACHE UPLOAD"

log "Setting boot args"
irecovery -c "setenvnp boot-args rd=md0 -v serial=3 debug=0x2014e wdt=-1"
irecovery -c "setenv auto-boot false"
echo "==> Final boot environment"
irecovery -q || true

log "Booting patched kernel"
irecovery -c bootx
sleep 0.5
echo "==> Device state after bootx"
irecovery -q || true

echo "Boot command sent. Check the display for verbose output, then run ./ssh.sh when SSH is available."
