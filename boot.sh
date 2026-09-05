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

have_cmd usbliter8ctl || die "missing usbliter8ctl; run ./setup_dependencies.sh"

# libirecovery reconnects quickly during DFU/iBEC transitions. Poll at 100 ms
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

if [[ ! -x "$(command -v usbliter8ctl)" ]]; then
  die "usbliter8ctl is not available in PATH"
fi
if [[ -f "$BOOT/iBSS.patched.raw" ]]; then
  log "Loading patched iBSS"
  usbliter8ctl boot "$BOOT/iBSS.patched.raw"
  wait_device 5000 || die "iPhone did not reappear after iBSS"
elog=""; true
else
  die "missing iBSS.patched.raw in bootchain; rebuild with iBSS enabled"
fi

wait_device 5000 || die "iPhone not visible through libirecovery"
require_file() { local f="$1"; [[ -s "$f" ]] || die "required bootchain component missing: $f"; }
require_file "$BOOT/iBSS.patched.raw"
require_file "$BOOT/iBEC.patched.img4"
require_file "$BOOT/devicetree.img4"
require_file "$BOOT/trustcache.img4"
require_file "$BOOT/ramdisk.img4"
require_file "$BOOT/kernelcache.img4.patched"
log "Sending patched iBEC"
irecovery -f "$BOOT/iBEC.patched.img4"
wait_device 8000 || die "iPhone did not reappear after iBEC"

send_if_present() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  log "Sending $(basename "$f")"
  irecovery -f "$f"
}

send_if_present "$BOOT/devicetree.img4"
for key in SPTM TXM AOP ANE AVE ISP GFX SIO; do
  send_if_present "$BOOT/$key.img4"
done
send_if_present "$BOOT/trustcache.img4"
send_if_present "$BOOT/ramdisk.img4"
send_if_present "$BOOT/kernelcache.img4.patched"

log "Setting boot args"
irecovery -c "setenv boot-args rd=md0 -v serial=3 debug=0x2014e"
log "Booting"
irecovery -c bootx
echo "Boot command sent. Run ./ssh.sh when SSH is available."
