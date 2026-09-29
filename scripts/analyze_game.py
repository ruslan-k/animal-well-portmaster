#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, struct
from pathlib import Path
STAGES={0:'pixel',1:'vertex',2:'geometry',3:'hull',4:'domain',5:'compute'}
def u16(d,o): return struct.unpack_from('<H',d,o)[0]
def u32(d,o): return struct.unpack_from('<I',d,o)[0]
def rva2off(d,pe,rva):
 c=pe+4; n=u16(d,c+2); osz=u16(d,c+16); s=c+20+osz
 for i in range(n):
  o=s+i*40; vs,va,rs,rp=u32(d,o+8),u32(d,o+12),u32(d,o+16),u32(d,o+20)
  if va<=rva<va+max(vs,rs): return rp+rva-va
 return None
def cstr(d,o):
 if o is None or o>=len(d): return ''
 e=d.find(b'\0',o); e=len(d) if e<0 else e
 return d[o:e].decode('ascii','replace')
def parse_pe(d):
 if d[:2]!=b'MZ': raise ValueError('not MZ')
 pe=u32(d,0x3c)
 if d[pe:pe+4]!=b'PE\0\0': raise ValueError('bad PE')
 c=pe+4; machine=u16(d,c); n=u16(d,c+2); opt=c+20
 if u16(d,opt)!=0x20b: raise ValueError('not PE32+')
 rr=u32(d,opt+120); sz=u32(d,opt+124); off=rva2off(d,pe,rr) if rr else None; imports=[]
 if off is not None:
  for i in range(0,sz or 0x10000,20):
   o=off+i
   if o+20>len(d): break
   oft,ts,fwd,nrva,ft=struct.unpack_from('<IIIII',d,o)
   if not any((oft,ts,fwd,nrva,ft)): break
   imports.append(cstr(d,rva2off(d,pe,nrva)))
 return {'machine':machine,'machine_name':'x86_64' if machine==0x8664 else hex(machine),'sections':n,'imports':imports}
def scan_dxbc(d):
 out=[]; pos=0
 while True:
  b=d.find(b'DXBC',pos)
  if b<0: break
  pos=b+4
  if b+32>len(d): continue
  total,count=u32(d,b+24),u32(d,b+28)
  if not count or count>128 or total<32+4*count or b+total>len(d): continue
  offs=struct.unpack_from('<'+'I'*count,d,b+32); shader=None; ok=True
  for off in offs:
   if off+8>total: ok=False; break
   tag=d[b+off:b+off+4]; size=u32(d,b+off+4)
   if off+8+size>total: ok=False; break
   if tag in (b'SHDR',b'SHEX') and size>=4:
    t=u32(d,b+off+8); shader={'stage':STAGES.get((t>>16)&0xffff,'other'),'major':(t>>4)&15,'minor':t&15}
  if ok: out.append(shader)
 return out
def analyze(path):
 d=path.read_bytes(); shaders=scan_dxbc(d); sc={}
 for s in shaders:
  if s:
   k=f"{s['stage']}_sm{s['major']}_{s['minor']}"; sc[k]=sc.get(k,0)+1
 return {'sha256':hashlib.sha256(d).hexdigest(),'size':len(d),'pe':parse_pe(d),'dxbc_containers':len(shaders),'dxil_signature_count':d.count(b'DXIL'),'shader_counts':sc,'markers':{'directx12_required':b'DirectX 12 Required.' in d,'d3d12_serialize_root_signature':b'D3D12SerializeRootSignature' in d,'create_dxgi_factory1':b'CreateDXGIFactory1' in d}}
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('exe',type=Path); ap.add_argument('--json',action='store_true'); a=ap.parse_args(); r=analyze(a.exe)
 print(json.dumps(r,indent=2,sort_keys=True) if a.json else json.dumps(r,sort_keys=True)); return 0
if __name__=='__main__': raise SystemExit(main())
