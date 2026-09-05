#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"
source "$ROOT/scripts/ramdisk_linux.sh"
IMG4="$ROOT/.local/img4"

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
  --with-fw                    stage coprocessor firmware (default)
  --no-fw                      do not stage coprocessor firmware
  --no-sep                     do not stage RestoreSEP
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
WITH_SEP=-1
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
  --with-fw) WITH_FW=1; shift ;;
  --no-ssh) INJECT_SSH=0; shift ;;
  --no-fw) WITH_FW=0; shift ;;
  --no-sep) WITH_SEP=0; shift ;;
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
[[ -x "$IMG4" ]] || die "missing Linux img4 tool; run ./setup_dependencies.sh"

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
for name in ["iBEC","iBSS","KernelCache","DeviceTree","RestoreRamDisk","RestoreTrustCache","AOP","ANE","AVE","ISP","GFX","SIO","SPTM","TXM"]:
    item=x.get("Manifest",{}).get(name,{})
    path=item.get("Info",{}).get("Path")
    if path: out[name]=path

# RestoreSEP naming varies between restore generations. Prefer exact names,
# then fall back to any Manifest entry whose key/path clearly identifies SEP.
manifest = x.get("Manifest", {})
aliases = ["RestoreSEP","SEP","SepFirmware","SEPFirmware","RestoreSepFirmware","rsepfirmware"]
candidates = []
for key, item in manifest.items():
    path = str(item.get("Info",{}).get("Path",""))
    kl = str(key).lower()
    pl = path.lower()
    if not path or not path.lower().endswith(".im4p"):
        continue
    score = 0
    if key in aliases:
        score += 100
    if "sep" in kl:
        score += 50
    if "sep" in pl:
        score += 40
    if score:
        candidates.append((score, key, path))
