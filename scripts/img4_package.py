#!/usr/bin/env python3
from pathlib import Path
import argparse
from pyimg4 import IMG4, IM4M, IM4P, PayloadProperty, Compression

ap = argparse.ArgumentParser()
ap.add_argument("--im4p")
ap.add_argument("--output", required=True)
ap.add_argument("--im4m", required=True)
ap.add_argument("--raw")
ap.add_argument("--fourcc")
ap.add_argument("--description", default="")
ap.add_argument("--lzfse", action="store_true")
args = ap.parse_args()

if not args.im4p and not args.raw:
    raise SystemExit("one of --im4p or --raw is required")

template = IM4P(Path(args.im4p).read_bytes()) if args.im4p else None

if args.raw:
    item = IM4P(
        fourcc=args.fourcc or (template.fourcc if template else "rdsk"),
        description=args.description or (template.description if template else "RestoreRamDisk"),
        payload=Path(args.raw).read_bytes(),
    )
    for prop in (template.properties if template else []) or []:
        item.add_property(PayloadProperty(fourcc=prop.fourcc, value=prop.value))
    if args.lzfse or (template and template.payload.compression != Compression.NONE):
        item.payload.compress(Compression.LZFSE)
else:
    item = template

if not item:
    raise SystemExit("could not construct IM4P")

Path(args.output).write_bytes(
    IMG4(im4p=item, im4m=IM4M(Path(args.im4m).read_bytes())).output()
)
print(args.output)
