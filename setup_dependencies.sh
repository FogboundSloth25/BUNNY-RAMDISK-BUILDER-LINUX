#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"

[[ "$(uname -s)" == "Linux" ]] || die "This fork targets Linux."

. /etc/os-release
ID_LC="${ID,,}"
case "$ID_LC" in
  linuxmint|pop|elementary|neon) ID_LC=ubuntu ;;
  raspbian) ID_LC=debian ;;
esac

echo "Detected: $ID_LC"

case "$ID_LC" in
  debian|ubuntu)
    sudo apt-get update
    sudo apt-get install -y bash ca-certificates curl git jq unzip xz-utils zip golang \
      python3 python3-venv python3-pip python3-dev \
      build-essential pkg-config autoconf automake libtool gettext \
      libusb-1.0-0-dev libplist-dev libreadline-dev uuid-dev \
      libssl-dev fuse3 rsync tar sshpass
    ;;
  fedora)
    sudo dnf install -y bash ca-certificates curl git jq unzip xz zip golang \
      python3 python3-pip python3-devel gcc gcc-c++ make pkgconf \
      autoconf automake libtool gettext \
      libusb1-devel libplist-devel readline-devel libuuid-devel \
      openssl-devel fuse3 rsync tar sshpass
    ;;
  arch)
    sudo pacman -Sy --needed --noconfirm bash ca-certificates curl git jq unzip xz zip go gettext \
      python python-pip base-devel pkgconf autoconf automake libtool \
      libusb libplist readline libuuid openssl fuse3 rsync tar sshpass
    ;;
  *)
    die "Unsupported Linux distribution: $ID_LC (supported: Fedora, Debian, Ubuntu, Arch)"
    ;;
esac

mkdir -p "$BUNNY_TOOLS" "$BUNNY_PATCH" "$BUNNY_THIRD_PARTY" "$BUNNY_RESOURCES"

log "Creating Python virtual environment"
python3 -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/python" -m pip install --upgrade pip wheel
"$ROOT/.venv/bin/python" -m pip install -r "$ROOT/requirements.txt"

if ! command -v ipsw >/dev/null 2>&1; then
  command -v go >/dev/null 2>&1 || die "Go was not installed correctly"
  GOTOOLCHAIN=auto go install github.com/blacktop/ipsw@master
  [[ -x "$HOME/go/bin/ipsw" ]] || die "ipsw build succeeded but executable was not found"
  ln -sf "$HOME/go/bin/ipsw" "$BUNNY_TOOLS/ipsw"
fi

if ! command -v irecovery >/dev/null 2>&1; then
  if [[ "$ID_LC" == debian || "$ID_LC" == ubuntu ]]; then
    sudo apt-get install -y libirecovery-utils libirecovery-dev libimobiledevice-glue-dev 2>/dev/null || true
  elif [[ "$ID_LC" == fedora ]]; then
    sudo dnf install -y libirecovery libirecovery-devel libimobiledevice-glue-devel 2>/dev/null || true
  fi
fi

if ! command -v irecovery >/dev/null 2>&1; then
  SRC="$BUNNY_THIRD_PARTY/libirecovery"
  rm -rf "$SRC"
  git clone --depth 1 https://github.com/libimobiledevice/libirecovery.git "$SRC"
  (
    cd "$SRC"
    ./autogen.sh --prefix="$ROOT/.local"
    make -j"$(nproc)"
    make install
  )
fi

if ! command -v iproxy >/dev/null 2>&1; then
  case "$ID_LC" in
    debian|ubuntu) sudo apt-get install -y libusbmuxd-tools 2>/dev/null || true ;;
    fedora) sudo dnf install -y libusbmuxd-utils 2>/dev/null || true ;;
    arch) sudo pacman -S --needed --noconfirm libusbmuxd 2>/dev/null || true ;;
  esac
fi

