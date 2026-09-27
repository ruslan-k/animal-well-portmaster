import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("analyze_switch", ROOT / "scripts" / "analyze_switch.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def write_nso(path: Path, blobs, mem_offsets=None):
    if mem_offsets is None:
        mem_offsets = [0, 0x1000, 0x2000]
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    struct.pack_into("<I", header, 0x0C, 0)  # uncompressed, unhashed
    header[0x40:0x60] = bytes(range(32))
    pos = 0x100
    body = bytearray()
    for i, blob in enumerate(blobs):
        extra = 0x1234 if i == 2 else 0x100
        struct.pack_into("<IIII", header, 0x10 + i * 0x10,
                         pos, mem_offsets[i], len(blob), extra)
        struct.pack_into("<I", header, 0x60 + i * 4, len(blob))
        body.extend(blob)
        pos += len(blob)
    path.write_bytes(bytes(header) + bytes(body))


def make_nso(path: Path):
    text = b"AAAA\x00nvnDeviceInitialize\x00"
    ro = b"BBBB\x00glslcCompile\x00nvnQueueInitialize\x00"
    data = b"CCCC\x00"
    write_nso(path, [text, ro, data], [0, 0x1000, 0x2000])


def make_dynamic_nso(path: Path):
    text = bytearray(0x100)
    ro = bytearray(0x800)
    data = bytearray(0x200)
    text[:4] = b"TEXT"

    mod0_va = 0x1000 + 0x20
    dynamic_va = 0x2000
    struct.pack_into("<4s6I", ro, 0x20, b"MOD0",
                     dynamic_va - mod0_va, 0x1200, 0x1400, 0, 0, 0x1500)

    hash_va = 0x1100
    symtab_va = 0x1140
    strtab_va = 0x1200
    strtab = b"\0nvnBootstrapLoader\0_ZN2nn3hid14InitializeNpadEv\0"
    ro[strtab_va - 0x1000:strtab_va - 0x1000 + len(strtab)] = strtab

    # SysV hash: one bucket, three symbol-chain entries.
    struct.pack_into("<II", ro, hash_va - 0x1000, 1, 3)
    struct.pack_into("<I", ro, hash_va - 0x1000 + 8, 1)
    struct.pack_into("<III", ro, hash_va - 0x1000 + 12, 0, 2, 0)

    # ELF64 symbols: null + two strong undefined functions.
    off_nvn = 1
    off_hid = strtab.index(b"_ZN2nn")
    struct.pack_into("<IBBHQQ", ro, symtab_va - 0x1000 + 24,
                     off_nvn, 0x12, 0, 0, 0, 0)
    struct.pack_into("<IBBHQQ", ro, symtab_va - 0x1000 + 48,
                     off_hid, 0x12, 0, 0, 0, 0)

    entries = [
        (mod.DT_HASH, hash_va),
        (mod.DT_SYMTAB, symtab_va),
        (mod.DT_SYMENT, 24),
        (mod.DT_STRTAB, strtab_va),
        (mod.DT_STRSZ, len(strtab)),
        (mod.DT_NULL, 0),
    ]
    for i, (tag, value) in enumerate(entries):
        struct.pack_into("<QQ", data, i * 16, tag, value)

    write_nso(path, [bytes(text), bytes(ro), bytes(data)],
              [0, 0x1000, 0x2000])


class SwitchAnalyzerTests(unittest.TestCase):
    def test_parse_uncompressed_nso(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "main"
            make_nso(p)
            r = mod.parse_nso(p)
            self.assertEqual(r["name"], "main")
            self.assertEqual(r["build_id"], bytes(range(32)).hex())
            self.assertIn("nvnDeviceInitialize", r["nvn_names"])
            self.assertIn("nvnQueueInitialize", r["nvn_names"])
            self.assertEqual(r["glslc_names"], ["glslcCompile"])
            self.assertEqual(r["segments"]["data"]["extra_or_bss"], 0x1234)
            self.assertNotIn("dynamic", r)

    def test_parse_mod0_dynamic_imports(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "main"
            make_dynamic_nso(p)
            r = mod.parse_nso(p)
            dyn = r["dynamic"]
            self.assertEqual(dyn["dynamic_symbol_count"], 3)
            self.assertEqual(dyn["dynamic_import_count"], 2)
            self.assertEqual(dyn["nn_import_count"], 1)
            self.assertEqual(dyn["nn_namespace_counts"], {"hid": 1})
            self.assertEqual(dyn["direct_graphics_imports"], ["nvnBootstrapLoader"])
            self.assertIn("_ZN2nn3hid14InitializeNpadEv", dyn["dynamic_imports"])

    def test_lz4_literal_only_block(self):
        payload = b"hello"
        packed = bytes([len(payload) << 4]) + payload
        self.assertEqual(mod.lz4_block(packed, len(payload)), payload)

    def test_bad_magic(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bad"
            p.write_bytes(b"not-an-nso")
            with self.assertRaises(ValueError):
                mod.parse_nso(p)


if __name__ == "__main__":
    unittest.main()
