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
      build-essential pkg-config autoconf automake libtool gettext cmake \
      libusb-1.0-0-dev libplist-dev libreadline-dev uuid-dev \
      libssl-dev libpng-dev fuse3 rsync tar sshpass
    ;;
  fedora)
    sudo dnf install -y bash ca-certificates curl git jq unzip xz zip golang \
      python3 python3-pip python3-devel gcc gcc-c++ make pkgconf \
      autoconf automake libtool gettext \
      libusb1-devel libplist-devel readline-devel libuuid-devel \
      openssl-devel libpng-devel fuse3 rsync tar sshpass
    ;;
  arch)
    sudo pacman -Sy --needed --noconfirm bash ca-certificates curl git jq unzip xz zip go gettext \
      python python-pip base-devel pkgconf cmake autoconf automake libtool \
      libusb libplist readline libuuid openssl fuse3 rsync tar sshpass
    ;;
  *)
    die "Unsupported Linux distribution: $ID_LC (supported: Fedora, Debian, Ubuntu, Arch)"
    ;;
esac

mkdir -p "$BUNNY_TOOLS" "$BUNNY_PATCH" "$BUNNY_THIRD_PARTY" "$BUNNY_RESOURCES" "$ROOT/.local"

log "Creating Python virtual environment"
python3 -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/python" -m pip install --upgrade pip wheel
"$ROOT/.venv/bin/python" -m pip install -r "$ROOT/requirements.txt"

if ! command -v ipsw >/dev/null 2>&1; then
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

download() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  curl --fail --show-error --location --retry 8 --retry-all-errors \
    --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
    --output "$out" "$url"
  [[ -s "$out" ]] || die "downloaded file is empty: $url"
}

log "Fetching A12/A13 patchfinders and usbliter8ctl"
download https://raw.githubusercontent.com/Leeksov/usbliter8-iboot-patchfinder/main/iboot_patchfinder.py "$BUNNY_PATCH/iboot_patchfinder.py"
download https://raw.githubusercontent.com/Leeksov/usbliter8-kernel-patchfinder/main/kernel_patchfinder.py "$BUNNY_PATCH/kernel_patchfinder.py"
download https://raw.githubusercontent.com/Leeksov/usbliter8-sptm-patchfinder/main/sptm_patchfinder.py "$BUNNY_PATCH/sptm_patchfinder.py"
download https://raw.githubusercontent.com/Leeksov/usbliter8-txm-patchfinder/main/txm_patchfinder.py "$BUNNY_PATCH/txm_patchfinder.py"
download https://raw.githubusercontent.com/Leeksov/usbliter8ra1n/main/tools/usbliter8ctl "$BUNNY_TOOLS/usbliter8ctl"
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

KDIR="/lib/modules/$(uname -r)/build"
[[ -d "$KDIR" ]] || die "Kernel build directory missing: $KDIR"
bash "$ROOT/scripts/build_apfs_module.sh" "$APFS_SRC" "$APFS_SRC/apfs.ko"

log "Building mkapfs"
APFSPROGS="$BUNNY_THIRD_PARTY/apfsprogs"
[[ -d "$APFSPROGS" ]] || git clone --depth 1 https://github.com/linux-apfs/apfsprogs.git "$APFSPROGS"

APFS_PROGS_STAGE="$(mktemp -d /tmp/bunny-apfsprogs.XXXXXX)"
cleanup_apfsprogs() { rm -rf "$APFS_PROGS_STAGE"; }
trap cleanup_apfsprogs EXIT INT TERM
rsync -a "$APFSPROGS/" "$APFS_PROGS_STAGE/"
APFS_COMMIT="$(git -C "$APFSPROGS" describe --always HEAD | tail -c 9)"

(
  cd "$APFS_PROGS_STAGE/mkapfs"
  printf '#define GIT_COMMIT\t"%s"\n' "$APFS_COMMIT" > version.h
  make -j"$(nproc)"
)

[[ -x "$APFS_PROGS_STAGE/mkapfs/mkapfs" ]] || die "mkapfs build finished without executable"
MKAPFS_VERSION="$("$APFS_PROGS_STAGE/mkapfs/mkapfs" -v)"
[[ "$MKAPFS_VERSION" == "mkapfs $APFS_COMMIT" ]] || die "mkapfs version self-test failed: $MKAPFS_VERSION"
install -m 0755 "$APFS_PROGS_STAGE/mkapfs/mkapfs" "$BUNNY_TOOLS/mkapfs"

download https://raw.githubusercontent.com/Pa7r0n/ICH_A12_plus_Ramdisk/main/resources/sshtarlist.txt "$BUNNY_RESOURCES/sshtarlist.txt"

log "Fetching default A12/A13 IM4M resources"
download https://raw.githubusercontent.com/strawhatdev01/Strawhat-Ramdisk/main/resources/IM4M_0x8020 "$BUNNY_RESOURCES/IM4M_0x8020"
download https://raw.githubusercontent.com/strawhatdev01/Strawhat-Ramdisk/main/resources/IM4M_0x8030 "$BUNNY_RESOURCES/IM4M_0x8030"

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
[[ -x "$ROOT/.local/img4" ]] && echo "[OK] img4"
[[ -x "$ROOT/scripts/kerneldiff.py" ]] && echo "[OK] kerneldiff.py"

echo
echo "Setup complete."
echo "Run ./status.sh, then ./build.sh --version <version>"


log "Building ibootim logo tool"
IBOOTIM_SRC="$BUNNY_THIRD_PARTY/ibootim"
if [[ ! -d "$IBOOTIM_SRC/.git" ]]; then
  rm -rf "$IBOOTIM_SRC"
  git clone --depth 1 https://github.com/realnp/ibootim.git "$IBOOTIM_SRC"
fi
make -C "$IBOOTIM_SRC" CFLAGS="${CFLAGS:-} -DEFTYPE=EINVAL" -j"$(nproc)"
[[ -x "$IBOOTIM_SRC/ibootim" ]] || die "ibootim build finished without executable"
install -m 0755 "$IBOOTIM_SRC/ibootim" "$BUNNY_TOOLS/ibootim"
"$BUNNY_TOOLS/ibootim" --help >/dev/null 2>&1 || true

echo "==> Building Linux IMG4 patching tool"
IMG4LIB="$ROOT/third_party/img4lib"
if [[ ! -d "$IMG4LIB/.git" ]]; then
  rm -rf "$IMG4LIB"
  git clone --recursive https://github.com/xerub/img4lib.git "$IMG4LIB"
else
  git -C "$IMG4LIB" submodule update --init --recursive
fi
make -C "$IMG4LIB/lzfse" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
make -C "$IMG4LIB" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
cp "$IMG4LIB/img4" "$ROOT/.local/img4"
chmod +x "$ROOT/.local/img4"
echo "IMG4 tool ready: $ROOT/.local/img4"
"$ROOT/.local/img4" -h >/dev/null
