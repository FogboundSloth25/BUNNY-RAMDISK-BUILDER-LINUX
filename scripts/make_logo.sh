#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/env.sh"
PY="$(python_bin)"
INPUT="$ROOT/logo.jpg"
OUT=""
while (($#)); do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) INPUT="$1"; shift ;;
  esac
done
[ -f "$INPUT" ] || die "boot logo source not found: $INPUT"
[ -n "$OUT" ] || die "use --out OUTPUT.img4"
read -r WIDTH HEIGHT <<EOF
1125 2436
EOF
SHORT="$WIDTH"
[ "$HEIGHT" -lt "$WIDTH" ] && SHORT="$HEIGHT"
MARK=$((SHORT * 35 / 100))
[ "$MARK" -lt 240 ] && MARK=240
[ "$MARK" -gt 720 ] && MARK=720
MARK=$((MARK - MARK % 2))
IBOOTIM="$BUNNY_TOOLS/ibootim"
[ -x "$IBOOTIM" ] || die "missing ibootim; run ./setup_dependencies.sh"
IMG4="$BUNNY_TOOLS/img4"
[ -x "$IMG4" ] || IMG4="$ROOT/.local/img4"
[ -x "$IMG4" ] || die "missing img4 tool"
IM4M="$BUNNY_RESOURCES/IM4M_0x8020"
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