if candidates:
    candidates.sort(reverse=True)
    out["RestoreSEP"] = candidates[0][2]
    out["RestoreSEPKey"] = candidates[0][1]
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

  if [[ "$key" == "iBSS" || "$key" == "iBEC" ]]; then
    # Always extract these two boot stages from the verified local IPSW. They
    # must never be substituted by another cached file with a coincidental
    # basename/content collision.
    if [[ -n "$LOCAL_REMOTE_IPSW" ]]; then
      "$PY" - "$LOCAL_REMOTE_IPSW" "$p" "$dst" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw, requested, out = map(Path, sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    names = z.namelist()
    exact = str(requested)
    if exact not in names:
        raise SystemExit(f"missing IPSW member: {exact}")
    info = z.getinfo(exact)
    if info.file_size <= 0:
        raise SystemExit(f"empty IPSW member: {exact}")
    out.write_bytes(z.read(exact))
    print(f"{exact}: {info.file_size} bytes, crc={info.CRC:08x}")
PY
    elif [[ -n "$LOCAL_IPSW" ]]; then
      "$PY" - "$LOCAL_IPSW" "$p" "$dst" <<'PY'
import sys, zipfile
from pathlib import Path
ipsw, requested, out = map(Path, sys.argv[1:])
with zipfile.ZipFile(ipsw) as z:
    exact = str(requested)
    try:
        info = z.getinfo(exact)
    except KeyError:
        raise SystemExit(f"missing IPSW member: {exact}")
    out.write_bytes(z.read(exact))
    print(f"{exact}: {info.file_size} bytes, crc={info.CRC:08x}")
PY
    else
      die "no verified local IPSW available for $key"
    fi
    [[ -s "$dst" ]] || die "$key extraction produced an empty file"
    return 0
  fi

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
if (( USE_IBSS )); then
  IBSS_PATH="$(path_for iBSS)"
  IBEC_PATH="$(path_for iBEC)"
  [[ -n "$IBSS_PATH" && -n "$IBEC_PATH" ]] || die "BuildManifest is missing iBSS/iBEC paths"
  echo "iBSS path: $IBSS_PATH"
  echo "iBEC path: $IBEC_PATH"
  [[ "$IBSS_PATH" != "$IBEC_PATH" ]] || die "BuildManifest selected the same path for iBSS and iBEC"
  [[ "$(basename "$IBSS_PATH")" != "$(basename "$IBEC_PATH")" ]] || die "iBSS/iBEC archive member names collide"
  fetch_member iBSS
fi
if (( WITH_FW )); then
  for key in AOP ANE AVE ISP GFX SIO; do fetch_member "$key" || true; done
fi
fetch_member SPTM || true
fetch_member TXM || true
if (( WITH_SEP < 0 )); then
  if [[ -n "$(path_for RestoreSEP)" ]]; then
    WITH_SEP=1
    echo "RestoreSEP: detected ($(path_for RestoreSEP))"
  else
    WITH_SEP=0
    echo "RestoreSEP: not present in selected BuildManifest; skipping"
  fi
fi
if (( WITH_SEP )); then
  SEP_PATH="$(path_for RestoreSEP)"
  [[ -n "$SEP_PATH" ]] || die "internal error: RestoreSEP enabled without a manifest path"
  fetch_member RestoreSEP
fi

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

extract_raw() {
  local in="$1" out="$2"
  rm -f "$out"

  "$PY" - "$in" "$out" <<'PY'
import sys
from pathlib import Path
import pyimg4

src, out = map(Path, sys.argv[1:])

try:
    item = pyimg4.IM4P(src.read_bytes())
except Exception as exc:
    raise SystemExit(f"failed to parse IM4P {src}: {exc}")

payload = item.payload

if payload.encrypted:
    raise SystemExit(
        f"IM4P payload is encrypted: {src}. "
        "A valid IV/key or firmware keybag is required."
    )

if payload.compression != pyimg4.Compression.NONE:
    print(f"decompressing {payload.compression.name}: {src}")
    try:
        payload.decompress()
    except Exception as exc:
        raise SystemExit(f"failed to decompress {src}: {exc}")

data = payload.output().data
if not data:
    raise SystemExit(f"empty IM4P payload after processing: {src}")

out.write_bytes(data)
print(f"extracted {len(data)} bytes -> {out}")
PY

  [[ -s "$out" ]] || die "empty extracted payload: $out"

  # iBoot/iBEC patchfinders consume a raw executable image, not necessarily
  # a Mach-O container. The first word may therefore be an ARM64 instruction
  # (for example 0x90000000 = ADRP X0, #0) rather than a Mach-O magic.
}

for key in iBEC KernelCache DeviceTree RestoreTrustCache; do
  cp "$CACHE/$(basename "$(path_for "$key")")" "$WORK/$key.im4p"
done

# RestoreSEP is fetched into the per-firmware cache above. Stage the exact
# cached member into WORK before packaging; otherwise the later packager
# cannot see it after WORK is recreated.
if (( WITH_SEP )); then
  SEP_CACHE="$CACHE/$(basename "$(path_for RestoreSEP)")"
  [[ -s "$SEP_CACHE" ]] || die "RestoreSEP cache member is missing: $SEP_CACHE"
  cp "$SEP_CACHE" "$WORK/RestoreSEP.im4p"
  [[ -s "$WORK/RestoreSEP.im4p" ]] || die "failed to stage RestoreSEP into WORK"
fi
RESTORE_RAMDISK_SRC="$CACHE/$(basename "$(path_for RestoreRamDisk)")"
[[ -s "$RESTORE_RAMDISK_SRC" ]] || die "RestoreRamDisk payload missing: $RESTORE_RAMDISK_SRC"
log "Extracting RestoreRamDisk IM4P payload"
extract_raw "$RESTORE_RAMDISK_SRC" "$WORK/RestoreRamDisk.dmg"
[[ -s "$WORK/RestoreRamDisk.dmg" ]] || die "RestoreRamDisk payload extraction failed"
(( USE_IBSS )) && cp "$CACHE/$(basename "$(path_for iBSS)")" "$WORK/iBSS.im4p"

for key in AOP ANE AVE ISP GFX SIO SPTM TXM; do
  p="$(path_for "$key")"
  [[ -n "$p" ]] && cp "$CACHE/$(basename "$p")" "$WORK/$key.im4p"
done

extract_raw "$WORK/iBEC.im4p" "$WORK/iBEC.raw"
extract_raw "$WORK/KernelCache.im4p" "$WORK/kernelcache.raw"

# Keep a decompressed IM4P container as the input to the IMG4 patching stage.
# kerneldiff compares raw Mach-O bytes, but img4 -P operates on an IM4P
# container (the reference workflow calls this kernelcache.dec).
rm -f "$WORK/kernelcache.dec"
# Produce the decompressed IM4P container used by img4 -P.  This is distinct
# from kernelcache.raw: kerneldiff works on raw Mach-O bytes, while img4 -P
# expects the original IM4P container with its payload decompressed.
"$IMG4" -i "$WORK/KernelCache.im4p" -o "$WORK/kernelcache.dec" -D
[[ -s "$WORK/kernelcache.dec" ]] || die "failed to create decompressed kernel IM4P: $WORK/kernelcache.dec"

# Fail early if the -D product is not a Mach-O-bearing IM4P.
"$PY" - "$WORK/kernelcache.dec" <<'PY'
import sys
from pathlib import Path
from pyimg4 import IM4P
p = IM4P(Path(sys.argv[1]).read_bytes())
payload = p.payload
if payload.compression:
    payload.decompress()
data = payload.output().data
if data[:4] not in (bytes.fromhex("cffaedfe"), bytes.fromhex("feedfacf")):
    raise SystemExit(f"decompressed KernelCache IM4P is not Mach-O: magic={data[:4].hex()}")
print(f"decompressed KernelCache IM4P verified: Mach-O payload={len(data)} bytes")
PY

(( USE_IBSS )) && extract_raw "$WORK/iBSS.im4p" "$WORK/iBSS.raw"
if (( USE_IBSS )); then
  iBSS_SIZE="$(stat -c %s "$WORK/iBSS.raw")"
  iBEC_SIZE="$(stat -c %s "$WORK/iBEC.raw")"
  iBSS_HASH="$(sha256sum "$WORK/iBSS.raw" | awk '{print $1}')"
  iBEC_HASH="$(sha256sum "$WORK/iBEC.raw" | awk '{print $1}')"
  iBSS_IM4P_HASH="$(sha256sum "$WORK/iBSS.im4p" | awk '{print $1}')"
  iBEC_IM4P_HASH="$(sha256sum "$WORK/iBEC.im4p" | awk '{print $1}')"
  echo "iBSS source: $IBSS_PATH"
  echo "iBEC source: $IBEC_PATH"
  echo "iBSS IM4P: $iBSS_IM4P_HASH"
  echo "iBEC IM4P: $iBEC_IM4P_HASH"
  echo "iBSS raw: $iBSS_SIZE bytes $iBSS_HASH"
  echo "iBEC raw: $iBEC_SIZE bytes $iBEC_HASH"

  [[ "$IBSS_PATH" == Firmware/dfu/iBSS.*.RELEASE.im4p ]] ||
    die "unexpected iBSS manifest path: $IBSS_PATH"
  [[ "$IBEC_PATH" == Firmware/dfu/iBEC.*.RELEASE.im4p ]] ||
    die "unexpected iBEC manifest path: $IBEC_PATH"
  [[ "$IBSS_PATH" != "$IBEC_PATH" ]] ||
    die "BuildManifest points iBSS and iBEC at the same IM4P member"
  [[ "$iBSS_IM4P_HASH" != "$iBEC_IM4P_HASH" ]] ||
    die "iBSS and iBEC IM4P containers are identical"
  if [[ "$iBSS_HASH" == "$iBEC_HASH" ]]; then
    echo "==> iBSS/iBEC share the same decompressed iBoot payload; keeping both containers and patching each mode separately"
  fi
fi
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
"$PY" "$BUNNY_PATCH/iboot_patchfinder.py" "$WORK/iBEC.raw" "$WORK/iBEC.patched.pre-final.raw" --mode ibec | tee "$IBOOT_LOG"
if ! grep -Eq '[1-9][0-9]* patches?, [1-9][0-9]* functions found|[1-9][0-9]* patches' "$IBOOT_LOG"; then
  echo "[x] iBEC patchfinder found no applicable patches for $PRODUCT $VERSION $BUILD" >&2
  echo "    This firmware is not confirmed by the selected patchfinder; refusing to continue with an unchanged iBEC." >&2
  exit 1
fi
[[ -s "$WORK/iBEC.patched.pre-final.raw" ]] || die "iBEC patchfinder produced no output"
# The Leeksov finder has a known d321 early false-positive at 0xE10 on
# iOS 18.x. Finalize the patched image against the stock image before IMG4
# packaging; this restores that early site and patches the real ASN.1-near
# image4 canary instead.
"$PY" "$ROOT/scripts/finalize_iboot.py"   --stock "$WORK/iBEC.raw"   --input "$WORK/iBEC.patched.pre-final.raw"   --output "$WORK/iBEC.patched.raw"   --board "$MODEL"
[[ -s "$WORK/iBEC.patched.raw" ]] || die "iBEC finalization produced no output"

if (( USE_IBSS )); then
  log "Patching iBSS"
  "$PY" "$BUNNY_PATCH/iboot_patchfinder.py" "$WORK/iBSS.raw" "$WORK/iBSS.patched.pre-final.raw" --mode ibss
  "$PY" "$ROOT/scripts/finalize_iboot.py"     --stock "$WORK/iBSS.raw"     --input "$WORK/iBSS.patched.pre-final.raw"     --output "$WORK/iBSS.patched.raw"     --board "$MODEL"
  cp "$WORK/iBSS.patched.raw" "$BOOT/iBSS.patched.raw"
fi

if [[ "$KERNEL_MODE" == patched ]]; then
  log "Patching kernel (minimal iOS 18 A12/A13 set)"
  KERNEL_LOG="$WORK/kernel-patch.log"
  "$PY" "$ROOT/scripts/apply_ios18_kernel_patches.py"     "$WORK/kernelcache.raw" "$WORK/kernelcache.patched.raw" | tee "$KERNEL_LOG"
  grep -Eq "iOS 18 minimal kernel patch set: 6 instructions, byte_delta=([1-9]|1[0-9]|2[0-4])$" "$KERNEL_LOG" ||
    die "iOS 18 kernel patch invariant failed"
else
  cp "$WORK/kernelcache.raw" "$WORK/kernelcache.patched.raw"
fi

log "Creating kernel patch diff (kc.bpatch)"
"$PY" "$ROOT/scripts/kerneldiff.py" "$WORK/kernelcache.raw" "$WORK/kernelcache.patched.raw" "$WORK/kc.bpatch"
[[ -s "$WORK/kc.bpatch" ]] || die "kernel patch diff is empty"
PATCH_COUNT="$(grep -Ec '^0x[0-9a-fA-F]+ 0x[0-9a-fA-F]+ 0x[0-9a-fA-F]+' "$WORK/kc.bpatch" || true)"
(( PATCH_COUNT > 0 )) || die "kernel patch diff contains no byte changes"
echo "kc.bpatch: $PATCH_COUNT byte patches"

cp "$WORK/iBEC.patched.raw" "$BOOT/iBEC.patched.raw"
[[ -s "$BOOT/iBEC.patched.raw" ]] || die "failed to stage raw patched iBEC"
"$IMG4" -i "$BOOT/iBEC.patched.raw" -o "$BOOT/iBEC.patched.img4" -M "$IM4M" -A -T ibec
# The reference A12/A13 flow uses img4 -P on the decompressed KernelCache
# IM4P and emits an rkrn IMG4.  -P applies the kc.bpatch byte changes to the
# payload during reassembly; it is not a property named "krnl".
# Therefore the final kernel artifact is a patched rkrn payload, not a stock
# kernel plus a second patch property.

"$IMG4" -i "$WORK/kernelcache.dec" \
  -o "$BOOT/kernelcache.img4.patched" \
  -M "$IM4M" \
  -T rkrn \
  -P "$WORK/kc.bpatch" \
  -J

# Validate the exact artifact delivered to iBoot using the same img4
# extractor used to obtain kcache.raw.  pyimg4 can expose the internal
# compression/property stream rather than the final Mach-O for some IMG4
# variants; that is not the correct transport-level validation here.
FINAL_KERNEL_RAW="$WORK/kernelcache.final.raw"
rm -f "$FINAL_KERNEL_RAW"
"$IMG4" -i "$BOOT/kernelcache.img4.patched" -o "$FINAL_KERNEL_RAW"
[[ -s "$FINAL_KERNEL_RAW" ]] || die "img4 could not extract the final kernel payload"

"$PY" - "$FINAL_KERNEL_RAW" "$WORK/kernelcache.raw" "$WORK/kc.bpatch" <<'PY'
import sys
from pathlib import Path

final_path = Path(sys.argv[1])
stock_path = Path(sys.argv[2])
patch_path = Path(sys.argv[3])
final_data = final_path.read_bytes()
stock_data = stock_path.read_bytes()

if final_data[:4] not in (bytes.fromhex("cffaedfe"), bytes.fromhex("feedfacf")):
    raise SystemExit(
        f"final kernel payload is not Mach-O after img4 extraction: "
        f"magic={final_data[:4].hex()}"
    )
if len(final_data) != len(stock_data):
    raise SystemExit(
        f"final kernel size mismatch: stock={len(stock_data)} final={len(final_data)}"
    )

checked = 0
changed = 0
for raw in patch_path.read_text().splitlines():
    line = raw.split("#", 1)[0].split(";", 1)[0].strip()
    if not line:
        continue
    fields = line.split()
    if len(fields) < 3:
        raise SystemExit(f"malformed kc.bpatch line: {raw!r}")
    off = int(fields[0], 0)
    old = int(fields[1], 0)
    new = int(fields[2], 0)
    if off >= len(final_data) or off >= len(stock_data):
        raise SystemExit(f"kc.bpatch offset 0x{off:x} outside final kernel")
    if stock_data[off] != old:
        raise SystemExit(
            f"stock kernel mismatch at 0x{off:x}: "
            f"got={stock_data[off]:02x}, patch-old={old:02x}"
        )
    if final_data[off] != new:
        raise SystemExit(
            f"kc.bpatch missing at 0x{off:x}: "
            f"got={final_data[off]:02x}, expected-new={new:02x}"
        )
    checked += 1

if checked == 0:
    raise SystemExit("kc.bpatch contains no byte patches")

# Confirm there really are differences, and that they are exactly the patch list.
for off in range(len(stock_data)):
    if stock_data[off] != final_data[off]:
        changed += 1

if changed != checked:
    raise SystemExit(
        f"final kernel differs from stock at {changed} byte(s), "
        f"but kc.bpatch contains {checked} patch(es)"
    )

print(
    f"kernel IMG4 verified: type=rkrn, Mach-O payload={len(final_data)} bytes, "
    f"applied patches={checked}, exact byte delta={changed}"
)
PY

"$IMG4" -i "$WORK/DeviceTree.im4p" -o "$BOOT/devicetree.img4" -M "$IM4M" -T rdtr

# Always unpack the stock RestoreTrustCache first. When SSH is injected, the
# additional signed Mach-O payloads must be appended to this exact cache
# before it is wrapped back into rtsc.
"$IMG4" -i "$WORK/RestoreTrustCache.im4p" -o "$WORK/trustcache.bin"
[[ -s "$WORK/trustcache.bin" ]] || die "failed to extract RestoreTrustCache"

if (( WITH_SEP )); then
  [[ -s "$WORK/RestoreSEP.im4p" ]] || die "RestoreSEP extraction missing: $WORK/RestoreSEP.im4p"
  "$IMG4" -i "$WORK/RestoreSEP.im4p" -o "$BOOT/sep-firmware.img4" -M "$IM4M" -T rsep
  [[ -s "$BOOT/sep-firmware.img4" ]] || die "RestoreSEP packaging failed"
  echo "RestoreSEP packaged: $BOOT/sep-firmware.img4"
fi

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
    curl --fail --show-error --location --retry 8 --retry-all-errors       --connect-timeout 20 --speed-time 60 --speed-limit 1024       -o "$SSH_TAR"       https://raw.githubusercontent.com/Pa7r0n/ICH_A12_plus_Ramdisk/main/resources/ssh.tar.gz
  fi
  [[ -s "$SSH_TAR" ]] || die "SSH payload is empty"

  SSH_LIST="$BUNNY_RESOURCES/sshtarlist.txt"
  if [[ ! -s "$SSH_LIST" ]]; then
    curl --fail --show-error --location --retry 8 --retry-all-errors       --connect-timeout 20 --speed-time 60 --speed-limit 1024       -o "$SSH_LIST"       https://raw.githubusercontent.com/Pa7r0n/ICH_A12_plus_Ramdisk/main/resources/sshtarlist.txt
  fi
  [[ -s "$SSH_LIST" ]] || die "SSH payload allowlist is empty"

  BUNNY_RESTORED_EXTERNAL="$BUNNY_RESOURCES/restored_external"
  # Use the exact upstream ICH A12/A13 restored_external payload. It is a
  # Mach-O executable, not a shell script; do not download/replace it.
  install -m 0755 "$ROOT/resources/bunny_restored_external" "$BUNNY_RESTORED_EXTERNAL"
  [[ -s "$BUNNY_RESTORED_EXTERNAL" ]] || die "restored_external is empty"

  SSH_STAGE="$WORK/ssh-stage"
  prepare_ssh_tree "$SSH_TAR" "$SSH_LIST" "$SSH_STAGE"
  verify_ssh_allowlist "$SSH_STAGE" "$SSH_LIST"

  # Replace the stock rc.boot launcher with our SSH-only entrypoint. This is a
  # shell script and therefore does not require a code-signature/trustcache
  # entry; Dropbear itself remains covered by sshtarlist.txt.
  # ssh-stage is created only from allowlisted paths, so /etc may not exist
  # until we add our launcher explicitly.
  mkdir -p "$SSH_STAGE/etc"
  install -m 0755 "$ROOT/resources/bunny_rc.boot" "$SSH_STAGE/etc/rc.boot"
  [[ -x "$SSH_STAGE/etc/rc.boot" ]] || die "failed to stage Bunny rc.boot"

  # The ICH restored_external replaces the archive copy. Put the exact final
  # bytes into the trustcache staging tree before collecting CDHashes.
  if [[ -s "$BUNNY_RESTORED_EXTERNAL" ]]; then
    install -m 0755 "$BUNNY_RESTORED_EXTERNAL" "$SSH_STAGE/usr/local/bin/restored_external"
  fi

  SSH_FILES=()
  SSH_FILE_COUNT=0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="$(printf '%s\n' "$entry" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$entry" ]] || continue
    rel="$(printf '%s\n' "$entry" | sed 's#^work/sshtar/##')"
    SSH_FILES+=("$SSH_STAGE/$rel")
    SSH_FILE_COUNT=$((SSH_FILE_COUNT + 1))
  done < "$SSH_LIST"

  (( SSH_FILE_COUNT > 0 )) || die "SSH trustcache allowlist contains no files"
  [[ -x "$BUNNY_TOOLS/trustcache" ]] || die "missing trustcache tool; run ./setup_dependencies.sh"

  log "Appending SSH Mach-O hashes to RestoreTrustCache"
  "$BUNNY_TOOLS/trustcache" append "$WORK/trustcache.bin" "${SSH_FILES[@]}"

  [[ -s "$WORK/trustcache.bin" ]] || die "trustcache append produced an empty cache"

  log "Injecting SSH into RestoreRamDisk.dmg"
  inject_ssh_ramdisk "$WORK/RestoreRamDisk.dmg" "$SSH_TAR" "$WORK/ramdisk-injected.dmg"
  [[ -s "$WORK/ramdisk-injected.dmg" ]] || die "ramdisk injection produced no image"

  "$IMG4" -i "$WORK/ramdisk-injected.dmg"     -o "$BOOT/ramdisk.img4" -M "$IM4M" -A -T rdsk
