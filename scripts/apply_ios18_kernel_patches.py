#!/usr/bin/env python3
"""Apply only the proven minimal iOS 18 A12/A13 kernel patch set."""
from __future__ import annotations
import importlib.util, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
kpf_path = root / ".local" / "patch" / "kernel_patchfinder.py"
if not kpf_path.is_file():
    raise SystemExit(f"missing kernel patchfinder: {kpf_path}")
spec = importlib.util.spec_from_file_location("bunny_kpf", kpf_path)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load kernel_patchfinder.py")
kpf = importlib.util.module_from_spec(spec)
sys.modules["bunny_kpf"] = kpf
spec.loader.exec_module(kpf)

def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} STOCK OUTPUT")
    src, dst = map(Path, sys.argv[1:])
    original = src.read_bytes()
    pf = kpf.KernelPatchfinder(original, verbose=True)
    results = pf.find_all()
    for name in ("PE_i_can_has_debugger", "AMFIIsCDHashInTrustCache"):
        if name not in results:
            raise SystemExit(f"required iOS 18 kernel target missing: {name}")

    edits = []
    def emit(off, new, label):
        old = bytes(pf.data[off:off+4])
        if old == new:
            raise SystemExit(f"{label}: already patched at 0x{off:x}")
        pf.emit(off, new, label)
        edits.append((off, old, new))

    off = results["PE_i_can_has_debugger"]
    emit(off, kpf.p32(kpf.MOV_W0_1_U32), "PE_i_can_has_debugger -> MOV W0,#1")
    emit(off + 4, kpf.p32(kpf.RETAB_U32), "PE_i_can_has_debugger -> RETAB")

    off = results["AMFIIsCDHashInTrustCache"]
    emit(off,      kpf.p32(kpf.MOV_X0_1_U32),  "AMFI trustcache -> MOV X0,#1")
    emit(off + 4,  kpf.p32(kpf.CBZ_X2_8_U32),  "AMFI trustcache -> CBZ X2,+8")
    emit(off + 8,  kpf.p32(kpf.STR_X0_X2_U32), "AMFI trustcache -> STR X0,[X2]")
    emit(off + 12, kpf.p32(kpf.RET_U32),       "AMFI trustcache -> RET")

    patched = bytes(pf.data)
    delta = sum(a != b for a, b in zip(original, patched))
    # Six instruction sites are the invariant. The number of changed bytes is
    # not necessarily 24 because an encoded ARM64 instruction may legitimately
    # retain one or more bytes from the original encoding.
    if len(edits) != 6 or not (0 < delta <= 24):
        raise SystemExit(
            f"minimal iOS 18 patch invariant failed: edits={len(edits)} byte_delta={delta}"
        )

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(patched)
    print(
        f"iOS 18 minimal kernel patch set: 6 instructions, byte_delta={delta}"
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
