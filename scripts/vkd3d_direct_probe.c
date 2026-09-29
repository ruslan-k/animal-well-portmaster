#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <vkd3d.h>

static const GUID iid_id3d12_device =
    {0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};

static HRESULT signal_event(HANDLE event)
{
    (void)event;
    return S_OK;
}

static ULONG release_com(void *object)
{
    typedef ULONG (STDMETHODCALLTYPE *release_fn)(void *);
    void **vtbl;

    if (!object)
        return 0;
    vtbl = *(void ***)object;
    if (!vtbl || !vtbl[2])
        return 0;
    return ((release_fn)vtbl[2])(object);
}

int main(void)
{
    struct vkd3d_application_info app_info;
    struct vkd3d_instance_create_info instance_info;
    struct vkd3d_device_create_info device_info;
    struct vkd3d_instance *instance = NULL;
    void *device = NULL;
    VkInstance vk_instance;
    VkPhysicalDevice vk_physical_device;
    VkDevice vk_device;
    HRESULT hr;
    ULONG refs;

    puts("ANIMAL WELL test13 direct VKD3D 2.1 probe");
    puts("path=Box64->libvkd3d.so->native Vulkan (no Wine, no DXGI, no Xorg, no WSI)");
    printf("requested_feature_level=0x%04x (D3D_FEATURE_LEVEL_11_0)\n",
            (unsigned int)D3D_FEATURE_LEVEL_11_0);

    memset(&app_info, 0, sizeof(app_info));
    app_info.type = VKD3D_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.application_name = "animalwell-test13";
    app_info.engine_name = "direct-vkd3d-probe";
    app_info.api_version = VKD3D_API_VERSION_2_1;

    memset(&instance_info, 0, sizeof(instance_info));
    instance_info.type = VKD3D_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.next = &app_info;
    instance_info.pfn_signal_event = signal_event;
    instance_info.wchar_size = 2;
    instance_info.pfn_vkGetInstanceProcAddr = NULL;
    instance_info.instance_extensions = NULL;
    instance_info.instance_extension_count = 0;

    hr = vkd3d_create_instance(&instance_info, &instance);
    printf("vkd3d_create_instance hr=0x%08x ptr=%p\n", (unsigned int)hr, (void *)instance);
    if (FAILED(hr) || !instance)
    {
        puts("VKD3D_INSTANCE_RESULT=FAIL");
        puts("VKD3D_DEVICE_RESULT=NOT_REACHED");
        return 21;
    }

    vk_instance = vkd3d_instance_get_vk_instance(instance);
    printf("vk_instance=%p\n", (void *)(uintptr_t)vk_instance);
    puts("VKD3D_INSTANCE_RESULT=PASS");

    memset(&device_info, 0, sizeof(device_info));
    device_info.type = VKD3D_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.minimum_feature_level = D3D_FEATURE_LEVEL_11_0;
    device_info.instance = instance;
    device_info.instance_create_info = NULL;
    device_info.vk_physical_device = VK_NULL_HANDLE;
    device_info.device_extensions = NULL;
    device_info.device_extension_count = 0;
    device_info.parent = NULL;
    memset(&device_info.adapter_luid, 0, sizeof(device_info.adapter_luid));

    hr = vkd3d_create_device(&device_info, &iid_id3d12_device, &device);
    printf("vkd3d_create_device FL11_0 hr=0x%08x ptr=%p\n", (unsigned int)hr, device);
    if (FAILED(hr) || !device)
    {
        puts("VKD3D_DEVICE_RESULT=FAIL");
        vkd3d_instance_decref(instance);
        return 22;
    }

    vk_physical_device = vkd3d_get_vk_physical_device((ID3D12Device *)device);
    vk_device = vkd3d_get_vk_device((ID3D12Device *)device);
    printf("vk_physical_device=%p\n", (void *)(uintptr_t)vk_physical_device);
    printf("vk_device=%p\n", (void *)(uintptr_t)vk_device);
    puts("VKD3D_DEVICE_RESULT=PASS");

    refs = release_com(device);
    printf("device_release_remaining_refs=%u\n", (unsigned int)refs);
    vkd3d_instance_decref(instance);
    return 0;
}
