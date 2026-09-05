#!/usr/bin/env python3
from pathlib import Path
import argparse
from pyimg4 import IMG4, IM4M, IM4P, PayloadProperty, Compression

ap = argparse.ArgumentParser()
ap.add_argument("--im4p", required=True)
ap.add_argument("--output", required=True)
ap.add_argument("--im4m", required=True)
ap.add_argument("--raw", default=None)
ap.add_argument("--fourcc", default=None)
ap.add_argument("--lzfse", action="store_true")
a = ap.parse_args()

template = IM4P(Path(a.im4p).read_bytes())
if a.raw:
    item = IM4P(
        fourcc=a.fourcc or template.fourcc,
        description=template.description,
        payload=Path(a.raw).read_bytes(),
    )
    for prop in template.properties or []:
        item.add_property(PayloadProperty(fourcc=prop.fourcc, value=prop.value))
    if a.lzfse:
        item.payload.compress(Compression.LZFSE)
else:
    item = template

Path(a.output).write_bytes(
    IMG4(im4p=item, im4m=IM4M(Path(a.im4m).read_bytes())).output()
)
print(a.output)
