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
irecovery -c "bgcolor 0 127 127" || true

send_fw() {
  local key="$1" f="$BOOT/$1.img4"
  [[ -s "$f" ]] || return 0
  log "Sending $key"
  irecovery -f "$f"
  irecovery -c firmware
}

if [[ ! -f "$BOOT/iBSS.patched.raw" ]]; then
  # Direct iBEC path: upstream sends USB/coprocessor firmware before DT.
  for key in SPTM TXM AOP ANE AVE ISP GFX SIO; do
    [[ -s "$BOOT/$key.img4" ]] && send_fw "$key"
  done
  log "Sending DeviceTree"
  irecovery -f "$BOOT/devicetree.img4"
  irecovery -c devicetree
fi

log "Sending TrustCache"
irecovery -f "$BOOT/trustcache.img4"
irecovery -c firmware

log "Sending RestoreRamDisk"
irecovery -f "$BOOT/ramdisk.img4"
irecovery -c ramdisk

# Critical for normal USB enumeration on the iBSS/Option-B path:
# firmware follows the ramdisk and precedes the kernel, matching ICH/BUNNY.
if [[ -f "$BOOT/iBSS.patched.raw" ]]; then
  for key in SPTM TXM AOP ANE AVE ISP GFX SIO; do
    [[ -s "$BOOT/$key.img4" ]] && send_fw "$key"
  done
fi

log "Sending KernelCache"
irecovery -f "$BOOT/kernelcache.img4.patched"

log "Setting boot args"
irecovery -c "setenvnp boot-args rd=md0 -v debug=0x14e serial=3 wdt=-1 keepsyms=1" ||   irecovery -c "setenv boot-args rd=md0 -v debug=0x14e serial=3 wdt=-1 keepsyms=1"
irecovery -c "setenv auto-boot false" || true

echo "==> Final boot environment"
irecovery -q 2>&1 || true

log "Booting patched kernel"
irecovery -c bootx
sleep 0.5
echo "==> Device state after bootx"
irecovery -q 2>&1 || true

echo "Boot command sent. Check the display for verbose output, then run ./ssh.sh when SSH is available."
