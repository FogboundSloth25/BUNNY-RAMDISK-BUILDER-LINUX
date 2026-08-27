#!/bin/bash
# BUNNY RAMDISK BUILDER — dependency setup for any Mac.
# Installs: Rosetta (Apple Silicon), Homebrew (if missing), ipsw CLI, pyimg4.
set -uo pipefail

log() { echo "==> $*"; }

log "Checking dependencies..."

# 1) Rosetta (Apple Silicon only — needed for bundled x86_64 tools)
if [ "$(uname -m)" = "arm64" ]; then
    if /usr/bin/pgrep -q oahd 2>/dev/null || /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        log "Rosetta already installed"
    else
        log "Installing Rosetta (required for bundled tools)..."
        softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 \
            || log "warning: Rosetta install failed (manual: softwareupdate --install-rosetta)"
    fi
fi

# 2) Homebrew
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null \
        || { echo "error: Homebrew install failed" >&2; exit 1; }
    if [ "$(uname -m)" = "arm64" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    log "Homebrew present"
fi

# 3) ipsw CLI (blacktop)
if command -v ipsw >/dev/null 2>&1; then
    log "ipsw present ($(ipsw version 2>/dev/null | head -1))"
else
    log "Installing ipsw (blacktop/tap)..."
    brew install blacktop/tap/ipsw 2>&1 | tail -3 || { echo "error: ipsw install failed" >&2; exit 1; }
fi

# 4) pyimg4 for homebrew python3
PYBIN=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] && PYBIN="$c" && break
done
if [ -z "$PYBIN" ]; then
    echo "error: python3 not found" >&2
    exit 1
fi
if "$PYBIN" -c "import pyimg4" 2>/dev/null; then
    log "pyimg4 present ($PYBIN)"
else
    log "Installing pyimg4 for $PYBIN ..."
    "$PYBIN" -m pip install --user pyimg4 2>&1 | tail -2 || {
        "$PYBIN" -m pip install pyimg4 2>&1 | tail -2 || { echo "error: pyimg4 install failed" >&2; exit 1; }
    }
fi

log "Verification:"
command -v ipsw && echo "  ipsw OK"
"$PYBIN" -c "import pyimg4; print('  pyimg4 OK ('+pyimg4.__version__+')')"
log "ALL DEPENDENCIES READY ✔"