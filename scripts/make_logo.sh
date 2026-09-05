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
import statistics
import sys
import os
from pathlib import Path
from PIL import Image

src, out, W, H, mark = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
im = Image.open(src).convert("RGBA")

# ibootim itself performs the required RGBA -> BGRA conversion. Do not
# pre-swap channels here. Normalize arbitrary artwork to white-on-black.
rgba = im.load()
bw, bh = im.size
frame_x = max(1, min(16, bw // 20))
frame_y = max(1, min(16, bh // 20))
border = []
for y in range(bh):
    if y < frame_y or y >= bh - frame_y:
        xs = range(bw)
    else:
        xs = list(range(frame_x)) + list(range(max(frame_x, bw-frame_x), bw))
    for x in xs:
        border.append(rgba[x, y])

def lum(px):
    r,g,b,a = px
    if a < 16:
        return 0
    return 0.2126*r + 0.7152*g + 0.0722*b

bg = statistics.median(lum(px) for px in border) if border else 0
gray = im.convert("L")
mode = os.environ.get("BUNNY_LOGO_INVERT", "auto").lower() if "os" in globals() else "auto"
if mode not in {"auto", "light", "dark", "1", "0"}:
    raise SystemExit("BUNNY_LOGO_INVERT must be auto, light, dark, 1, or 0")
invert = (bg >= 128) if mode == "auto" else mode in {"light", "1"}

if invert:
    threshold = max(72, min(210, round(bg * 0.72)))
    mask = gray.point(lambda p: 255 if p < threshold else 0, "L")
else:
    threshold = max(45, min(210, round(bg + (255-bg) * 0.28)))
    mask = gray.point(lambda p: 255 if p > threshold else 0, "L")

mono = mask.convert("RGB")
src_w, src_h = mono.size
scale = min(mark / src_w, mark / src_h)
new_w = max(1, round(src_w * scale))
new_h = max(1, round(src_h * scale))
mark_im = mono.resize((new_w, new_h), Image.Resampling.LANCZOS)
canvas = Image.new("RGB", (W, H), (0, 0, 0))
canvas.paste(mark_im, ((W-new_w)//2, (H-new_h)//2))
out.parent.mkdir(parents=True, exist_ok=True)
canvas.save(out, "PNG")

corner = [canvas.getpixel((0,0)), canvas.getpixel((W-1,0)), canvas.getpixel((0,H-1)), canvas.getpixel((W-1,H-1))]
white = sum(1 for p in canvas.getdata() if p[0] > 200)
print(f"logo canvas {W}x{H} mark_box={new_w}x{new_h} background_luma={bg:.1f} invert={invert} threshold={threshold} white_pixels={white}")
if any(p != (0,0,0) for p in corner):
    raise SystemExit("logo canvas corners are not pure black")
if white < 100:
    raise SystemExit("logo has fewer than 100 visible white pixels")
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
