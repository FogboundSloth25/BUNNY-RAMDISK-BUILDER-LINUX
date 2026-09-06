#!/usr/bin/env python3
"""Build a tiny Darwin/arm64e Mach-O restored_external launcher on Linux.

The launcher is freestanding: it uses Darwin BSD syscalls directly, prints the
Bunny banner to stderr/console, then execve()s the already-installed Dropbear
binary. It has no Linux ABI and no Linux ELF loader dependency.
"""
from __future__ import annotations
import argparse
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path

PAGE = 0x1000
BASE = 0x100000000
TEXT_FILEOFF = 0x1000
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
MH_EXECUTE = 2
MH_PIE = 0x00200000
LC_SEGMENT_64 = 0x19
LC_MAIN = 0x80000028
LC_BUILD_VERSION = 0x32

BANNER = b"VALIDITY IS THE BEST\n"
STRINGS = {
    "banner": BANNER,
    "path": b"/usr/local/bin/dropbear\0",
    "arg_R": b"-R\0",
    "arg_E": b"-E\0",
    "arg_F": b"-F\0",
    "arg_p": b"-p\0",
    "arg_44": b"44\0",
}

def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)

def align(value: int, n: int) -> int:
    return (value + n - 1) & ~(n - 1)

def patch_adrp(buf: bytearray, off: int, pc: int, target: int) -> None:
    ins = struct.unpack_from("<I", buf, off)[0]
    delta_pages = (target & ~0xFFF) - (pc & ~0xFFF)
    delta_pages //= 0x1000
    if not -(1 << 20) <= delta_pages < (1 << 20):
        raise ValueError(f"ADRP target out of range: {delta_pages}")
    imm21 = delta_pages & ((1 << 21) - 1)
    ins &= ~((0x3 << 29) | (0x7FFFF << 5))
    ins |= ((imm21 & 0x3) << 29) | (((imm21 >> 2) & 0x7FFFF) << 5)
    struct.pack_into("<I", buf, off, ins)

def patch_add_imm12(buf: bytearray, off: int, target: int) -> None:
    ins = struct.unpack_from("<I", buf, off)[0]
    imm12 = target & 0xFFF
    ins &= ~(0xFFF << 10)
    ins |= imm12 << 10
    struct.pack_into("<I", buf, off, ins)

def symbol_offset(name: str, cstr: bytes) -> int:
    needle = STRINGS[name]
    pos = cstr.find(needle)
    if pos < 0:
        raise SystemExit(f"missing expected cstring {name!r}")
    return pos

