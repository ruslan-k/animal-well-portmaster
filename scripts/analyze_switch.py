#!/usr/bin/env python3
"""Inspect extracted Nintendo Switch NSO modules without redistributing game data.

The parser intentionally uses only the Python standard library. It can inspect an
ExeFS directory (rtld/main/subsdk*/sdk) or one NSO file. Compressed NSO segments
use Nintendo's raw LZ4 block format and are decoded locally.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path

SEGMENTS = ("text", "rodata", "data")
ASCII_RE = re.compile(rb"[\x20-\x7e]{4,}")
NVN_RE = re.compile(r"^nvn[A-Za-z0-9_]+$")
GLSLC_RE = re.compile(r"^glslc[A-Za-z0-9_]+$")


def lz4_block(data: bytes, expected_size: int) -> bytes:
    out = bytearray()
    p = 0
    while p < len(data):
        token = data[p]
        p += 1
        lit = token >> 4
        if lit == 15:
            while True:
                if p >= len(data):
                    raise ValueError("truncated LZ4 literal length")
                x = data[p]
                p += 1
                lit += x
                if x != 255:
                    break
        if p + lit > len(data):
            raise ValueError("truncated LZ4 literals")
        out.extend(data[p:p + lit])
        p += lit
        if p == len(data):
            break
        if p + 2 > len(data):
            raise ValueError("truncated LZ4 match offset")
        off = data[p] | (data[p + 1] << 8)
        p += 2
        if off == 0 or off > len(out):
            raise ValueError("invalid LZ4 match offset")
        length = token & 0x0F
        if length == 15:
            while True:
                if p >= len(data):
                    raise ValueError("truncated LZ4 match length")
                x = data[p]
                p += 1
                length += x
                if x != 255:
                    break
        length += 4
        start = len(out) - off
        for i in range(length):
            out.append(out[start + i])
    if len(out) != expected_size:
        raise ValueError(f"LZ4 size mismatch: got {len(out)}, expected {expected_size}")
    return bytes(out)


def strings(blob: bytes) -> set[str]:
    return {m.group().decode("ascii", "replace") for m in ASCII_RE.finditer(blob)}


def parse_nso(path: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) < 0x100 or raw[:4] != b"NSO0":
        raise ValueError(f"{path}: not an NSO0 file")
    flags = struct.unpack_from("<I", raw, 0x0C)[0]
    build_id = raw[0x40:0x60].hex()
    segs = {}
    all_strings: set[str] = set()

    for i, name in enumerate(SEGMENTS):
        off = 0x10 + i * 0x10
        file_off, mem_off, mem_size, extra = struct.unpack_from("<IIII", raw, off)
        stored_size = struct.unpack_from("<I", raw, 0x60 + i * 4)[0]
        compressed = bool(flags & (1 << i))
        hashed = bool(flags & (1 << (i + 3)))
        payload_size = stored_size if compressed else mem_size
        if file_off + payload_size > len(raw):
            raise ValueError(f"{path}: {name} segment extends past EOF")
        payload = raw[file_off:file_off + payload_size]
        decoded = lz4_block(payload, mem_size) if compressed else payload
        digest = hashlib.sha256(decoded).hexdigest()
        expected = raw[0xA0 + i * 0x20:0xC0 + i * 0x20].hex()
        hash_ok = (digest == expected) if hashed else None
        segs[name] = {
            "file_offset": file_off,
            "memory_offset": mem_off,
            "size": mem_size,
            "stored_size": payload_size,
            "extra_or_bss": extra,
            "compressed": compressed,
            "hashed": hashed,
            "sha256": digest,
            "hash_ok": hash_ok,
        }
        all_strings.update(strings(decoded))

    nvn = sorted(s for s in all_strings if NVN_RE.match(s))
    glslc = sorted(s for s in all_strings if GLSLC_RE.match(s))
    return {
        "name": path.name,
        "raw_size": len(raw),
        "raw_sha256": hashlib.sha256(raw).hexdigest(),
        "flags": f"0x{flags:x}",
        "build_id": build_id,
        "segments": segs,
        "nvn_names": nvn,
        "glslc_names": glslc,
    }


def shim_nvn_symbols(path: Path) -> list[str]:
    p = subprocess.run(["nm", "-g", str(path)], check=True, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = set()
    for line in p.stdout.splitlines():
        sym = line.rsplit(None, 1)[-1] if line.split() else ""
        # Bloodstained's game-specific wrappers are cotm_nvnFoo(...).
        if sym.startswith("cotm_nvn"):
            out.add(sym[len("cotm_"):])
    return sorted(out)


def analyze_exefs(path: Path) -> dict:
    names = ["rtld", "main"]
    names.extend(sorted(p.name for p in path.glob("subsdk*") if p.is_file()))
    if (path / "sdk").is_file():
        names.append("sdk")
    modules = []
    for name in names:
        p = path / name
        if p.is_file():
            modules.append(parse_nso(p))
    if not modules:
        raise ValueError(f"{path}: no NSO modules found")
    return {"exefs": str(path), "modules": modules}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="NSO file or extracted ExeFS directory")
    ap.add_argument("--compare-shim", type=Path,
                    help="ELF exporting Bloodstained-style cotm_nvn* wrappers")
    ap.add_argument("--output", type=Path)
    args = ap.parse_args()

    result = analyze_exefs(args.input) if args.input.is_dir() else {"modules": [parse_nso(args.input)]}
    main_mod = next((m for m in result["modules"] if m["name"] == "main"), result["modules"][0])

    if args.compare_shim:
        shim = shim_nvn_symbols(args.compare_shim)
        guest = set(main_mod["nvn_names"])
        covered = sorted(guest.intersection(shim))
        missing = sorted(guest.difference(shim))
        result["shim_comparison"] = {
            "shim": str(args.compare_shim),
            "guest_static_nvn_name_count": len(guest),
            "shim_wrapper_count": len(shim),
            "covered_name_count": len(covered),
            "static_name_surface_coverage_percent": round(100.0 * len(covered) / len(guest), 2) if guest else 0.0,
            "missing_names": missing,
            "warning": "Static string-name surface is an upper bound; it does not prove every entry point is executed.",
        }

    text = json.dumps(result, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
