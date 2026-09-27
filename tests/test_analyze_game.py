import importlib.util, struct, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('analyze_game',ROOT/'scripts'/'analyze_game.py'); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def dxbc(stage=0,major=5,minor=0):
 t=(stage<<16)|(major<<4)|minor; chunk=b'SHEX'+struct.pack('<I',4)+struct.pack('<I',t); total=36+len(chunk)
 return b'DXBC'+b'\0'*16+struct.pack('<III',1,total,1)+struct.pack('<I',36)+chunk
class T(unittest.TestCase):
 def test_ps5(self): self.assertEqual(mod.scan_dxbc(dxbc())[0],{'stage':'pixel','major':5,'minor':0})
 def test_vs5(self): self.assertEqual(mod.scan_dxbc(dxbc(1))[0]['stage'],'vertex')
 def test_fake(self): self.assertEqual(mod.scan_dxbc(b'DXBC'+b'\0'*20),[])
if __name__=='__main__': unittest.main()
