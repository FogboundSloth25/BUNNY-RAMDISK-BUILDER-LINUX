#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
PY="$(python_bin)"
INPUT="${BUNNY_LOGO_PATH:-$ROOT/logo.jpg}"
OUT=""
BOARD="${BUNNY_LOGO_MODEL:-}"
CPID="${BUNNY_LOGO_CPID:-}"
while (($#)); do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done
[ -n "$OUT" ] || die "use --out OUTPUT.img4"

field_from_irecovery() {
  command -v irecovery >/dev/null 2>&1 || return 0
  local info
  info="$(irecovery -q 2>/dev/null || true)"
  awk -F': ' -v key="$1" '$1 == key {print $2; exit}' <<<"$info"
}

if [[ ! -f "$INPUT" && "$INPUT" == "$ROOT/logo.jpg" && -f "$BUNNY_RESOURCES/ich_logo.png" ]]; then
  INPUT="$BUNNY_RESOURCES/ich_logo.png"
fi
[ -f "$INPUT" ] || die "boot logo source not found: $INPUT"

BOARD="${BOARD:-$(field_from_irecovery MODEL)}"
CPID="${CPID:-$(field_from_irecovery CPID)}"
CPID="${CPID:-0x8020}"

panel_for_board() {
  case "$1" in
    n841ap) echo "828 1792" ;;
    d321ap) echo "1125 2436" ;;
    d331ap|d331pap) echo "1242 2688" ;;
    n104ap) echo "828 1792" ;;
    d421ap) echo "1125 2436" ;;
    d431ap) echo "1242 2688" ;;
    d79ap) echo "750 1334" ;;
    j210ap|j210aap) echo "1536 2048" ;;
    j217ap|j218ap) echo "1668 2224" ;;
    j320ap|j321ap) echo "1668 2388" ;;
    j417ap|j418ap) echo "2048 2732" ;;
    j307ap|j308ap) echo "1620 2160" ;;
    *) return 1 ;;
  esac
}

if [[ -n "${BUNNY_LOGO_WIDTH:-}" && -n "${BUNNY_LOGO_HEIGHT:-}" ]]; then
  WIDTH="$BUNNY_LOGO_WIDTH"
  HEIGHT="$BUNNY_LOGO_HEIGHT"
elif [[ -n "$BOARD" ]] && panel="$(panel_for_board "$BOARD")"; then
  read -r WIDTH HEIGHT <<<"$panel"
else
  WIDTH=1125
  HEIGHT=2436
  [[ -z "$BOARD" ]] || warn "unknown board '$BOARD'; using fallback panel ${WIDTH}x${HEIGHT}"
fi

if [[ -n "${BUNNY_LOGO_MARK:-}" ]]; then
  MARK="$BUNNY_LOGO_MARK"
else
  SHORT="$WIDTH"
  [ "$HEIGHT" -lt "$WIDTH" ] && SHORT="$HEIGHT"
  MARK=$((SHORT * 35 / 100))
fi
[ "$MARK" -lt 240 ] && MARK=240
[ "$MARK" -gt 720 ] && MARK=720
MARK=$((MARK - MARK % 2))
IBOOTIM="$BUNNY_TOOLS/ibootim"
[ -x "$IBOOTIM" ] || die "missing ibootim; run ./setup_dependencies.sh"
IMG4="$BUNNY_TOOLS/img4"
[ -x "$IMG4" ] || IMG4="$ROOT/.local/img4"
[ -x "$IMG4" ] || die "missing img4 tool"
case "${CPID,,}" in
  0x8020|8020) IM4M="$BUNNY_RESOURCES/IM4M_0x8020" ;;
  0x8030|8030) IM4M="$BUNNY_RESOURCES/IM4M_0x8030" ;;
  *) IM4M="$BUNNY_RESOURCES/IM4M_${CPID}" ;;
esac
[ -s "$IM4M" ] || die "missing IM4M: $IM4M"
WORK="$(mktemp -d "$ROOT/work/logo.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FULL="$WORK/logo-$WIDTH"x"$HEIGHT.png"
RAW="$WORK/logo.raw"
"$PY" - "$INPUT" "$FULL" "$WIDTH" "$HEIGHT" "$MARK" <<'PY'
import sys
from pathlib import Path
from PIL import Image
src, out, W, H, mark = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
im = Image.open(src).convert("RGBA")
base = Image.new("RGBA", im.size, (255,255,255,255))
base.paste(im, mask=im.getchannel("A"))
bw = base.convert("L").point(lambda p: 255 if p < 140 else 0, "L").convert("RGB")
mark_im = bw.resize((mark, mark), Image.Resampling.NEAREST)
canvas = Image.new("RGB", (W,H), (0,0,0))
canvas.paste(mark_im, ((W-mark)//2, (H-mark)//2))
canvas.save(out, "PNG")
white = sum(1 for p in canvas.getdata() if p[0] > 200)
print("logo canvas", W, H, "mark", mark, "white_pixels", white)
if white < 100: raise SystemExit("logo contains fewer than 100 visible white pixels")
PY
"$IBOOTIM" "$FULL" "$RAW"

# Verify that the generated iBoot Embedded Image is readable again and
# preserves the exact panel dimensions. This catches malformed color-space
# headers before the IMG4 is sent to an actual device.
ROUNDTRIP="$WORK/logo-roundtrip.png"
"$IBOOTIM" -c "$RAW" "$ROUNDTRIP" >/dev/null
"$PY" - "$ROUNDTRIP" "$WIDTH" "$HEIGHT" <<'PY'
import sys
from pathlib import Path
from PIL import Image
p=Path(sys.argv[1]); expected=(int(sys.argv[2]), int(sys.argv[3]))
im=Image.open(p)
if im.size != expected:
    raise SystemExit(f"iBootIm round-trip dimensions mismatch: got={im.size}, expected={expected}")
if im.getbbox() is None:
    raise SystemExit("iBootIm round-trip is completely empty")
print(f"iBootIm round-trip verified: {im.size[0]}x{im.size[1]}")
PY
mkdir -p "$(dirname "$OUT")"
"$IMG4" -i "$RAW" -o "$OUT" -A -T logo -M "$IM4M"
[ -s "$OUT" ] || die "logo IMG4 was not produced"
"$PY" - "$OUT" <<'PY'
import sys
from pathlib import Path
from pyimg4 import IMG4
obj = IMG4(Path(sys.argv[1]).read_bytes())
if not obj.im4p: raise SystemExit("logo IMG4 has no IM4P")
if obj.im4p.fourcc != "logo": raise SystemExit("wrong logo fourcc: " + repr(obj.im4p.fourcc))
print("logo IMG4 verified")
PY