else
  "$IMG4" -i "$WORK/RestoreRamDisk.dmg"     -o "$BOOT/ramdisk.img4" -M "$IM4M" -A -T rdsk
fi

"$IMG4" -i "$WORK/trustcache.bin"   -o "$BOOT/trustcache.img4" -M "$IM4M" -A -T rtsc
[[ -s "$BOOT/trustcache.img4" ]] || die "trustcache IMG4 was not produced"

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

# Project boot logo. Prefer an explicit override, then the historical
# repo-root logo.jpg, then the known-good ICH resource downloaded by setup.
LOGO_OVERRIDE="$(printenv BUNNY_LOGO_PATH 2>/dev/null || true)"
if [[ -n "$LOGO_OVERRIDE" ]]; then
  LOGO_SOURCE="$LOGO_OVERRIDE"
elif [[ -f "$ROOT/logo.jpg" ]]; then
  LOGO_SOURCE="$ROOT/logo.jpg"
elif [[ -f "$BUNNY_RESOURCES/ich_logo.png" ]]; then
  LOGO_SOURCE="$BUNNY_RESOURCES/ich_logo.png"
else
  die "boot logo source not found: set BUNNY_LOGO_PATH, add logo.jpg, or run ./setup_dependencies.sh"
fi
[[ -s "$LOGO_SOURCE" ]] || die "boot logo source is empty: $LOGO_SOURCE"

