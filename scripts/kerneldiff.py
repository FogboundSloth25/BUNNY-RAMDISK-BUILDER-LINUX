#!/usr/bin/env python3
"""Create an iBoot-compatible text kernel patch list from two equal-sized files."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

HEADER = "#AMFI\n\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("original", type=Path)
    parser.add_argument("patched", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.original.read_bytes()
    patched = args.patched.read_bytes()
    if len(original) != len(patched):
        raise SystemExit(
            f"size mismatch: original={len(original)} patched={len(patched)}"
        )

    count = 0
    with args.output.open("w", encoding="ascii", newline="\n") as out:
        out.write(HEADER)
        for off, (old, new) in enumerate(zip(original, patched)):
            if old == new:
                continue
            out.write(f"0x{off:x} 0x{old:02x} 0x{new:02x}\n")
            count += 1

    if count == 0:
        args.output.unlink(missing_ok=True)
        raise SystemExit("no byte changes found")
    print(f"generated {count} byte patches -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