log "Fetching A12/A13 patchfinders and usbliter8ctl"
curl -fsSL https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/iboot_patchfinder.py -o "$BUNNY_PATCH/iboot_patchfinder.py"
curl -fsSL https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/kernel_patchfinder.py -o "$BUNNY_PATCH/kernel_patchfinder.py"
curl -fsSL https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/sptm_patchfinder.py -o "$BUNNY_PATCH/sptm_patchfinder.py"
curl -fsSL https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/txm_patchfinder.py -o "$BUNNY_PATCH/txm_patchfinder.py"
curl -fsSL https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/usbliter8ctl -o "$BUNNY_TOOLS/usbliter8ctl"
chmod 755 "$BUNNY_PATCH"/*.py "$BUNNY_TOOLS/usbliter8ctl"

if [[ ! -x "$BUNNY_TOOLS/trustcache" ]]; then
  SRC="$BUNNY_THIRD_PARTY/trustcache"
  rm -rf "$SRC"
  git clone --depth 1 https://github.com/CRKatri/trustcache.git "$SRC"
  (
    cd "$SRC"
    make -j"$(nproc)"
    install -m 0755 trustcache "$BUNNY_TOOLS/trustcache"
  )
fi

log "Building experimental Linux APFS driver"
APFS_SRC="$BUNNY_THIRD_PARTY/linux-apfs-rw"
[[ -d "$APFS_SRC" ]] || git clone --depth 1 https://github.com/linux-apfs/linux-apfs-rw.git "$APFS_SRC"
if [[ ! -f "$APFS_SRC/apfs.ko" ]]; then
  make -C "$APFS_SRC"
fi

log "Building mkapfs"
APFSPROGS="$BUNNY_THIRD_PARTY/apfsprogs"
[[ -d "$APFSPROGS" ]] || git clone --depth 1 https://github.com/linux-apfs/apfsprogs.git "$APFSPROGS"
if [[ ! -x "$BUNNY_TOOLS/mkapfs" ]]; then
  make -C "$APFSPROGS/mkapfs" -j"$(nproc)"
  install -m 0755 "$APFSPROGS/mkapfs/mkapfs" "$BUNNY_TOOLS/mkapfs"
fi

log "Fetching default A12/A13 IM4M resources"
curl -fsSL https://raw.githubusercontent.com/strawhatdev01/Strawhat-Ramdisk/main/resources/IM4M_0x8020 -o "$BUNNY_RESOURCES/IM4M_0x8020"
curl -fsSL https://raw.githubusercontent.com/strawhatdev01/Strawhat-Ramdisk/main/resources/IM4M_0x8030 -o "$BUNNY_RESOURCES/IM4M_0x8030"

if [[ -d "$BUNNY_THIRD_PARTY/libirecovery/udev" ]]; then
  for rule in "$BUNNY_THIRD_PARTY/libirecovery"/udev/*.rules; do
    [[ -f "$rule" ]] || continue
    sudo install -m 0644 "$rule" "/etc/udev/rules.d/$(basename "$rule")"
  done
  sudo udevadm control --reload-rules
  sudo udevadm trigger
fi

echo
for tool in python3 ipsw irecovery; do
  command -v "$tool" >/dev/null 2>&1 && echo "[OK] $tool" || echo "[MISS] $tool"
done
command -v iproxy >/dev/null 2>&1 && echo "[OK] iproxy" || echo "[WARN] iproxy unavailable"
[[ -x "$BUNNY_TOOLS/usbliter8ctl" ]] && echo "[OK] usbliter8ctl"
[[ -x "$BUNNY_TOOLS/trustcache" ]] && echo "[OK] trustcache"
[[ -x "$BUNNY_TOOLS/mkapfs" ]] && echo "[OK] mkapfs"
[[ -f "$APFS_SRC/apfs.ko" ]] && echo "[OK] apfs.ko"

echo
echo "Setup complete."
echo "Run ./status.sh, then ./build.sh --version <version>"
