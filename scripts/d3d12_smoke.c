#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <dxgi1_4.h>
#include <d3d12.h>
static LRESULT CALLBACK wp(HWND h,UINT m,WPARAM w,LPARAM l){return DefWindowProcA(h,m,w,l);}
int main(void){HRESULT hr; IDXGIFactory4*f=0; IDXGIAdapter1*a=0; ID3D12Device*d=0; ID3D12CommandQueue*q=0; IDXGISwapChain*s=0;
 hr=CreateDXGIFactory1(&IID_IDXGIFactory4,(void**)&f); printf("CreateDXGIFactory1=0x%08lx\n",(unsigned long)hr); if(FAILED(hr))return 10;
 for(UINT i=0;IDXGIFactory4_EnumAdapters1(f,i,&a)!=DXGI_ERROR_NOT_FOUND;i++){DXGI_ADAPTER_DESC1 ad; IDXGIAdapter1_GetDesc1(a,&ad); printf("adapter[%u] vendor=%04x device=%04x flags=%x\n",i,ad.VendorId,ad.DeviceId,ad.Flags); hr=D3D12CreateDevice((IUnknown*)a,D3D_FEATURE_LEVEL_11_0,&IID_ID3D12Device,(void**)&d); printf("D3D12CreateDevice FL11_0=0x%08lx\n",(unsigned long)hr); if(SUCCEEDED(hr))break; IDXGIAdapter1_Release(a);a=0;}
 if(!d){hr=D3D12CreateDevice(0,D3D_FEATURE_LEVEL_11_0,&IID_ID3D12Device,(void**)&d);printf("D3D12CreateDevice(NULL)=0x%08lx\n",(unsigned long)hr);} if(FAILED(hr)||!d)return 11;
 D3D12_COMMAND_QUEUE_DESC qd={0};qd.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;hr=ID3D12Device_CreateCommandQueue(d,&qd,&IID_ID3D12CommandQueue,(void**)&q);printf("CreateCommandQueue=0x%08lx\n",(unsigned long)hr);if(FAILED(hr))return 12;
 HINSTANCE hi=GetModuleHandleA(0);WNDCLASSA wc={0};wc.lpfnWndProc=wp;wc.hInstance=hi;wc.lpszClassName="AWD3D12Smoke";RegisterClassA(&wc);HWND h=CreateWindowA(wc.lpszClassName,"AW smoke",WS_OVERLAPPEDWINDOW,0,0,64,64,0,0,hi,0);if(!h)return 13;
 DXGI_SWAP_CHAIN_DESC sd={0};sd.BufferDesc.Width=64;sd.BufferDesc.Height=64;sd.BufferDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;sd.SampleDesc.Count=1;sd.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;sd.BufferCount=2;sd.OutputWindow=h;sd.Windowed=TRUE;sd.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
 hr=IDXGIFactory4_CreateSwapChain(f,(IUnknown*)q,&sd,&s);printf("CreateSwapChain=0x%08lx\n",(unsigned long)hr);if(FAILED(hr))return 14;hr=IDXGISwapChain_Present(s,0,0);printf("Present=0x%08lx\n",(unsigned long)hr);
 IDXGISwapChain_Release(s);DestroyWindow(h);ID3D12CommandQueue_Release(q);ID3D12Device_Release(d);if(a)IDXGIAdapter1_Release(a);IDXGIFactory4_Release(f);return FAILED(hr)?15:0;}
