#!/bin/sh
# Bunny ramdisk rc.boot replacement.
# The stock RestoreRamDisk rc.boot eventually invokes restored_external. For an
# SSH ramdisk we deliberately stop that restore workflow and bring up Dropbear
# directly instead. This also gives us a deterministic place to initialize
# runtime directories and print the project banner to the verbose console.
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
export HOME=/var/root
export USER=root
export LOGNAME=root
umask 0

# The restore ramdisk root should already be mounted by the kernel handoff.
# Remounting read-write is harmless when supported and makes /var/run and
# Dropbear host-key creation deterministic.
if [ -x /sbin/mount ]; then
    /sbin/mount -uw / >/dev/null 2>&1 || true
fi

mkdir -p /var/run /tmp /var/root/.ssh /etc/dropbear 2>/dev/null || true
chmod 700 /var/root/.ssh 2>/dev/null || true
chmod 700 /etc/dropbear 2>/dev/null || true

cat >/dev/console <<'BUNNY'
================================================================
██    ██  █████  ██      ██ ██████  ██ ████████ ██    ██
██    ██ ██   ██ ██      ██ ██   ██ ██    ██     ██  ██
██    ██ ███████ ██      ██ ██   ██ ██    ██      ████
 ██  ██  ██   ██ ██      ██ ██   ██ ██    ██       ██
  ████   ██   ██ ███████ ██ ██████  ██    ██       ██
================================================================
                 VALIDITY IS THE BEST
================================================================
BUNNY

echo "BUNNY: starting Dropbear SSH on device ports 22 and 44" >/dev/console 2>&1

if [ ! -x /usr/local/bin/dropbear ]; then
    echo "BUNNY: ERROR: /usr/local/bin/dropbear is missing" >/dev/console 2>&1
    exit 127
fi

# Port 44 is kept for compatibility with ramdisk clients that probe the
# usbliter8ra1n-style service. Port 22 is the documented ICH service.
# A failure to bind 44 must never prevent the primary 22 listener.
(/usr/local/bin/dropbear -R -E -F -p 44 >/dev/console 2>&1) &
exec /usr/local/bin/dropbear -R -E -F -p 22 >/dev/console 2>&1
