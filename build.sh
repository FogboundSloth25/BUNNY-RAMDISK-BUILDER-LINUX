#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"
source "$ROOT/scripts/ramdisk_linux.sh"

usage() {
cat <<'EOF'
usage:
  ./build.sh --version VERSION [--product PRODUCT] [--model BOARD]
  ./build.sh --build BUILD    [--product PRODUCT] [--model BOARD]
  ./build.sh --url URL         --product PRODUCT --model BOARD
  ./build.sh --ipsw FILE       --model BOARD
options:
  --kernel stock|patched       default: patched
  --use-ibss                   patch/stage iBSS
  --no-ssh                     keep stock RestoreRamDisk
  --no-fw                      do not stage coprocessor firmware
  --dry-run                    validate manifest only
EOF
}

SELECTION=""
DIRECT_URL=""
LOCAL_IPSW=""
PRODUCT=""
MODEL=""
IM4M=""
KERNEL_MODE="patched"
USE_IBSS=0
WITH_FW=1
INJECT_SSH=1
DRY_RUN=0

while (($#)); do
case "$1" in
  --version|--build) (($# >= 2)) || die "$1 needs a value"; SELECTION="$2"; shift 2 ;;
  --url) (($# >= 2)) || die "--url needs a value"; DIRECT_URL="$2"; shift 2 ;;
  --ipsw) (($# >= 2)) || die "--ipsw needs a path"; LOCAL_IPSW="$2"; shift 2 ;;
  --product) (($# >= 2)) || die "--product needs a value"; PRODUCT="$2"; shift 2 ;;
  --model|--board) (($# >= 2)) || die "--model needs a value"; MODEL="$2"; shift 2 ;;
  --im4m) (($# >= 2)) || die "--im4m needs a value"; IM4M="$2"; shift 2 ;;
  --kernel) (($# >= 2)) || die "--kernel needs a value"; KERNEL_MODE="$2"; shift 2 ;;
  --use-ibss) USE_IBSS=1; shift ;;
  --no-ssh) INJECT_SSH=0; shift ;;
  --no-fw) WITH_FW=0; shift ;;
  --dry-run) DRY_RUN=1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "unknown option: $1" ;;
esac
done

[[ "$KERNEL_MODE" == stock || "$KERNEL_MODE" == patched ]] || die "invalid --kernel"
need_cmd curl
need_cmd jq
need_cmd python3
need_cmd ipsw

PY="$(python_bin)"

if [[ -z "$PRODUCT" || -z "$MODEL" ]]; then
  DEVICE_INFO="$(irecovery -q 2>/dev/null || true)"
  field() { awk -F': ' -v key="$1" '$1 == key {print $2; exit}' <<<"$DEVICE_INFO"; }
  [[ -n "$PRODUCT" ]] || PRODUCT="$(field PRODUCT || true)"
  [[ -n "$MODEL" ]] || MODEL="$(field MODEL || true)"
  CPID="$(field CPID || true)"
  ECID="$(field ECID || true)"
else
  CPID=""
  ECID=""
fi

[[ -n "$PRODUCT" ]] || die "PRODUCT unknown; connect the device or pass --product"
[[ -n "$MODEL" ]] || die "MODEL unknown; connect the device or pass --model"

VERSION="unknown"
BUILD=""
IPSW_URL="$DIRECT_URL"
IPSW_SHA256=""
API_JSON=""
LOCAL_REMOTE_IPSW=""

extract_manifest_from_ipsw() {
  local ipsw="$1" out="$2"
  "$PY" - "$ipsw" "$out" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw, out = map(Path, sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    try:
        data = z.read("BuildManifest.plist")
    except KeyError:
        raise SystemExit("BuildManifest.plist not found in IPSW")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(data)
PY
}

resolve_doh_ipv4() {
  local host="$1" answer
  answer="$(
    curl --fail --silent --show-error --connect-timeout 10 --max-time 20 \
      --resolve "cloudflare-dns.com:443:1.1.1.1" \
      -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=$host&type=A" |
      jq -r '.Answer[]? | select(.type == 1) | .data' |
      head -n1
  )"
  [[ -n "$answer" && "$answer" != "null" ]] || return 1
  printf '%s\n' "$answer"
}

url_host() {
  "$PY" - "$1" <<'PY'
from urllib.parse import urlparse
import sys
host = urlparse(sys.argv[1]).hostname
if not host:
    raise SystemExit("invalid URL")
print(host)
PY
}

download_remote_ipsw() {
  local url="$1" out="$2" expected="$3"
  local host ip partial actual

  host="$(url_host "$url")"
  [[ -n "$host" ]] || die "could not determine IPSW host"

  ip="$(resolve_doh_ipv4 "$host" || true)"
  [[ -n "$ip" ]] || die "DNS-over-HTTPS could not resolve $host"

  log "Apple CDN: $host -> $ip"
  mkdir -p "$(dirname "$out")"
  partial="$out.partial"

  if [[ ! -s "$out" ]]; then
    log "Downloading IPSW (resume supported)"
    curl --fail --show-error --location --retry 8 --retry-all-errors \
      --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
      --continue-at - --resolve "$host:443:$ip" \
      --output "$partial" "$url"
    mv -f "$partial" "$out"
  fi

  [[ -s "$out" ]] || die "downloaded IPSW is empty"

  if [[ -n "$expected" && "$expected" != "null" ]]; then
    local hash_marker="${out}.sha256.ok"
    if [[ -s "$hash_marker" ]] && grep -Fqx "$expected" "$hash_marker"; then
      log "SHA-256 already verified; skipping re-hash"
    else
      log "Verifying IPSW SHA-256"
      actual="$(sha256sum "$out" | awk '{print $1}')"
      [[ "${actual,,}" == "${expected,,}" ]] ||
        die "IPSW SHA-256 mismatch: expected $expected, got $actual"
      printf '%s\n' "$expected" > "$hash_marker"
      echo "  SHA256: $actual"
    fi
  fi

  if command -v zipinfo >/dev/null 2>&1; then
    zipinfo -t "$out" >/dev/null || die "downloaded IPSW failed ZIP validation"
  fi
}


if [[ -n "$LOCAL_IPSW" ]]; then
  [[ -f "$LOCAL_IPSW" ]] || die "IPSW not found: $LOCAL_IPSW"
  CACHE_KEY="$(basename "$LOCAL_IPSW" .ipsw)"
  MANIFEST="$BUNNY_CACHE/$CACHE_KEY/BuildManifest.plist"
  mkdir -p "$(dirname "$MANIFEST")"
  if [[ ! -s "$MANIFEST" ]]; then
    "$PY" - "$LOCAL_IPSW" "$MANIFEST" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw,out=map(Path,sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    data=z.read("BuildManifest.plist")
out.write_bytes(data)
PY
  fi
else
  API_JSON="$(curl -fsSL "https://api.ipsw.me/v4/device/$PRODUCT?type=ipsw")"
  if [[ -z "$IPSW_URL" ]]; then
    [[ -n "$SELECTION" ]] || die "use --version, --build, --url or --ipsw"
    MATCH="$("$PY" - "$SELECTION" "$API_JSON" <<'PY'
import json,sys
sel,raw=sys.argv[1],sys.argv[2]
for item in json.loads(raw).get("firmwares",[]):
    if item.get("version")==sel or item.get("buildid")==sel:
        print(json.dumps(item))
        raise SystemExit
raise SystemExit("firmware not found: "+sel)
PY
)"
    VERSION="$(jq -r '.version' <<<"$MATCH")"
    BUILD="$(jq -r '.buildid' <<<"$MATCH")"
    IPSW_URL="$(jq -r '.url' <<<"$MATCH")"
    IPSW_SHA256="$(jq -r '.sha256sum // .sha256 // empty' <<<"$MATCH")"
  else
    MATCH="$(jq -c --arg url "$IPSW_URL" '.firmwares[] | select(.url == $url) | .' <<<"$API_JSON" | head -n1 || true)"
    VERSION="$(jq -r '.version // "unknown"' <<<"$MATCH")"
    BUILD="$(jq -r '.buildid // "custom"' <<<"$MATCH")"
    IPSW_SHA256="$(jq -r '.sha256sum // .sha256 // empty' <<<"$MATCH")"
  fi

  [[ -n "$BUILD" ]] || BUILD="custom"
  CACHE_KEY="$PRODUCT-$BUILD"
  MANIFEST="$BUNNY_CACHE/$CACHE_KEY/BuildManifest.plist"
  REMOTE_IPSW="$BUNNY_CACHE/$CACHE_KEY/$(basename "${IPSW_URL%%\?*}")"

  download_remote_ipsw "$IPSW_URL" "$REMOTE_IPSW" "$IPSW_SHA256"

  if [[ ! -s "$MANIFEST" ]]; then
    log "Extracting BuildManifest.plist from verified local IPSW"
    extract_manifest_from_ipsw "$REMOTE_IPSW" "$MANIFEST"
  fi

  LOCAL_REMOTE_IPSW="$REMOTE_IPSW"
fi

MODEL_MANIFEST="${MODEL^^}"

IDENTITY="$("$PY" - "$MANIFEST" "$MODEL_MANIFEST" <<'PY'
import json,plistlib,sys
from pathlib import Path
m=plistlib.loads(Path(sys.argv[1]).read_bytes())
board=sys.argv[2].upper()
ids=[x for x in m.get("BuildIdentities",[]) if str(x.get("Info",{}).get("DeviceClass","")).upper()==board]
if not ids:
    raise SystemExit("no BuildIdentity for board "+board)
x=ids[0]
out={"build":x.get("Info",{}).get("BuildNumber","")}
for name in ["iBEC","iBSS","KernelCache","DeviceTree","RestoreRamDisk","RestoreTrustCache","AOP","ANE","AVE","ISP","GFX","SIO","SPTM","TXM","RestoreSEP"]:
    item=x.get("Manifest",{}).get(name,{})
    path=item.get("Info",{}).get("Path")
    if path: out[name]=path
print(json.dumps(out))
PY
)"

BUILD="$(jq -r '.build // empty' <<<"$IDENTITY")"
[[ -n "$BUILD" ]] || die "BuildManifest has no build number"
[[ -n "$VERSION" && "$VERSION" != unknown ]] || VERSION="$BUILD"
CACHE="$BUNNY_CACHE/$CACHE_KEY"
mkdir -p "$CACHE"

path_for() { jq -r --arg key "$1" '.[$key] // empty' <<<"$IDENTITY"; }

fetch_member() {
  local key="$1" p dst
  p="$(path_for "$key")"
  [[ -n "$p" ]] || return 0
  dst="$CACHE/$(basename "$p")"

  if [[ ! -s "$dst" ]]; then
    if [[ -n "$LOCAL_IPSW" ]]; then
      "$PY" - "$LOCAL_IPSW" "$p" "$dst" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw, name, out = map(Path, sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    out.write_bytes(z.read(str(name)))
PY
    elif [[ -n "$LOCAL_REMOTE_IPSW" ]]; then
      "$PY" - "$LOCAL_REMOTE_IPSW" "$p" "$dst" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw, name, out = map(Path, sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    try:
        data = z.read(str(name))
    except KeyError:
        raise SystemExit(f"missing IPSW member: {name}")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(data)
PY
    else
      die "no local IPSW available for $key"
    fi
  fi

  [[ -s "$dst" ]] || die "component $key is missing/empty: $dst"
}

for key in iBEC KernelCache DeviceTree RestoreRamDisk RestoreTrustCache; do
  fetch_member "$key"
done
(( USE_IBSS )) && fetch_member iBSS
if (( WITH_FW )); then
  for key in AOP ANE AVE ISP GFX SIO; do fetch_member "$key" || true; done
fi
fetch_member SPTM || true
fetch_member TXM || true

if [[ -z "$IM4M" ]]; then
  case "${CPID,,}" in
    0x8020|8020) IM4M="$BUNNY_RESOURCES/IM4M_0x8020" ;;
    0x8030|8030) IM4M="$BUNNY_RESOURCES/IM4M_0x8030" ;;
    *) IM4M="$BUNNY_RESOURCES/IM4M_${CPID:-unknown}" ;;
  esac
fi
[[ -f "$IM4M" ]] || die "missing IM4M: $IM4M"

WORK="$BUNNY_WORK/$CACHE_KEY"
BOOT="$BUNNY_BOOTCHAIN/$MODEL-$VERSION-$BUILD-ramdisk"
rm -rf "$WORK" "$BOOT"
mkdir -p "$WORK" "$BOOT"

for key in iBEC KernelCache DeviceTree RestoreRamDisk RestoreTrustCache; do
  cp "$CACHE/$(basename "$(path_for "$key")")" "$WORK/$key.im4p"
done
(( USE_IBSS )) && cp "$CACHE/$(basename "$(path_for iBSS)")" "$WORK/iBSS.im4p"

for key in AOP ANE AVE ISP GFX SIO SPTM TXM; do
  p="$(path_for "$key")"
  [[ -n "$p" ]] && cp "$CACHE/$(basename "$p")" "$WORK/$key.im4p"
done

extract_raw() {
  local in="$1" out="$2"
  "$PY" - "$in" "$out" <<'PY'
import sys
from pathlib import Path
from pyimg4 import IM4P
src,out=map(Path,sys.argv[1:])
out.write_bytes(IM4P(src.read_bytes()).payload.data)
PY
}

extract_raw "$WORK/iBEC.im4p" "$WORK/iBEC.raw"
extract_raw "$WORK/KernelCache.im4p" "$WORK/kernelcache.raw"
(( USE_IBSS )) && extract_raw "$WORK/iBSS.im4p" "$WORK/iBSS.raw"
[[ -f "$WORK/SPTM.im4p" ]] && extract_raw "$WORK/SPTM.im4p" "$WORK/SPTM.raw"
[[ -f "$WORK/TXM.im4p" ]] && extract_raw "$WORK/TXM.im4p" "$WORK/TXM.raw"

if (( DRY_RUN )); then
  echo "=== DRY RUN SUCCESS ==="
  jq . <<<"$IDENTITY"
  echo "cache: $CACHE"
  exit 0
fi

log "Patching iBEC"
IBOOT_LOG="$WORK/ibec-patch.log"
"$PY" "$BUNNY_PATCH/iboot_patchfinder.py" "$WORK/iBEC.raw" "$WORK/iBEC.patched.raw" --mode ibec | tee "$IBOOT_LOG"
if ! grep -Eq '[1-9][0-9]* patches?, [1-9][0-9]* functions found|[1-9][0-9]* patches' "$IBOOT_LOG"; then
  echo "[x] iBEC patchfinder found no applicable patches for $PRODUCT $VERSION $BUILD" >&2
  echo "    This firmware is not confirmed by the selected patchfinder; refusing to continue with an unchanged iBEC." >&2
  exit 1
fi
[[ -s "$WORK/iBEC.patched.raw" ]] || die "iBEC patchfinder produced no output"

if (( USE_IBSS )); then
  log "Patching iBSS"
  "$PY" "$BUNNY_PATCH/iboot_patchfinder.py" "$WORK/iBSS.raw" "$WORK/iBSS.patched.raw" --mode ibss
  cp "$WORK/iBSS.patched.raw" "$BOOT/iBSS.patched.raw"
fi

if [[ "$KERNEL_MODE" == patched ]]; then
  log "Patching kernel"
  KERNEL_LOG="$WORK/kernel-patch.log"
  "$PY" "$BUNNY_PATCH/kernel_patchfinder.py" "$WORK/kernelcache.raw" --apply "$WORK/kernelcache.patched.raw" | tee "$KERNEL_LOG"
  if ! grep -Eq "FOUND:[[:space:]]*[1-9][0-9]* targets|[1-9][0-9]* targets" "$KERNEL_LOG"; then
    echo "[x] kernel patchfinder found no applicable targets for $PRODUCT $VERSION $BUILD" >&2
    exit 1
  fi
else
  cp "$WORK/kernelcache.raw" "$WORK/kernelcache.patched.raw"
fi

"$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/iBEC.im4p" --raw "$WORK/iBEC.patched.raw" --output "$BOOT/iBEC.patched.img4" --im4m "$IM4M"
"$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/KernelCache.im4p" --raw "$WORK/kernelcache.patched.raw" --output "$BOOT/kernelcache.img4.patched" --im4m "$IM4M" --lzfse

"$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/DeviceTree.im4p" --output "$BOOT/devicetree.img4" --im4m "$IM4M"
"$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/RestoreTrustCache.im4p" --output "$BOOT/trustcache.img4" --im4m "$IM4M"

if [[ -f "$WORK/SPTM.im4p" ]]; then
  "$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/SPTM.im4p" --output "$BOOT/sptm.img4" --im4m "$IM4M"
fi
if [[ -f "$WORK/TXM.im4p" ]]; then
  "$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/TXM.im4p" --output "$BOOT/txm.img4" --im4m "$IM4M"
fi

if (( INJECT_SSH )); then
  mkdir -p "$BUNNY_RESOURCES"
  SSH_TAR="$BUNNY_RESOURCES/ssh.tar.gz"
  if [[ ! -s "$SSH_TAR" ]]; then
    curl -fsSL https://raw.githubusercontent.com/Pa7r0n/ICH_A12_plus_Ramdisk/main/resources/ssh.tar.gz -o "$SSH_TAR"
  fi
  log "Injecting SSH into a copied ramdisk"
  # RestoreRamDisk.im4p contains the raw DMG payload.
  extract_raw "$WORK/RestoreRamDisk.im4p" "$WORK/ramdisk-stock.dmg"
  inject_ssh_ramdisk "$WORK/ramdisk-stock.dmg" "$SSH_TAR" "$WORK/ramdisk-injected.dmg"
  "$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/RestoreRamDisk.im4p" --raw "$WORK/ramdisk-injected.dmg" --output "$BOOT/ramdisk.img4" --im4m "$IM4M" --fourcc rdsk
else
  "$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/RestoreRamDisk.im4p" --output "$BOOT/ramdisk.img4" --im4m "$IM4M"
fi

if (( WITH_FW )); then
  for key in AOP ANE AVE ISP GFX SIO; do
    [[ -f "$WORK/$key.im4p" ]] || continue
    "$PY" "$ROOT/scripts/img4_package.py" --im4p "$WORK/$key.im4p" --output "$BOOT/$key.img4" --im4m "$IM4M"
  done
fi

{
  echo "version=$VERSION"
  echo "build=$BUILD"
  echo "product=$PRODUCT"
  echo "model=$MODEL"
  echo "cpid=$CPID"
  echo "ecid=$ECID"
  echo "kernel=$KERNEL_MODE"
  echo "use_ibss=$USE_IBSS"
  echo "with_fw=$WITH_FW"
  echo "ssh_injected=$INJECT_SSH"
  echo "linux_apfs_backend=linux-apfs-rw"
} > "$BOOT/chain.info"

printf '%s\n' "$(basename "$BOOT")" > "$BUNNY_LAST"
rm -rf "$WORK"
echo
echo "=== BUILD COMPLETE ==="
echo "$BOOT"
