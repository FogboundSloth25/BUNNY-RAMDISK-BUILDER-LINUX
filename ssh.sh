#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"

need_cmd iproxy
need_cmd ssh

start_usbmuxd() {
  [[ "${BUNNY_USBMUX_AUTOSTART:-1}" == 1 ]] || return 0
  if command -v usbmuxd >/dev/null 2>&1; then
    if ! pgrep -x usbmuxd >/dev/null 2>&1; then
      log "Starting usbmuxd"
      if [[ -x /usr/sbin/usbmuxd ]]; then
        sudo /usr/sbin/usbmuxd >/tmp/bunny-usbmuxd.log 2>&1 &
      else
        sudo usbmuxd >/tmp/bunny-usbmuxd.log 2>&1 &
      fi
      for _ in {1..20}; do
        pgrep -x usbmuxd >/dev/null 2>&1 && break
        sleep 0.1
      done
    fi
  fi
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
DEVICE_PORT="${BUNNY_SSH_DEVICE_PORT:-22}"
USER_NAME="${BUNNY_SSH_USER:-root}"
PASSWORD="${BUNNY_SSH_PASSWORD:-alpine}"

pattern="iproxy .*${LOCAL_PORT} .*${DEVICE_PORT}"
if ! pgrep -f "$pattern" >/dev/null 2>&1; then
  log "Starting iproxy $LOCAL_PORT -> $DEVICE_PORT"
  iproxy "$LOCAL_PORT" "$DEVICE_PORT" >/tmp/bunny-iproxy.log 2>&1 &
  echo $! > "$ROOT/.iproxy.pid"
  sleep 1
fi

echo "SSH: $USER_NAME@127.0.0.1:$LOCAL_PORT"
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
