#!/bin/sh
# Bunny A12/A13 SSH ramdisk entrypoint.
# iBoot invokes this file directly as restored_external; there is no launchd.
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
export HOME=/var/root
export USER=root
export LOGNAME=root

mkdir -p /var/run /tmp /var/root/.ssh 2>/dev/null || true
chmod 700 /var/root/.ssh 2>/dev/null || true

# Dropbear -R generates host keys when they are absent. Keep the daemon in the
# foreground so restored_external remains the long-lived PID 1 child instead
# of returning to iBoot/restore code after spawning a fragile background job.
# -E sends diagnostics to the kernel console, which is useful on DCSD verbose.
exec /usr/local/bin/dropbear -R -E -F -p 44
