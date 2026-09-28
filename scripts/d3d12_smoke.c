#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/*
 * Header-independent D3D12/DXGI bootstrap probe.
 *
 * Ubuntu 20.04's MinGW headers predate d3d12.h.  Keeping this probe independent
 * of the SDK is useful in its own right: it tests the exact dynamic exports the
 * game needs without importing a host build-time D3D implementation.
 */

typedef HRESULT (WINAPI *pfn_CreateDXGIFactory1)(REFIID riid, void **factory);
typedef HRESULT (WINAPI *pfn_D3D12CreateDevice)(void *adapter,
                                                UINT minimum_feature_level,
                                                REFIID riid,
                                                void **device);

static const GUID iid_idxgi_factory1 =
    {0x770aae78,0xf26f,0x4dba,{0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87}};
static const GUID iid_id3d12_device =
    {0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};

static void release_com(void *object)
{
    typedef ULONG (STDMETHODCALLTYPE *release_fn)(void *);
    void **vtbl;
    if (!object)
        return;
    vtbl = *(void ***)object;
    if (vtbl && vtbl[2])
        ((release_fn)vtbl[2])(object);
}

int main(void)
{
    HMODULE dxgi = NULL, d3d12 = NULL;
    pfn_CreateDXGIFactory1 create_factory;
    pfn_D3D12CreateDevice create_device;
    void *factory = NULL, *device = NULL;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("ANIMAL WELL D3D12 bootstrap smoke\n");
    printf("requested_feature_level=0x%04x (D3D_FEATURE_LEVEL_11_0)\n", 0xb000);

    dxgi = LoadLibraryA("dxgi.dll");
    if (!dxgi) {
        printf("LoadLibrary(dxgi.dll) failed=%lu\n", (unsigned long)GetLastError());
        return 10;
    }
    d3d12 = LoadLibraryA("d3d12.dll");
    if (!d3d12) {
        printf("LoadLibrary(d3d12.dll) failed=%lu\n", (unsigned long)GetLastError());
        FreeLibrary(dxgi);
        return 11;
    }

    create_factory = (pfn_CreateDXGIFactory1)(void *)
        GetProcAddress(dxgi, "CreateDXGIFactory1");
    create_device = (pfn_D3D12CreateDevice)(void *)
        GetProcAddress(d3d12, "D3D12CreateDevice");
    printf("CreateDXGIFactory1=%s\n", create_factory ? "present" : "missing");
    printf("D3D12CreateDevice=%s\n", create_device ? "present" : "missing");
    if (!create_factory || !create_device) {
        FreeLibrary(d3d12);
        FreeLibrary(dxgi);
        return 12;
    }

    puts("STAGE_DXGI_FACTORY_BEGIN");
    hr = create_factory(&iid_idxgi_factory1, &factory);
    printf("CreateDXGIFactory1 hr=0x%08lx ptr=%p\n",
           (unsigned long)hr, factory);
    if (FAILED(hr) || !factory) {
        FreeLibrary(d3d12);
        FreeLibrary(dxgi);
        return 13;
    }

    puts("STAGE_DXGI_FACTORY_PASS");
    puts("STAGE_D3D12_DEVICE_BEGIN");
    hr = create_device(NULL, 0xb000, &iid_id3d12_device, &device);
    printf("D3D12CreateDevice(NULL, FL11_0) hr=0x%08lx ptr=%p\n",
           (unsigned long)hr, device);
    if (FAILED(hr) || !device) {
        release_com(factory);
        FreeLibrary(d3d12);
        FreeLibrary(dxgi);
        return 14;
    }

    puts("STAGE_D3D12_DEVICE_PASS");
    release_com(device);
    release_com(factory);
    FreeLibrary(d3d12);
    FreeLibrary(dxgi);
    puts("D3D12 bootstrap smoke: PASS");
    return 0;
}
