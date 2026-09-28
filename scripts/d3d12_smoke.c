#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

/*
 * Header-independent D3D12/DXGI bootstrap probe.
 *
 * Ubuntu 20.04's MinGW headers predate d3d12.h. Keeping this probe independent
 * of the SDK lets us test the exact dynamic exports and Wine display/KMT path
 * without importing a host build-time D3D implementation.
 */

typedef HRESULT (WINAPI *pfn_CreateDXGIFactory1)(REFIID riid, void **factory);
typedef HRESULT (WINAPI *pfn_D3D12CreateDevice)(void *adapter,
                                                UINT minimum_feature_level,
                                                REFIID riid,
                                                void **device);

/* Minimal private copies of the WDDM structs used by Wine's wined3d adapter
 * discovery. Function entry points are resolved dynamically from gdi32.dll. */
typedef struct
{
    WCHAR DeviceName[32];
    UINT hAdapter;
    LUID AdapterLuid;
    UINT VidPnSourceId;
} aw_d3dkmt_open_adapter_from_gdi_display_name;

typedef struct
{
    LUID AdapterLuid;
    UINT hAdapter;
} aw_d3dkmt_open_adapter_from_luid;

typedef struct
{
    UINT hAdapter;
} aw_d3dkmt_close_adapter;

typedef LONG (WINAPI *pfn_D3DKMTOpenAdapterFromGdiDisplayName)(
        aw_d3dkmt_open_adapter_from_gdi_display_name *desc);
typedef LONG (WINAPI *pfn_D3DKMTOpenAdapterFromLuid)(
        aw_d3dkmt_open_adapter_from_luid *desc);
typedef LONG (WINAPI *pfn_D3DKMTCloseAdapter)(
        const aw_d3dkmt_close_adapter *desc);

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

static void print_wide(const WCHAR *w, char *out, size_t out_size)
{
    int n;
    if (!out_size)
        return;
    out[0] = 0;
    if (!w)
        return;
    n = WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)out_size, NULL, NULL);
    if (!n)
        snprintf(out, out_size, "<wide-conversion-error:%lu>", (unsigned long)GetLastError());
}

static int probe_display_kmt(void)
{
    DISPLAY_DEVICEW display;
    WCHAR primary_name[32] = {0};
    char name_utf8[256], string_utf8[256];
    unsigned int i, count = 0;
    HMODULE gdi32;
    pfn_D3DKMTOpenAdapterFromGdiDisplayName open_gdi;
    pfn_D3DKMTOpenAdapterFromLuid open_luid;
    pfn_D3DKMTCloseAdapter close_adapter;
    aw_d3dkmt_open_adapter_from_gdi_display_name gdi_desc;
    aw_d3dkmt_open_adapter_from_luid luid_desc;
    aw_d3dkmt_close_adapter close_desc;
    LONG status;

    puts("STAGE_ENUM_DISPLAY_BEGIN");
    for (i = 0; i < 16; ++i)
    {
        memset(&display, 0, sizeof(display));
        display.cb = sizeof(display);
        if (!EnumDisplayDevicesW(NULL, i, &display, 0))
            break;

        print_wide(display.DeviceName, name_utf8, sizeof(name_utf8));
        print_wide(display.DeviceString, string_utf8, sizeof(string_utf8));
        printf("DISPLAY[%u] name=%s string=%s flags=0x%08lx\n",
               i, name_utf8, string_utf8, (unsigned long)display.StateFlags);
        ++count;

        if ((display.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) && !primary_name[0])
            lstrcpynW(primary_name, display.DeviceName, 32);
    }
    printf("EnumDisplayDevicesW count=%u primary=%s\n",
           count, primary_name[0] ? "present" : "missing");
    if (!primary_name[0])
    {
        puts("STAGE_ENUM_DISPLAY_FAIL");
        return 20;
    }
    print_wide(primary_name, name_utf8, sizeof(name_utf8));
    printf("primary_display=%s\n", name_utf8);
    puts("STAGE_ENUM_DISPLAY_PASS");

    gdi32 = LoadLibraryA("gdi32.dll");
    if (!gdi32)
    {
        printf("STAGE_D3DKMT_LOAD_FAIL error=%lu\n", (unsigned long)GetLastError());
        return 21;
    }
    open_gdi = (pfn_D3DKMTOpenAdapterFromGdiDisplayName)(void *)
        GetProcAddress(gdi32, "D3DKMTOpenAdapterFromGdiDisplayName");
    open_luid = (pfn_D3DKMTOpenAdapterFromLuid)(void *)
        GetProcAddress(gdi32, "D3DKMTOpenAdapterFromLuid");
    close_adapter = (pfn_D3DKMTCloseAdapter)(void *)
        GetProcAddress(gdi32, "D3DKMTCloseAdapter");
    printf("D3DKMT exports gdi=%s luid=%s close=%s\n",
           open_gdi ? "present" : "missing",
           open_luid ? "present" : "missing",
           close_adapter ? "present" : "missing");
    if (!open_gdi || !open_luid || !close_adapter)
    {
        FreeLibrary(gdi32);
        return 22;
    }

    memset(&gdi_desc, 0, sizeof(gdi_desc));
    lstrcpynW(gdi_desc.DeviceName, primary_name, 32);
    puts("STAGE_D3DKMT_OPEN_GDI_BEGIN");
    status = open_gdi(&gdi_desc);
    printf("D3DKMTOpenAdapterFromGdiDisplayName status=0x%08lx hAdapter=%u luid=%08lx:%08lx source=%u\n",
           (unsigned long)status, gdi_desc.hAdapter,
           (unsigned long)gdi_desc.AdapterLuid.HighPart,
           (unsigned long)gdi_desc.AdapterLuid.LowPart,
           gdi_desc.VidPnSourceId);
    if (status)
    {
        FreeLibrary(gdi32);
        return 23;
    }
    puts("STAGE_D3DKMT_OPEN_GDI_PASS");
    close_desc.hAdapter = gdi_desc.hAdapter;
    status = close_adapter(&close_desc);
    printf("D3DKMTCloseAdapter(gdi) status=0x%08lx\n", (unsigned long)status);

    memset(&luid_desc, 0, sizeof(luid_desc));
    luid_desc.AdapterLuid = gdi_desc.AdapterLuid;
    puts("STAGE_D3DKMT_OPEN_LUID_BEGIN");
    status = open_luid(&luid_desc);
    printf("D3DKMTOpenAdapterFromLuid status=0x%08lx hAdapter=%u\n",
           (unsigned long)status, luid_desc.hAdapter);
    if (status)
    {
        FreeLibrary(gdi32);
        return 24;
    }
    puts("STAGE_D3DKMT_OPEN_LUID_PASS");
    close_desc.hAdapter = luid_desc.hAdapter;
    status = close_adapter(&close_desc);
    printf("D3DKMTCloseAdapter(luid) status=0x%08lx\n", (unsigned long)status);

    FreeLibrary(gdi32);
    puts("SMOKE_RESULT=PASS_DISPLAY_KMT");
    return 0;
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

    if (!strcmp(mode, "display-kmt"))
        return probe_display_kmt();

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