log "Building boot logo from $(basename "$LOGO_SOURCE") for $MODEL"
BUNNY_LOGO_MODEL="$MODEL" BUNNY_LOGO_CPID="$CPID"   "$BASH" "$ROOT/scripts/make_logo.sh" "$LOGO_SOURCE" --out "$BOOT/logo.img4"
[[ -s "$BOOT/logo.img4" ]] || die "boot logo generation produced no IMG4"

"$PY" - "$BOOT/logo.img4" <<'PY'
import sys
from pathlib import Path
from pyimg4 import IMG4

p = Path(sys.argv[1])
obj = IMG4(p.read_bytes())
if not obj.im4p:
    raise SystemExit("boot logo IMG4 has no IM4P")
if obj.im4p.fourcc != "logo":
    raise SystemExit(f"boot logo IMG4 has wrong fourcc: {obj.im4p.fourcc!r}")
payload = obj.im4p.payload
if payload.compression:
    payload.decompress()
data = payload.output().data
if not data:
    raise SystemExit("boot logo IMG4 has an empty payload")
print(f"boot logo verified: rlgo, payload={len(data)} bytes")
PY

printf "logo_source=%s\n" "$LOGO_SOURCE" >> "$BOOT/chain.info"
printf '%s\n' "$(basename "$BOOT")" > "$BUNNY_LAST"
rm -rf "$WORK"
echo
echo "=== BUILD COMPLETE ==="
echo "$BOOT"
