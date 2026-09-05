send_fw() {
  local key="$1" f="$BOOT/$1.img4"
  [[ -s "$f" ]] || return 0
  log "Sending $key"
  irecovery -f "$f"
  irecovery -c firmware
}

if (( USE_SEP < 0 )); then

  if [[ -s "$BOOT/sep-firmware.img4" ]]; then USE_SEP=1; else USE_SEP=0; fi
fi
if (( USE_SEP )); then
  require_file "$BOOT/sep-firmware.img4"
  log "Sending RestoreSEP (rsepfirmware)"
  irecovery -f "$BOOT/sep-firmware.img4"
  irecovery -c rsepfirmware
  show_state "AFTER RESTORESEP"
else
  echo "==> RestoreSEP disabled (--no-sep)"
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

# Option-B / iBSS path loads USB firmware after the ramdisk, matching the
# upstream usbliter8ra1n sequence.
if [[ -s "$BOOT/iBSS.patched.raw" ]]; then
  for key in sptm txm AOP ANE AVE ISP GFX SIO; do
    [[ -s "$BOOT/$key.img4" ]] && send_fw "$key"
  done
fi

log "Sending KernelCache"
irecovery -f "$BOOT/kernelcache.img4.patched"
show_state "AFTER KERNELCACHE UPLOAD"

log "Setting boot args"
BOOTARGS="${BUNNY_BOOTARGS:-rd=md0 -v debug=0x14e serial=3 wdt=-1 keepsyms=1}"
if irecovery -c "setenvnp boot-args $BOOTARGS"; then
  echo "==> setenvnp accepted"
else
  echo "[!] setenvnp failed; trying legacy setenv" >&2
  irecovery -c "setenv boot-args $BOOTARGS"
fi
# Some libirecovery builds do not expose getenv as a client command and
 # legitimately return no readback. Command acceptance above is the
 # authoritative transport check on this path.
BOOTARGS_READBACK="$(irecovery -c "getenv boot-args" 2>/dev/null || true)"
if [[ -n "$BOOTARGS_READBACK" ]]; then
  echo "    boot-args readback: $BOOTARGS_READBACK"
else
  echo "    boot-args readback: unavailable (client does not expose getenv)"
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
