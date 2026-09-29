#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_SUCCESS 0
#define VK_INCOMPLETE 5
#define VK_MAX_EXTENSION_NAME_SIZE 256
#define VK_STRUCTURE_TYPE_APPLICATION_INFO 0
#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO 1
#define VK_MAKE_API_VERSION(variant, major, minor, patch) \
    ((((uint32_t)(variant)) << 29) | (((uint32_t)(major)) << 22) | \
     (((uint32_t)(minor)) << 12) | ((uint32_t)(patch)))

typedef int32_t VkResult;
typedef void *VkInstance;
typedef void *VkPhysicalDevice;

typedef struct VkExtensionProperties
{
    char extensionName[VK_MAX_EXTENSION_NAME_SIZE];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct VkApplicationInfo
{
    int32_t sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VkApplicationInfo;

typedef struct VkInstanceCreateInfo
{
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef VkResult (*PFN_vkEnumerateInstanceExtensionProperties)(
        const char *pLayerName,
        uint32_t *pPropertyCount,
        VkExtensionProperties *pProperties);
typedef VkResult (*PFN_vkCreateInstance)(
        const VkInstanceCreateInfo *pCreateInfo,
        const void *pAllocator,
        VkInstance *pInstance);
typedef void (*PFN_vkDestroyInstance)(
        VkInstance instance,
        const void *pAllocator);
typedef void *(*PFN_vkGetInstanceProcAddr)(VkInstance instance, const char *name);
typedef VkResult (*PFN_vkEnumeratePhysicalDevices)(
        VkInstance instance,
        uint32_t *pPhysicalDeviceCount,
        VkPhysicalDevice *pPhysicalDevices);
typedef VkResult (*PFN_vkEnumerateDeviceExtensionProperties)(
        VkPhysicalDevice physicalDevice,
        const char *pLayerName,
        uint32_t *pPropertyCount,
        VkExtensionProperties *pProperties);
typedef void (*PFN_vkGetPhysicalDeviceMemoryPropertiesOpaque)(
        VkPhysicalDevice physicalDevice,
        void *pMemoryProperties);

static int do_extension_call(const char *source,
                             PFN_vkEnumerateInstanceExtensionProperties enumerate,
                             int fill)
{
    VkExtensionProperties *props = NULL;
    uint32_t count = 0, capacity = 0;
    VkResult vr;

    printf("VKEXT_SOURCE=%s\n", source);
    puts("VKEXT_COUNT_BEGIN");
    vr = enumerate(NULL, &count, NULL);
    printf("VKEXT_COUNT_END result=%d count=%u\n", vr, count);
    if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
    {
        puts("VKEXT_RESULT=FAIL_COUNT");
        return 20;
    }

    if (!fill)
    {
        puts("VKEXT_RESULT=PASS");
        return 0;
    }

    capacity = count ? count : 1;
    props = calloc(capacity, sizeof(*props));
    if (!props)
    {
        puts("VKEXT_RESULT=FAIL_ALLOC");
        return 21;
    }

    count = capacity;
    printf("VKEXT_FILL_BEGIN capacity=%u buffer=%p\n", capacity, (void *)props);
    vr = enumerate(NULL, &count, props);
    printf("VKEXT_FILL_END result=%d count=%u\n", vr, count);
    if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
    {
        free(props);
        puts("VKEXT_RESULT=FAIL_FILL");
        return 22;
    }

    for (uint32_t i = 0; i < count && i < capacity && i < 32; ++i)
        printf("VKEXT[%u]=%s spec=%u\n", i, props[i].extensionName, props[i].specVersion);

    free(props);
    puts("VKEXT_RESULT=PASS");
    return 0;
}

static int do_create_call(const char *source,
                          PFN_vkCreateInstance create_instance,
                          PFN_vkDestroyInstance destroy_instance,
                          int wine5)
{
    static const char *const wine5_extensions[] = {
        "VK_KHR_external_memory_capabilities",
        "VK_KHR_external_semaphore_capabilities",
        "VK_KHR_get_physical_device_properties2",
        "VK_KHR_surface",
        "VK_EXT_headless_surface"
    };
    VkApplicationInfo app;
    VkInstanceCreateInfo ci;
    VkInstance instance = NULL;
    VkResult vr;

    memset(&app, 0, sizeof(app));
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "animalwell-vkcreate-probe";
    app.pEngineName = "vkd3d";
    app.engineVersion = 0x00801000u;
    app.apiVersion = VK_MAKE_API_VERSION(0, 1, 1, 0);

    memset(&ci, 0, sizeof(ci));
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &app;
    if (wine5)
    {
        ci.enabledExtensionCount =
            (uint32_t)(sizeof(wine5_extensions) / sizeof(wine5_extensions[0]));
        ci.ppEnabledExtensionNames = wine5_extensions;
    }

    printf("VKCREATE_SOURCE=%s\n", source);
    printf("VKCREATE_VARIANT=%s extension_count=%u api=0x%08x\n",
           wine5 ? "wine5" : "minimal", ci.enabledExtensionCount, app.apiVersion);
    for (uint32_t i = 0; i < ci.enabledExtensionCount; ++i)
        printf("VKCREATE_EXT[%u]=%s\n", i, ci.ppEnabledExtensionNames[i]);

    puts("VKCREATE_BEGIN");
    vr = create_instance(&ci, NULL, &instance);
    printf("VKCREATE_END result=%d instance=%p\n", vr, instance);
    if (vr != VK_SUCCESS || !instance)
    {
        puts("VKCREATE_RESULT=FAIL");
        return 30;
    }

    puts("VKCREATE_RESULT=PASS");
    if (destroy_instance)
    {
        puts("VKDESTROY_BEGIN");
        destroy_instance(instance, NULL);
        puts("VKDESTROY_END");
    }
    else
    {
        puts("VKDESTROY_SKIPPED=no_symbol");
    }
    return 0;
}


static int do_postcreate_call(PFN_vkCreateInstance create_instance,
                              PFN_vkDestroyInstance direct_destroy,
                              PFN_vkGetInstanceProcAddr gipa)
{
    static const char *const wine5_extensions[] = {
        "VK_KHR_external_memory_capabilities",
        "VK_KHR_external_semaphore_capabilities",
        "VK_KHR_get_physical_device_properties2",
        "VK_KHR_surface",
        "VK_EXT_headless_surface"
    };
    static const char *const proc_names[] = {
        "vkCreateDebugReportCallbackEXT",
        "vkCreateDebugUtilsMessengerEXT",
        "vkCreateDevice",
        "vkDebugReportMessageEXT",
        "vkDestroyDebugReportCallbackEXT",
        "vkDestroyDebugUtilsMessengerEXT",
        "vkDestroyInstance",
        "vkDestroySurfaceKHR",
        "vkEnumerateDeviceExtensionProperties",
        "vkEnumerateDeviceLayerProperties",
        "vkEnumeratePhysicalDeviceGroups",
        "vkEnumeratePhysicalDeviceGroupsKHR",
        "vkEnumeratePhysicalDeviceQueueFamilyPerformanceCountersByRegionARM",
        "vkEnumeratePhysicalDeviceQueueFamilyPerformanceQueryCountersKHR",
        "vkEnumeratePhysicalDeviceShaderInstrumentationMetricsARM",
        "vkEnumeratePhysicalDevices",
        "vkGetPhysicalDeviceCalibrateableTimeDomainsEXT",
        "vkGetPhysicalDeviceCalibrateableTimeDomainsKHR",
        "vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR",
        "vkGetPhysicalDeviceCooperativeMatrixPropertiesNV",
        "vkGetPhysicalDeviceDisplayPlaneProperties2KHR",
        "vkGetPhysicalDeviceDisplayPlanePropertiesKHR",
        "vkGetPhysicalDeviceDisplayProperties2KHR",
        "vkGetPhysicalDeviceDisplayPropertiesKHR",
        "vkGetPhysicalDeviceExternalBufferProperties",
        "vkGetPhysicalDeviceExternalBufferPropertiesKHR",
        "vkGetPhysicalDeviceExternalFenceProperties",
        "vkGetPhysicalDeviceExternalFencePropertiesKHR",
        "vkGetPhysicalDeviceExternalImageFormatPropertiesNV",
        "vkGetPhysicalDeviceExternalSemaphoreProperties",
        "vkGetPhysicalDeviceExternalSemaphorePropertiesKHR",
        "vkGetPhysicalDeviceExternalTensorPropertiesARM",
        "vkGetPhysicalDeviceFeatures",
        "vkGetPhysicalDeviceFeatures2",
        "vkGetPhysicalDeviceFeatures2KHR",
        "vkGetPhysicalDeviceFormatProperties",
        "vkGetPhysicalDeviceFormatProperties2",
        "vkGetPhysicalDeviceFormatProperties2KHR",
        "vkGetPhysicalDeviceFragmentShadingRatesKHR",
        "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceImageFormatProperties2",
        "vkGetPhysicalDeviceImageFormatProperties2KHR",
        "vkGetPhysicalDeviceMemoryProperties",
        "vkGetPhysicalDeviceMemoryProperties2",
        "vkGetPhysicalDeviceMemoryProperties2KHR",
        "vkGetPhysicalDeviceMultisamplePropertiesEXT",
        "vkGetPhysicalDeviceOpticalFlowImageFormatsNV",
        "vkGetPhysicalDevicePresentRectanglesKHR",
        "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceProperties2",
        "vkGetPhysicalDeviceProperties2KHR",
        "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceQueueFamilyProperties2",
        "vkGetPhysicalDeviceQueueFamilyProperties2KHR",
        "vkGetPhysicalDeviceSparseImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties2",
        "vkGetPhysicalDeviceSparseImageFormatProperties2KHR",
        "vkGetPhysicalDeviceSurfaceCapabilities2EXT",
        "vkGetPhysicalDeviceSurfaceCapabilities2KHR",
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        "vkGetPhysicalDeviceSurfaceFormats2KHR",
        "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
        "vkGetPhysicalDeviceSurfaceSupportKHR",
        "vkGetPhysicalDeviceToolProperties",
        "vkGetPhysicalDeviceToolPropertiesEXT",
        "vkGetPhysicalDeviceVideoCapabilitiesKHR",
        "vkGetPhysicalDeviceVideoEncodeQualityLevelPropertiesKHR",
        "vkGetPhysicalDeviceVideoFormatPropertiesKHR",
        "vkGetPhysicalDeviceWaylandPresentationSupportKHR",
        "vkGetPhysicalDeviceXcbPresentationSupportKHR",
        "vkGetPhysicalDeviceXlibPresentationSupportKHR"
    };
    VkApplicationInfo app;
    VkInstanceCreateInfo ci;
    VkInstance instance = NULL;
    PFN_vkEnumeratePhysicalDevices enumerate_physical_devices = NULL;
    PFN_vkEnumerateDeviceExtensionProperties enumerate_device_extensions = NULL;
    PFN_vkGetPhysicalDeviceMemoryPropertiesOpaque get_memory_properties = NULL;
    VkPhysicalDevice *physical_devices = NULL;
    VkExtensionProperties *device_extensions = NULL;
    uint32_t physical_count = 0, device_extension_count = 0;
    VkResult vr;

    memset(&app, 0, sizeof(app));
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "animalwell-postcreate-probe";
    app.pEngineName = "vkd3d";
    app.engineVersion = 0x00801000u;
    app.apiVersion = VK_MAKE_API_VERSION(0, 1, 1, 0);

    memset(&ci, 0, sizeof(ci));
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &app;
    ci.enabledExtensionCount = (uint32_t)(sizeof(wine5_extensions) / sizeof(wine5_extensions[0]));
    ci.ppEnabledExtensionNames = wine5_extensions;

    puts("VKPOSTCREATE_CREATE_BEGIN");
    vr = create_instance(&ci, NULL, &instance);
    printf("VKPOSTCREATE_CREATE_END result=%d instance=%p\n", vr, instance);
    if (vr != VK_SUCCESS || !instance)
    {
        puts("VKPOSTCREATE_RESULT=FAIL_CREATE");
        return 40;
    }

    for (uint32_t i = 0; i < (uint32_t)(sizeof(proc_names) / sizeof(proc_names[0])); ++i)
    {
        void *proc;
        printf("VKPOSTPROC_BEGIN index=%u name=%s\n", i, proc_names[i]);
        proc = gipa(instance, proc_names[i]);
        printf("VKPOSTPROC_END index=%u name=%s ptr=%p\n", i, proc_names[i], proc);

        if (!strcmp(proc_names[i], "vkEnumeratePhysicalDevices"))
            enumerate_physical_devices = (PFN_vkEnumeratePhysicalDevices)proc;
        else if (!strcmp(proc_names[i], "vkEnumerateDeviceExtensionProperties"))
            enumerate_device_extensions = (PFN_vkEnumerateDeviceExtensionProperties)proc;
        else if (!strcmp(proc_names[i], "vkGetPhysicalDeviceMemoryProperties"))
            get_memory_properties = (PFN_vkGetPhysicalDeviceMemoryPropertiesOpaque)proc;
    }
    puts("VKPOSTCREATE_GIPA_SCAN_PASS");

    if (!enumerate_physical_devices)
    {
        puts("VKPOSTCREATE_RESULT=FAIL_NO_ENUM_PHYSICAL");
        goto failed;
    }

    puts("VKPOSTPHYS_COUNT_BEGIN");
    vr = enumerate_physical_devices(instance, &physical_count, NULL);
    printf("VKPOSTPHYS_COUNT_END result=%d count=%u\n", vr, physical_count);
    if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
    {
        puts("VKPOSTCREATE_RESULT=FAIL_PHYSICAL_COUNT");
        goto failed;
    }

    if (physical_count)
    {
        uint32_t capacity = physical_count;
        physical_devices = calloc(capacity, sizeof(*physical_devices));
        if (!physical_devices)
        {
            puts("VKPOSTCREATE_RESULT=FAIL_PHYSICAL_ALLOC");
            goto failed;
        }

        puts("VKPOSTPHYS_FILL_BEGIN");
        vr = enumerate_physical_devices(instance, &physical_count, physical_devices);
        printf("VKPOSTPHYS_FILL_END result=%d count=%u first=%p\n",
               vr, physical_count, physical_count ? physical_devices[0] : NULL);
        if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
        {
            puts("VKPOSTCREATE_RESULT=FAIL_PHYSICAL_FILL");
            goto failed;
        }

        if (physical_count && get_memory_properties)
        {
            union {
                uint64_t align;
                unsigned char bytes[4096];
            } memory_properties;
            memset(&memory_properties, 0, sizeof(memory_properties));
            puts("VKPOSTMEM_BEGIN");
            get_memory_properties(physical_devices[0], memory_properties.bytes);
            printf("VKPOSTMEM_END first_words=%08x:%08x\n",
                   ((uint32_t *)memory_properties.bytes)[0],
                   ((uint32_t *)memory_properties.bytes)[1]);
        }

        if (physical_count && enumerate_device_extensions)
        {
            puts("VKPOSTDEVEXT_COUNT_BEGIN");
            vr = enumerate_device_extensions(physical_devices[0], NULL, &device_extension_count, NULL);
            printf("VKPOSTDEVEXT_COUNT_END result=%d count=%u\n", vr, device_extension_count);
            if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
            {
                puts("VKPOSTCREATE_RESULT=FAIL_DEVICE_EXT_COUNT");
                goto failed;
            }

            if (device_extension_count)
            {
                uint32_t capacity = device_extension_count;
                device_extensions = calloc(capacity, sizeof(*device_extensions));
                if (!device_extensions)
                {
                    puts("VKPOSTCREATE_RESULT=FAIL_DEVICE_EXT_ALLOC");
                    goto failed;
                }
                puts("VKPOSTDEVEXT_FILL_BEGIN");
                vr = enumerate_device_extensions(physical_devices[0], NULL,
                                                 &device_extension_count, device_extensions);
                printf("VKPOSTDEVEXT_FILL_END result=%d count=%u\n", vr, device_extension_count);
                if (vr != VK_SUCCESS && vr != VK_INCOMPLETE)
                {
                    puts("VKPOSTCREATE_RESULT=FAIL_DEVICE_EXT_FILL");
                    goto failed;
                }
                for (uint32_t i = 0; i < device_extension_count && i < capacity && i < 32; ++i)
                    printf("VKPOSTDEVEXT[%u]=%s spec=%u\n", i,
                           device_extensions[i].extensionName, device_extensions[i].specVersion);
            }
        }
    }

    puts("VKPOSTCREATE_RESULT=PASS");
    free(device_extensions);
    free(physical_devices);
    if (direct_destroy)
    {
        puts("VKPOSTDESTROY_BEGIN");
        direct_destroy(instance, NULL);
        puts("VKPOSTDESTROY_END");
    }
    return 0;

failed:
    free(device_extensions);
    free(physical_devices);
    if (direct_destroy) direct_destroy(instance, NULL);
    return 41;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "direct-fill";
    void *lib;
    PFN_vkEnumerateInstanceExtensionProperties direct_enum = NULL;
    PFN_vkEnumerateInstanceExtensionProperties via_gipa_enum = NULL;
    PFN_vkCreateInstance direct_create = NULL;
    PFN_vkCreateInstance via_gipa_create = NULL;
    PFN_vkDestroyInstance direct_destroy = NULL;
    PFN_vkDestroyInstance via_gipa_destroy = NULL;
    PFN_vkGetInstanceProcAddr gipa = NULL;
    int fill;

    setvbuf(stdout, NULL, _IONBF, 0);
    puts("ANIMAL WELL x86_64 Vulkan extension/create/post-create bridge probe");
    printf("mode=%s\n", mode);
    printf("sizeof_extension_properties=%zu sizeof_app_info=%zu sizeof_instance_create_info=%zu\n",
           sizeof(VkExtensionProperties), sizeof(VkApplicationInfo), sizeof(VkInstanceCreateInfo));

    lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib)
    {
        printf("VKEXT_DLOPEN_FAIL error=%s\n", dlerror());
        return 10;
    }
    printf("VKEXT_DLOPEN_PASS handle=%p\n", lib);

    direct_enum = (PFN_vkEnumerateInstanceExtensionProperties)
        dlsym(lib, "vkEnumerateInstanceExtensionProperties");
    direct_create = (PFN_vkCreateInstance)dlsym(lib, "vkCreateInstance");
    direct_destroy = (PFN_vkDestroyInstance)dlsym(lib, "vkDestroyInstance");
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    printf("VKEXT_SYMBOLS enumerate=%p create=%p destroy=%p gipa=%p\n",
           (void *)direct_enum, (void *)direct_create, (void *)direct_destroy, (void *)gipa);

    fill = strstr(mode, "-fill") != NULL;

    if (!strncmp(mode, "direct-", 7) &&
        (strstr(mode, "-count") || strstr(mode, "-fill")))
    {
        if (!direct_enum)
        {
            puts("VKEXT_RESULT=FAIL_DIRECT_SYMBOL");
            dlclose(lib);
            return 11;
        }
        int rc = do_extension_call("direct-dlsym", direct_enum, fill);
        dlclose(lib);
        return rc;
    }

    if (!strncmp(mode, "gipa-", 5) &&
        (strstr(mode, "-count") || strstr(mode, "-fill")))
    {
        if (!gipa)
        {
            puts("VKEXT_RESULT=FAIL_GIPA_SYMBOL");
            dlclose(lib);
            return 12;
        }
        via_gipa_enum = (PFN_vkEnumerateInstanceExtensionProperties)
            gipa(NULL, "vkEnumerateInstanceExtensionProperties");
        printf("VKEXT_GIPA_RESULT enumerate=%p\n", (void *)via_gipa_enum);
        if (!via_gipa_enum)
        {
            puts("VKEXT_RESULT=FAIL_GIPA_LOOKUP");
            dlclose(lib);
            return 13;
        }
        int rc = do_extension_call("vkGetInstanceProcAddr", via_gipa_enum, fill);
        dlclose(lib);
        return rc;
    }

    if (!strcmp(mode, "postcreate-wine5"))
    {
        if (!direct_create || !gipa)
        {
            puts("VKPOSTCREATE_RESULT=FAIL_SYMBOLS");
            dlclose(lib);
            return 16;
        }
        int rc = do_postcreate_call(direct_create, direct_destroy, gipa);
        dlclose(lib);
        return rc;
    }

    if (!strncmp(mode, "create-", 7))
    {
        int wine5 = strstr(mode, "-wine5-") != NULL;
        int use_gipa = strstr(mode, "-gipa") != NULL;
        PFN_vkCreateInstance create_fn = direct_create;
        PFN_vkDestroyInstance destroy_fn = direct_destroy;
        const char *source = "direct-dlsym";

        if (use_gipa)
        {
            if (!gipa)
            {
                puts("VKCREATE_RESULT=FAIL_GIPA_SYMBOL");
                dlclose(lib);
                return 14;
            }
            via_gipa_create = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
            via_gipa_destroy = (PFN_vkDestroyInstance)gipa(NULL, "vkDestroyInstance");
            printf("VKCREATE_GIPA_RESULT create=%p destroy=%p\n",
                   (void *)via_gipa_create, (void *)via_gipa_destroy);
            create_fn = via_gipa_create;
            destroy_fn = via_gipa_destroy;
            source = "vkGetInstanceProcAddr";
        }

        if (!create_fn)
        {
            puts("VKCREATE_RESULT=FAIL_CREATE_SYMBOL");
            dlclose(lib);
            return 15;
        }

        int rc = do_create_call(source, create_fn, destroy_fn, wine5);
        dlclose(lib);
        return rc;
    }

    puts("usage: vulkan_ext_probe_x64 direct-count|direct-fill|gipa-count|gipa-fill|create-min-direct|create-min-gipa|create-wine5-direct|create-wine5-gipa|postcreate-wine5");
    dlclose(lib);
    return 2;
}
