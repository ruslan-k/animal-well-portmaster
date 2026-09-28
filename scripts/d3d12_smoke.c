#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

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

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "all";
    HMODULE dxgi = NULL, d3d12 = NULL;
    pfn_CreateDXGIFactory1 create_factory = NULL;
    pfn_D3D12CreateDevice create_device = NULL;
    void *factory = NULL, *device = NULL;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("ANIMAL WELL D3D12 bootstrap smoke\n");
    printf("mode=%s\n", mode);
    printf("requested_feature_level=0x%04x (D3D_FEATURE_LEVEL_11_0)\n", 0xb000);

    if (!strcmp(mode, "load-dxgi") || !strcmp(mode, "factory") || !strcmp(mode, "all"))
    {
        puts("STAGE_LOAD_DXGI_BEGIN");
        dxgi = LoadLibraryA("dxgi.dll");
        if (!dxgi)
        {
            printf("STAGE_LOAD_DXGI_FAIL error=%lu\n", (unsigned long)GetLastError());
            return 10;
        }
        puts("STAGE_LOAD_DXGI_PASS");
        if (!strcmp(mode, "load-dxgi"))
        {
            FreeLibrary(dxgi);
            puts("SMOKE_RESULT=PASS_LOAD_DXGI");
            return 0;
        }
    }

    if (!strcmp(mode, "load-d3d12") || !strcmp(mode, "device") || !strcmp(mode, "all"))
    {
        puts("STAGE_LOAD_D3D12_BEGIN");
        d3d12 = LoadLibraryA("d3d12.dll");
        if (!d3d12)
        {
            printf("STAGE_LOAD_D3D12_FAIL error=%lu\n", (unsigned long)GetLastError());
            if (dxgi) FreeLibrary(dxgi);
            return 11;
        }
        puts("STAGE_LOAD_D3D12_PASS");
        if (!strcmp(mode, "load-d3d12"))
        {
            FreeLibrary(d3d12);
            puts("SMOKE_RESULT=PASS_LOAD_D3D12");
            return 0;
        }
    }

    if (!strcmp(mode, "factory") || !strcmp(mode, "all"))
    {
        create_factory = (pfn_CreateDXGIFactory1)(void *)
            GetProcAddress(dxgi, "CreateDXGIFactory1");
        printf("CreateDXGIFactory1=%s\n", create_factory ? "present" : "missing");
        if (!create_factory)
        {
            if (d3d12) FreeLibrary(d3d12);
            if (dxgi) FreeLibrary(dxgi);
            return 12;
        }

        puts("STAGE_DXGI_FACTORY_BEGIN");
        hr = create_factory(&iid_idxgi_factory1, &factory);
        printf("CreateDXGIFactory1 hr=0x%08lx ptr=%p\n",
               (unsigned long)hr, factory);
        if (FAILED(hr) || !factory)
        {
            if (d3d12) FreeLibrary(d3d12);
            if (dxgi) FreeLibrary(dxgi);
            return 13;
        }
        puts("STAGE_DXGI_FACTORY_PASS");

        if (!strcmp(mode, "factory"))
        {
            release_com(factory);
            FreeLibrary(dxgi);
            puts("SMOKE_RESULT=PASS_DXGI_FACTORY");
            return 0;
        }
    }

    if (!strcmp(mode, "device") || !strcmp(mode, "all"))
    {
        create_device = (pfn_D3D12CreateDevice)(void *)
            GetProcAddress(d3d12, "D3D12CreateDevice");
        printf("D3D12CreateDevice=%s\n", create_device ? "present" : "missing");
        if (!create_device)
        {
            if (factory) release_com(factory);
            if (d3d12) FreeLibrary(d3d12);
            if (dxgi) FreeLibrary(dxgi);
            return 12;
        }

        puts("STAGE_D3D12_DEVICE_BEGIN");
        hr = create_device(NULL, 0xb000, &iid_id3d12_device, &device);
        printf("D3D12CreateDevice(NULL, FL11_0) hr=0x%08lx ptr=%p\n",
               (unsigned long)hr, device);
        if (FAILED(hr) || !device)
        {
            if (factory) release_com(factory);
            if (d3d12) FreeLibrary(d3d12);
            if (dxgi) FreeLibrary(dxgi);
            return 14;
        }
        puts("STAGE_D3D12_DEVICE_PASS");

        if (!strcmp(mode, "device"))
        {
            release_com(device);
            FreeLibrary(d3d12);
            puts("SMOKE_RESULT=PASS_D3D12_DEVICE");
            return 0;
        }
    }

    if (device) release_com(device);
    if (factory) release_com(factory);
    if (d3d12) FreeLibrary(d3d12);
    if (dxgi) FreeLibrary(dxgi);
    puts("D3D12 bootstrap smoke: PASS");
    return 0;
}

