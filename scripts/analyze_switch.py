#!/usr/bin/env python3
"""Inspect extracted Nintendo Switch NSO modules without redistributing game data.

The parser intentionally uses only the Python standard library. It can inspect an
ExeFS directory (rtld/main/subsdk*/sdk) or one NSO file. Compressed NSO segments
use Nintendo's raw LZ4 block format and are decoded locally.

For ordinary SDK-built NSOs it also follows the MOD0 dynamic table and reports
the actual undefined dynamic-symbol contract. This is much stronger evidence
than merely grepping printable strings.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
from collections import Counter
from pathlib import Path

SEGMENTS = ("text", "rodata", "data")
ASCII_RE = re.compile(rb"[\x20-\x7e]{4,}")
NVN_RE = re.compile(r"^nvn[A-Za-z0-9_]+$")
GLSLC_RE = re.compile(r"^glslc[A-Za-z0-9_]+$")

DT_NULL = 0
DT_PLTRELSZ = 2
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_RELA = 7
DT_RELASZ = 8
DT_RELAENT = 9
DT_STRSZ = 10
DT_SYMENT = 11
DT_REL = 17
DT_RELSZ = 18
DT_RELENT = 19
DT_PLTREL = 20
DT_JMPREL = 23


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


def _read_virtual(decoded_segments: list[tuple[str, int, bytes, int]],
                  va: int, size: int) -> bytes:
    if size < 0:
        raise ValueError("negative virtual read")
    for name, base, blob, extra in decoded_segments:
        end = base + len(blob)
        if base <= va and va + size <= end:
            return blob[va - base:va - base + size]
        if name == "data":
            bss_end = end + extra
            if end <= va and va + size <= bss_end:
                return b"\0" * size
    raise ValueError(f"virtual read 0x{va:x}+0x{size:x} is outside decoded segments")


def _cstring(blob: bytes, offset: int) -> str:
    if not 0 <= offset < len(blob):
        return ""
    end = blob.find(b"\0", offset)
    if end < 0:
        end = len(blob)
    return blob[offset:end].decode("utf-8", "replace")


def _nn_namespace(symbol: str) -> str | None:
    if not symbol.startswith("_ZN2nn"):
        return None
    rest = symbol[len("_ZN2nn"):]
    m = re.match(r"([0-9]+)", rest)
    if not m:
        return None
    length = int(m.group(1))
    name = rest[len(m.group(1)):len(m.group(1)) + length]
    return name if len(name) == length else None


def _max_relocation_symbol(decoded_segments, tags: dict[int, int]) -> int:
    maximum = -1

    def scan_rela(va: int, size: int, ent: int) -> None:
        nonlocal maximum
        if not va or not size:
            return
        ent = ent or 24
        if ent < 16 or size % ent:
            raise ValueError("invalid RELA table geometry")
        for off in range(0, size, ent):
            row = _read_virtual(decoded_segments, va + off, ent)
            r_info = struct.unpack_from("<Q", row, 8)[0]
            maximum = max(maximum, r_info >> 32)

    def scan_rel(va: int, size: int, ent: int) -> None:
        nonlocal maximum
        if not va or not size:
            return
        ent = ent or 16
        if ent < 16 or size % ent:
            raise ValueError("invalid REL table geometry")
        for off in range(0, size, ent):
            row = _read_virtual(decoded_segments, va + off, ent)
            r_info = struct.unpack_from("<Q", row, 8)[0]
            maximum = max(maximum, r_info >> 32)

    scan_rela(tags.get(DT_RELA, 0), tags.get(DT_RELASZ, 0), tags.get(DT_RELAENT, 0))
    scan_rel(tags.get(DT_REL, 0), tags.get(DT_RELSZ, 0), tags.get(DT_RELENT, 0))

    if tags.get(DT_JMPREL) and tags.get(DT_PLTRELSZ):
        if tags.get(DT_PLTREL) == DT_RELA:
            scan_rela(tags[DT_JMPREL], tags[DT_PLTRELSZ], tags.get(DT_RELAENT, 0))
        elif tags.get(DT_PLTREL) == DT_REL:
            scan_rel(tags[DT_JMPREL], tags[DT_PLTRELSZ], tags.get(DT_RELENT, 0))
    return maximum


def parse_mod0_dynamic(decoded_segments: list[tuple[str, int, bytes, int]]) -> dict | None:
    candidates: list[tuple[int, str, int]] = []
    for name, base, blob, _extra in decoded_segments:
        start = 0
        while True:
            idx = blob.find(b"MOD0", start)
            if idx < 0:
                break
            candidates.append((base + idx, name, idx))
            start = idx + 4

    for mod0_va, seg_name, seg_off in candidates:
        try:
            header = _read_virtual(decoded_segments, mod0_va, 28)
            magic, dynamic_rel, bss_start_rel, bss_end_rel, eh_start_rel, eh_end_rel, module_rel = \
                struct.unpack("<4s6I", header)
            if magic != b"MOD0":
                continue
            dynamic_va = mod0_va + dynamic_rel

            entries: list[tuple[int, int]] = []
            for i in range(512):
                tag, value = struct.unpack(
                    "<QQ", _read_virtual(decoded_segments, dynamic_va + i * 16, 16))
                entries.append((tag, value))
                if tag == DT_NULL:
                    break
            else:
                raise ValueError("unterminated MOD0 dynamic table")
            tags = {tag: value for tag, value in entries if tag != DT_NULL}

            if not all(k in tags for k in (DT_STRTAB, DT_SYMTAB, DT_STRSZ, DT_SYMENT)):
                raise ValueError("MOD0 dynamic table has no complete dynstr/dynsym contract")
            if tags[DT_SYMENT] < 24:
                raise ValueError("unexpected ELF64 symbol entry size")

            symbol_count = None
            if DT_HASH in tags:
                nbucket, nchain = struct.unpack(
                    "<II", _read_virtual(decoded_segments, tags[DT_HASH], 8))
                if nbucket > 1_000_000 or nchain > 1_000_000:
                    raise ValueError("implausible SysV hash dimensions")
                symbol_count = nchain
            else:
                max_sym = _max_relocation_symbol(decoded_segments, tags)
                if max_sym >= 0:
                    symbol_count = max_sym + 1

            if symbol_count is None:
                raise ValueError("cannot derive dynamic symbol count")
            strtab = _read_virtual(decoded_segments, tags[DT_STRTAB], tags[DT_STRSZ])

            undefined: list[str] = []
            defined: list[str] = []
            for i in range(symbol_count):
                row = _read_virtual(
                    decoded_segments, tags[DT_SYMTAB] + i * tags[DT_SYMENT], 24)
                st_name, st_info, st_other, st_shndx, st_value, st_size = \
                    struct.unpack("<IBBHQQ", row)
                del st_info, st_other, st_value, st_size
                name = _cstring(strtab, st_name)
                if not name:
                    continue
                if st_shndx == 0:
                    undefined.append(name)
                else:
                    defined.append(name)

            undefined = sorted(set(undefined))
            defined = sorted(set(defined))
            nn_imports = [s for s in undefined if s.startswith("_ZN2nn")]
            namespace_counts = Counter(
                ns for ns in (_nn_namespace(s) for s in nn_imports) if ns)
            direct_graphics = [
                s for s in undefined
                if s == "nvnBootstrapLoader" or s.startswith("glslc")
            ]
            other_imports = [
                s for s in undefined if s not in nn_imports and s not in direct_graphics
            ]

            return {
                "mod0_segment": seg_name,
                "mod0_virtual_address": mod0_va,
                "dynamic_virtual_address": dynamic_va,
                "bss_start_virtual_address": mod0_va + bss_start_rel,
                "bss_end_virtual_address": mod0_va + bss_end_rel,
                "eh_frame_hdr_start_virtual_address": mod0_va + eh_start_rel,
                "eh_frame_hdr_end_virtual_address": mod0_va + eh_end_rel,
                "module_object_virtual_address": mod0_va + module_rel,
                "dynamic_symbol_count": symbol_count,
                "dynamic_import_count": len(undefined),
                "dynamic_export_count": len(defined),
                "dynamic_imports": undefined,
                "nn_import_count": len(nn_imports),
                "nn_namespace_counts": dict(sorted(namespace_counts.items())),
                "nn_imports": nn_imports,
                "direct_graphics_imports": direct_graphics,
                "other_imports": other_imports,
            }
        except (ValueError, struct.error):
            # Printable "MOD0" can theoretically occur in arbitrary data. Try
            # another candidate rather than turning a false positive into a
            # hard parser failure.
            continue
    return None


def parse_nso(path: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) < 0x100 or raw[:4] != b"NSO0":
        raise ValueError(f"{path}: not an NSO0 file")
    flags = struct.unpack_from("<I", raw, 0x0C)[0]
    build_id = raw[0x40:0x60].hex()
    segs = {}
    decoded_segments: list[tuple[str, int, bytes, int]] = []
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
        decoded_segments.append((name, mem_off, decoded, extra if name == "data" else 0))
        all_strings.update(strings(decoded))

    nvn = sorted(s for s in all_strings if NVN_RE.match(s))
    glslc = sorted(s for s in all_strings if GLSLC_RE.match(s))
    result = {
        "name": path.name,
        "raw_size": len(raw),
        "raw_sha256": hashlib.sha256(raw).hexdigest(),
        "flags": f"0x{flags:x}",
        "build_id": build_id,
        "segments": segs,
        "nvn_names": nvn,
        "glslc_names": glslc,
    }
    dynamic = parse_mod0_dynamic(decoded_segments)
    if dynamic:
        result["dynamic"] = dynamic
    return result


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
