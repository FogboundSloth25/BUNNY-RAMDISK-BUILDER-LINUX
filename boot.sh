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

have_cmd usbliter8ctl || true
if have_cmd usbliter8ctl && [[ -f "$BOOT/iBSS.patched.raw" ]]; then
  log "Loading patched iBSS"
  usbliter8ctl boot "$BOOT/iBSS.patched.raw"
  sleep 2
fi

wait_device() {
  for _ in $(seq 1 40); do
    irecovery -q >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_device || die "iPhone not visible through libirecovery"
log "Sending patched iBEC"
irecovery -f "$BOOT/iBEC.patched.img4"
sleep 2
wait_device || die "iPhone did not reappear after iBEC"
sleep 1

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
