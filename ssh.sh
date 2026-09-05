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

wait_usb_recovery() {
  for _ in {1..50}; do
    if irecovery -q 2>/dev/null | grep -q "MODE: Recovery"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_usbmuxd
wait_usb_recovery || true

LOCAL_PORT="${BUNNY_SSH_LOCAL_PORT:-2222}"
DEVICE_PORT="${BUNNY_SSH_DEVICE_PORT:-44}"
USER_NAME="${BUNNY_SSH_USER:-root}"
PASSWORD="${BUNNY_SSH_PASSWORD:-alpine}"

pattern="iproxy .*${LOCAL_PORT} .*${DEVICE_PORT}"
if ! pgrep -f "$pattern" >/dev/null 2>&1; then
  log "Starting iproxy $LOCAL_PORT -> $DEVICE_PORT (Dropbear)"
  env USBMUXD_SOCKET_ADDRESS="$USBMUXD_SOCKET_ADDRESS" iproxy "$LOCAL_PORT" "$DEVICE_PORT" >/tmp/bunny-iproxy.log 2>&1 &
  echo $! > "$ROOT/.iproxy.pid"
  sleep 1
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
