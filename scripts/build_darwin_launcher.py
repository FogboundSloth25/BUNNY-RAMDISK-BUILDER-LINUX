#!/usr/bin/env python3
"""Build a native Darwin arm64 Mach-O restored_external launcher on Linux.

The source is assembled for the Darwin arm64 ABI and then linked by LLVM's
Mach-O linker (ld64.lld). We do not hand-write a Mach-O header: that would be
too easy to get subtly wrong for XNU/ldid.
"""
from __future__ import annotations
import argparse
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
MH_EXECUTE = 2
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2

def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)

def find_ld64(explicit: str | None) -> str:
    if explicit:
        return explicit
    for name in ("ld64.lld", "ld.lld"):
        path = shutil.which(name)
        if path:
            return path
    raise SystemExit("Darwin Mach-O linker not found; install LLVM LLD (ld64.lld/ld.lld)")

def parse_macho(path: Path) -> tuple[int, int, int, int, bool]:
    data = path.read_bytes()
    if len(data) < 32 or data[:4] != bytes.fromhex("cffaedfe"):
        raise SystemExit(f"not a 64-bit little-endian Mach-O: {path}")
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, 0)
    if cputype != CPU_TYPE_ARM64:
        raise SystemExit(f"launcher cputype is 0x{cputype & 0xffffffff:08x}, expected ARM64 0x0100000c")
    subtype = cpusubtype & 0xffffffff
    if subtype not in (CPU_SUBTYPE_ARM64_ALL, 2):
        raise SystemExit(f"unsupported ARM64 subtype: {subtype}")
    if filetype != MH_EXECUTE:
        raise SystemExit(f"launcher filetype is {filetype}, expected MH_EXECUTE=2")
    cursor = 32
    if cursor + sizeofcmds > len(data):
        raise SystemExit("Mach-O load commands exceed file")
    found_ios = False
    entryoff = None
    for _ in range(ncmds):
        if cursor + 8 > len(data):
            raise SystemExit("truncated Mach-O load command")
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > len(data):
            raise SystemExit("invalid Mach-O load command size")
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform, minos, sdk, ntools = struct.unpack_from("<IIII", data, cursor + 8)
            if platform == PLATFORM_IOS:
                found_ios = True
        if cmd == 0x80000028 and cmdsize >= 24:
            entryoff = struct.unpack_from("<Q", data, cursor + 8)[0]
        cursor += cmdsize
    if not found_ios:
        raise SystemExit("launcher has no LC_BUILD_VERSION platform=iOS")
    if entryoff is None:
        raise SystemExit("launcher has no LC_MAIN entry point")
    if entryoff >= len(data):
        raise SystemExit(f"LC_MAIN entryoff 0x{entryoff:x} outside file")
    return cputype, subtype, filetype, entryoff, found_ios

def verify_source_strings(source: Path) -> None:
    text = source.read_text(encoding="utf-8")
    if '.asciz "VALIDITY IS THE BEST\\n"' not in text:
        raise SystemExit("banner must be emitted as a null-terminated Darwin cstring")
    if '.asciz "EXECVE FAILED\\n"' not in text:
        raise SystemExit("exec failure string must be emitted as a null-terminated Darwin cstring")
    if '.ascii "VALIDITY IS THE BEST\\n"' in text or '.ascii "EXECVE FAILED\\n"' in text:
        raise SystemExit("non-null-terminated __cstring literal remains")
    print("Darwin cstring termination check: ✅")

def verify_source_syscalls(source: Path) -> None:
    text = source.read_text(encoding="utf-8")
    required = [
        "movk x16, #0x2000, lsl #16",
    ]
    for line in required:
        if line not in text:
            raise SystemExit(f"Darwin syscall namespace marker missing: {line}")
    forbidden = [
        "movk x16, #0x200, lsl #16",
    ]
    for line in forbidden:
        if line in text:
            raise SystemExit(f"invalid Darwin syscall namespace still present: {line}")
    print("Darwin syscall ABI source check: 0x20000000 namespace ✅")

def build(source: Path, output: Path, clang: str, linker: str | None) -> None:
    verify_source_strings(source)
    verify_source_syscalls(source)
    ld = find_ld64(linker)
    flavor = []
    if Path(ld).name == "ld.lld":
        flavor = ["-flavor", "darwin"]
    with tempfile.TemporaryDirectory(prefix="bunny-darwin-launcher-") as td:
        obj = Path(td) / "restored_external.o"
        run([
            clang, "--target=arm64-apple-ios18.0", "-c", "-O2",
            "-o", str(obj), str(source),
        ])
        run([
            ld, *flavor, "-arch", "arm64",
            "-platform_version", "ios", "18.0", "18.0",
            "-e", "_start", "-execute",
            "-o", str(output), str(obj),
        ])
    os.chmod(output, 0o755)
    cputype, subtype, filetype, entryoff, ios = parse_macho(output)
    print(
        f"Darwin launcher created: {output} ({output.stat().st_size} bytes, "
        f"arm64 subtype={subtype}, iOS, entryoff=0x{entryoff:x})"
    )

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--clang", default="clang")
    ap.add_argument("--ld", default=None)
    args = ap.parse_args()
    build(args.source, args.output, args.clang, args.ld)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())