#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"

trap cleanup_usbmuxd EXIT INT TERM HUP

need_cmd iproxy
need_cmd ssh

USBMUXD_PRIVATE_SOCKET="$HOME/.cache/bunny-usbmuxd.sock"
USBMUXD_PRIVATE_MASKED=0
USBMUXD_PRIVATE_STARTED=0

cleanup_usbmuxd() {
  local rc=$?
  trap - EXIT INT TERM HUP

  if (( USBMUXD_PRIVATE_STARTED )); then
    sudo pkill -TERM -x usbmuxd 2>/dev/null || true
    for _ in {1..30}; do
      pgrep -x usbmuxd >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi

  if (( USBMUXD_PRIVATE_MASKED )); then
    sudo systemctl unmask usbmuxd.service usbmuxd.socket 2>/dev/null || true
  fi

  rm -f "$USBMUXD_PRIVATE_SOCKET"
  exit "$rc"
}

start_usbmuxd() {
  [[ "${BUNNY_USBMUX_AUTOSTART:-1}" == 1 ]] || return 0
  command -v usbmuxd >/dev/null 2>&1 || die "usbmuxd not found"

  mkdir -p "$(dirname "$USBMUXD_PRIVATE_SOCKET")"
  rm -f "$USBMUXD_PRIVATE_SOCKET"

  # The desktop's GVFS/UPower clients connect to the global usbmuxd socket and
  # probe Apple's lockdownd port 62078. A Bunny ramdisk deliberately does not
  # expose lockdownd, so those probes produce harmless but confusing traffic.
  # More importantly, they can race the private SSH connection. Isolate Bunny
  # from the desktop by giving our usbmuxd its own UNIX socket.
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl mask --runtime usbmuxd.service usbmuxd.socket >/dev/null 2>&1 || true
    if sudo systemctl is-enabled usbmuxd.service >/dev/null 2>&1 ||
       sudo systemctl is-enabled usbmuxd.socket >/dev/null 2>&1; then
      USBMUXD_PRIVATE_MASKED=1
    else
      # mask --runtime may succeed even when the unit has no enabled state;
      # explicitly record the mask so cleanup always restores it.
      systemctl list-unit-files usbmuxd.service usbmuxd.socket >/dev/null 2>&1 &&
        USBMUXD_PRIVATE_MASKED=1
    fi
  fi

  # Stop any pre-existing daemon before claiming the USB interface.
  sudo pkill -TERM -x usbmuxd 2>/dev/null || true
  for _ in {1..30}; do
    pgrep -x usbmuxd >/dev/null 2>&1 || break
    sleep 0.1
  done

  log "Starting isolated usbmuxd on $USBMUXD_PRIVATE_SOCKET"
  sudo usbmuxd -f -p -S "$USBMUXD_PRIVATE_SOCKET" >/tmp/bunny-usbmuxd.log 2>&1 &
  USBMUXD_PRIVATE_STARTED=1

  for _ in {1..50}; do
    [[ -S "$USBMUXD_PRIVATE_SOCKET" ]] && break
    sleep 0.1
  done
  [[ -S "$USBMUXD_PRIVATE_SOCKET" ]] ||
    die "private usbmuxd socket was not created; see /tmp/bunny-usbmuxd.log"

  # usbmuxd starts privileged in order to access USB, then we only need the
  # local client socket from the invoking user.
  sudo chown "$USER":"$USER" "$USBMUXD_PRIVATE_SOCKET" 2>/dev/null || true
  chmod 0600 "$USBMUXD_PRIVATE_SOCKET"

  export USBMUXD_SOCKET_ADDRESS="UNIX:$USBMUXD_PRIVATE_SOCKET"
  export BUNNY_USBMUX_PRIVATE=1
  log "Bunny usbmuxd isolated from desktop lockdownd probes"
}

wait_for_ramdisk_usb() {
  # Do not run irecovery -q here. Once the ramdisk is active, that probe can
  # block or wait for a standard Apple Recovery endpoint that this ramdisk
  # intentionally does not expose. SSH must not depend on it.
  return 0
}

wait_for_ssh_mux() {
  local socket="$1"
  for _ in {1..50}; do
    [[ -S "$socket" ]] && return 0
    sleep 0.1
  done
  die "private usbmuxd socket did not become ready: $socket"
}

start_usbmuxd
wait_for_ramdisk_usb
wait_for_ssh_mux "$USBMUXD_PRIVATE_SOCKET"

LOCAL_PORT="${BUNNY_SSH_LOCAL_PORT:-2222}"
DEVICE_PORT="${BUNNY_SSH_DEVICE_PORT:-44}"
USER_NAME="${BUNNY_SSH_USER:-root}"
PASSWORD="${BUNNY_SSH_PASSWORD:-alpine}"

pattern="iproxy .*${LOCAL_PORT} .*${DEVICE_PORT}"
if ! pgrep -f "$pattern" >/dev/null 2>&1; then
  log "Starting iproxy $LOCAL_PORT -> $DEVICE_PORT (Dropbear)"
  env USBMUXD_SOCKET_ADDRESS="$USBMUXD_SOCKET_ADDRESS" \
    iproxy "${LOCAL_PORT}:${DEVICE_PORT}" >/tmp/bunny-iproxy.log 2>&1 &
  IPROXY_PID=$!
  echo "$IPROXY_PID" > "$ROOT/.iproxy.pid"

  # iproxy may start before usbmuxd has enumerated the ramdisk. Fail with its
  # real log instead of leaving the user waiting forever.
  READY=0
  for _ in {1..50}; do
    if ! kill -0 "$IPROXY_PID" 2>/dev/null; then
      echo "[x] iproxy exited unexpectedly:" >&2
      cat /tmp/bunny-iproxy.log >&2 || true
      exit 1
    fi
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 0.2
  done
  (( READY )) || {
    echo "[x] iproxy did not open local port $LOCAL_PORT" >&2
    cat /tmp/bunny-iproxy.log >&2 || true
    exit 1
  }
fi
echo "SSH: $USER_NAME@127.0.0.1:$LOCAL_PORT (device port $DEVICE_PORT)"
if command -v sshpass >/dev/null 2>&1; then
  SSHPASS="$PASSWORD" sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$LOCAL_PORT" "$USER_NAME@127.0.0.1"
else
  warn "sshpass not installed; using interactive password entry"
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$LOCAL_PORT" "$USER_NAME@127.0.0.1"
fi