def build(source: Path, output: Path, clang: str, objcopy: str) -> None:
    with tempfile.TemporaryDirectory(prefix="bunny-darwin-launcher-") as td:
        t = Path(td)
        obj = t / "launcher.o"
        textbin = t / "text.bin"
        cstrbin = t / "cstring.bin"

        run([
            clang, "--target=arm64-apple-darwin", "-c",
            "-O2", "-o", str(obj), str(source),
        ])
        run([objcopy, "--dump-section=__TEXT,__text=" + str(textbin), str(obj)])
        run([objcopy, "--dump-section=__TEXT,__cstring=" + str(cstrbin), str(obj)])

        text = bytearray(textbin.read_bytes())
        cstr = cstrbin.read_bytes()
        if not text or not cstr:
            raise SystemExit("Darwin launcher object sections are empty")

        # Relocations emitted by clang's Darwin assembler:
        rel = subprocess.run(
            ["llvm-objdump", "-r", str(obj)],
            check=True, text=True, capture_output=True
        ).stdout
        relocations = []
        for line in rel.splitlines():
            m = re.match(r"^([0-9a-f]+)\s+ARM64_RELOC_(PAGE21|PAGEOFF12)\s+(\S+)$", line.strip())
            if m:
                relocations.append((int(m.group(1), 16), m.group(2), m.group(3)))

        if len(relocations) != 16:
            raise SystemExit(
                f"unexpected relocation count: expected 16, got {len(relocations)}"
            )

        text_va = BASE + TEXT_FILEOFF
        cstr_va = text_va + len(text)
        for off, kind, name in relocations:
            if name not in STRINGS:
                raise SystemExit(f"unexpected launcher relocation target: {name}")
            target = cstr_va + symbol_offset(name, cstr)
            pc = text_va + off
            if kind == "PAGE21":
                patch_adrp(text, off, pc, target)
            else:
                patch_add_imm12(text, off, target)

        # Verify each relocated pair against the final symbol address. An
        # ADRP with a zero page delta is valid when the symbol is on the same
        # 4 KiB page as the instruction; therefore checking for the literal
        # encoding 0x90000000 would falsely reject a correctly relocated ADRP.
        def decode_adrp_target(ins: int, pc: int) -> int:
            if (ins & 0x9F000000) != 0x90000000:
                raise SystemExit(f"relocation site is not ADRP: ins=0x{ins:08x}")
            immlo = (ins >> 29) & 0x3
            immhi = (ins >> 5) & 0x7FFFF
            imm21 = (immhi << 2) | immlo
            if imm21 & (1 << 20):
                imm21 -= 1 << 21
            return (pc & ~0xFFF) + (imm21 << 12)

        resolved = {}
        for off, kind, name in relocations:
            target = cstr_va + symbol_offset(name, cstr)
            if kind == "PAGE21":
                ins = struct.unpack_from("<I", text, off)[0]
                actual = decode_adrp_target(ins, text_va + off)
                if actual != (target & ~0xFFF):
                    raise SystemExit(
                        f"ADRP relocation mismatch at text+0x{off:x}: "
                        f"expected page 0x{target & ~0xFFF:x}, got 0x{actual:x}"
                    )
            else:
                ins = struct.unpack_from("<I", text, off)[0]
                if (ins & 0x3B000000) != 0x11000000:
                    raise SystemExit(
                        f"relocation site is not ADD-immediate: ins=0x{ins:08x}"
                    )
                actual_pageoff = (ins >> 10) & 0xFFF
                if actual_pageoff != (target & 0xFFF):
                    raise SystemExit(
                        f"PAGEOFF12 relocation mismatch at text+0x{off:x}: "
                        f"expected 0x{target & 0xfff:x}, got 0x{actual_pageoff:x}"
                    )

        sizeofcmds = 72 + 24 + 24
        header = struct.pack(
            "<IiiIIIII",
            MH_MAGIC_64, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E,
            MH_EXECUTE, 3, sizeofcmds, MH_PIE, 0
        )
        seg_size = 72
        seg_filesize = align(TEXT_FILEOFF + len(text) + len(cstr), PAGE)
        segment = struct.pack(
            "<II16sQQQQiiII",
            LC_SEGMENT_64, seg_size, b"__TEXT\0",
            BASE, seg_filesize, 0, seg_filesize,
            5, 5, 0, 0
        )
        main = struct.pack("<IIQQ", LC_MAIN, 24, TEXT_FILEOFF, 0)
        buildver = struct.pack(
            "<IIIIII", LC_BUILD_VERSION, 24, 2, 18 << 16, 18 << 16, 0
        )
        blob = bytearray(header + segment + main + buildver)
        if len(blob) > TEXT_FILEOFF:
            raise SystemExit("Mach-O load commands exceed reserved first page")
        blob.extend(b"\0" * (TEXT_FILEOFF - len(blob)))
        blob.extend(text)
        blob.extend(cstr)
        blob.extend(b"\0" * (seg_filesize - len(blob)))

        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(blob)
        os.chmod(output, 0o755)

        # Structural verification before signing.
        b = output.read_bytes()
        if b[:4] != bytes.fromhex("cffaedfe"):
            raise SystemExit(f"bad Mach-O magic: {b[:4].hex()}")
        if struct.unpack_from("<I", b, 12)[0] != MH_EXECUTE:
            raise SystemExit("launcher is not MH_EXECUTE")
        if struct.unpack_from("<I", b, 16)[0] != 3:
            raise SystemExit("launcher has unexpected load-command count")
        build_platform = struct.unpack_from("<I", b, 32 + 72 + 24 + 8)[0]
        if build_platform != 2:
            raise SystemExit(f"launcher is not marked as iOS: platform={build_platform}")
        print(f"Darwin launcher created: {output} ({len(b)} bytes, arm64e, iOS)")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--clang", default="clang")
    ap.add_argument("--objcopy", default="llvm-objcopy")
    args = ap.parse_args()
    build(args.source, args.output, args.clang, args.objcopy)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
