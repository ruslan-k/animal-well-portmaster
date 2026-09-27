import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("analyze_switch", ROOT / "scripts" / "analyze_switch.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def make_nso(path: Path):
    text = b"AAAA\x00nvnDeviceInitialize\x00"
    ro = b"BBBB\x00glslcCompile\x00nvnQueueInitialize\x00"
    data = b"CCCC\x00"
    blobs = [text, ro, data]
    header = bytearray(0x100)
    header[:4] = b"NSO0"
    struct.pack_into("<I", header, 0x0C, 0)  # uncompressed, unhashed
    header[0x40:0x60] = bytes(range(32))
    pos = 0x100
    body = bytearray()
    mem = 0
    for i, blob in enumerate(blobs):
        extra = 0x1234 if i == 2 else 0x100
        struct.pack_into("<IIII", header, 0x10 + i * 0x10, pos, mem, len(blob), extra)
        struct.pack_into("<I", header, 0x60 + i * 4, len(blob))
        body.extend(blob)
        pos += len(blob)
        mem += 0x1000
    path.write_bytes(bytes(header) + bytes(body))


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
