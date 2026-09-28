#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_SUCCESS 0
#define VK_INCOMPLETE 5
#define VK_MAX_EXTENSION_NAME_SIZE 256

typedef int32_t VkResult;

typedef struct VkExtensionProperties
{
    char extensionName[VK_MAX_EXTENSION_NAME_SIZE];
    uint32_t specVersion;
} VkExtensionProperties;

typedef VkResult (*PFN_vkEnumerateInstanceExtensionProperties)(
        const char *pLayerName,
        uint32_t *pPropertyCount,
        VkExtensionProperties *pProperties);

typedef void *(*PFN_vkGetInstanceProcAddr)(void *instance, const char *name);

static int do_call(const char *source,
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

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "direct-fill";
    void *lib;
    PFN_vkEnumerateInstanceExtensionProperties direct = NULL;
    PFN_vkEnumerateInstanceExtensionProperties via_gipa = NULL;
    PFN_vkGetInstanceProcAddr gipa = NULL;
    int fill;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("ANIMAL WELL x86_64 Vulkan extension bridge probe\n");
    printf("mode=%s\n", mode);
    printf("sizeof_extension_properties=%zu\n", sizeof(VkExtensionProperties));

    lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib)
    {
        printf("VKEXT_DLOPEN_FAIL error=%s\n", dlerror());
        return 10;
    }
    printf("VKEXT_DLOPEN_PASS handle=%p\n", lib);

    direct = (PFN_vkEnumerateInstanceExtensionProperties)
        dlsym(lib, "vkEnumerateInstanceExtensionProperties");
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    printf("VKEXT_SYMBOLS direct=%p gipa=%p\n", (void *)direct, (void *)gipa);

    fill = strstr(mode, "-fill") != NULL;

    if (!strncmp(mode, "direct-", 7))
    {
        if (!direct)
        {
            puts("VKEXT_RESULT=FAIL_DIRECT_SYMBOL");
            dlclose(lib);
            return 11;
        }
        int rc = do_call("direct-dlsym", direct, fill);
        dlclose(lib);
        return rc;
    }

    if (!strncmp(mode, "gipa-", 5))
    {
        if (!gipa)
        {
            puts("VKEXT_RESULT=FAIL_GIPA_SYMBOL");
            dlclose(lib);
            return 12;
        }
        via_gipa = (PFN_vkEnumerateInstanceExtensionProperties)
            gipa(NULL, "vkEnumerateInstanceExtensionProperties");
        printf("VKEXT_GIPA_RESULT enumerate=%p\n", (void *)via_gipa);
        if (!via_gipa)
        {
            puts("VKEXT_RESULT=FAIL_GIPA_LOOKUP");
            dlclose(lib);
            return 13;
        }
        int rc = do_call("vkGetInstanceProcAddr", via_gipa, fill);
        dlclose(lib);
        return rc;
    }

    puts("usage: vulkan_ext_probe_x64 direct-count|direct-fill|gipa-count|gipa-fill");
    dlclose(lib);
    return 2;
}
