#!/usr/bin/env python3
"""Neutralise the debug assert in winevulkan.dll (PE) by patching its import thunk.

Crash evidence: "Assertion failed: !status, file dlls/winevulkan/loader.c, line
668" (vkAllocateCommandBuffers), and the code right after that assert handles the
failure normally (frees the command buffers, returns the result) - so it is a
debug-only guard that this wine build turns into a fatal abort.

winevulkan.dll imports _assert from ucrtbase.dll; objdump reports the import
address table entry at RVA 0x2e39c.  Patch every `jmp qword ptr [rip+disp32]`
thunk whose target is that slot to a `ret` (0xC3 + NOPs).  On win64 the caller
cleans the stack, so `ret` is a valid no-op return.  The original is kept beside
it as .orig; the proper fix belongs in the port's CI wine build (asserts off).

Usage: patch-winevulkan-assert.py <winevulkan.dll> [--apply]
"""
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "runtime/wine/lib/wine/x86_64-windows/winevulkan.dll"
apply_ = "--apply" in sys.argv
data = bytearray(open(path, "rb").read())
orig = bytes(data)

pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe:pe + 4] == b"PE\0\0", "not a PE file"
num_sections = struct.unpack_from("<H", data, pe + 6)[0]
opt_size = struct.unpack_from("<H", data, pe + 20)[0]
base = pe + 24 + opt_size

sections = []
for i in range(num_sections):
    o = base + i * 40
    name = data[o:o + 8].rstrip(b"\0").decode(errors="replace")
    vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, o + 8)
    sections.append((name, vaddr, vsize, rawptr, rawsize))
print("sections:", [(s[0], hex(s[1]), hex(s[3])) for s in sections])


def off_to_rva(off):
    for name, vaddr, vsize, rawptr, rawsize in sections:
        if rawptr and rawptr <= off < rawptr + rawsize:
            return vaddr + (off - rawptr)
    return None


IAT_RVA = 0x2e39c
hits = []
blob = bytes(data)
for i in range(len(blob) - 6):
    if blob[i] == 0xFF and blob[i + 1] == 0x25:
        disp = struct.unpack_from("<i", blob, i + 2)[0]
        rva = off_to_rva(i)
        if rva is None:
            continue
        if rva + 6 + disp == IAT_RVA:
            hits.append(i)
print("thunks targeting _assert IAT %#x: %d" % (IAT_RVA, len(hits)))
for off in hits:
    print("  off=%#x rva=%#x bytes=%s" % (off, off_to_rva(off), blob[off:off + 6].hex()))

if not apply_:
    print("dry run (pass --apply to patch)")
    sys.exit(0)
if not hits:
    print("nothing to patch")
    sys.exit(1)
open(path + ".orig", "wb").write(orig)
for off in hits:
    data[off] = 0xC3
    for k in range(1, 6):
        data[off + k] = 0x90
open(path, "wb").write(bytes(data))
print("patched %d thunk(s); original kept at %s.orig" % (len(hits), path))
