#define VK_USE_PLATFORM_XLIB_KHR
#include <vulkan/vulkan.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int has_ext(const VkExtensionProperties *p, uint32_t n, const char *name)
{
    for (uint32_t i=0;i<n;i++) if (!strcmp(p[i].extensionName,name)) return 1;
    return 0;
}
int main(void)
{
    uint32_t n=0; VkResult vr;
    vkEnumerateInstanceExtensionProperties(NULL,&n,NULL);
    VkExtensionProperties *ep=calloc(n,sizeof(*ep));
    vkEnumerateInstanceExtensionProperties(NULL,&n,ep);
    printf("instance_ext.xlib_surface=%d\n",has_ext(ep,n,VK_KHR_XLIB_SURFACE_EXTENSION_NAME));
    printf("instance_ext.xcb_surface=%d\n",has_ext(ep,n,"VK_KHR_xcb_surface"));
    printf("instance_ext.wayland_surface=%d\n",has_ext(ep,n,"VK_KHR_wayland_surface"));
    printf("instance_ext.headless_surface=%d\n",has_ext(ep,n,"VK_EXT_headless_surface"));
    free(ep);
    const char *exts[]={VK_KHR_SURFACE_EXTENSION_NAME,VK_KHR_XLIB_SURFACE_EXTENSION_NAME};
    VkApplicationInfo ai={VK_STRUCTURE_TYPE_APPLICATION_INFO,NULL,"animalwell-test14",1,"wsi-probe",1,VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,NULL,0,&ai,0,NULL,2,exts};
    VkInstance inst=VK_NULL_HANDLE;
    vr=vkCreateInstance(&ici,NULL,&inst);
    printf("vkCreateInstance=%d\n",vr);
    if(vr!=VK_SUCCESS) return 20;

    Display *dpy=XOpenDisplay(NULL);
    printf("XOpenDisplay=%s\n",dpy?"PASS":"FAIL");
    if(!dpy) return 21;
    int s=DefaultScreen(dpy);
    Window win=XCreateSimpleWindow(dpy,RootWindow(dpy,s),0,0,320,180,0,BlackPixel(dpy,s),BlackPixel(dpy,s));
    XMapWindow(dpy,win); XFlush(dpy);

    PFN_vkCreateXlibSurfaceKHR pCreate=(PFN_vkCreateXlibSurfaceKHR)vkGetInstanceProcAddr(inst,"vkCreateXlibSurfaceKHR");
    printf("vkCreateXlibSurfaceKHR.proc=%s\n",pCreate?"present":"missing");
    if(!pCreate) return 22;
    VkXlibSurfaceCreateInfoKHR sci={VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,NULL,0,dpy,win};
    VkSurfaceKHR surf=VK_NULL_HANDLE;
    vr=pCreate(inst,&sci,NULL,&surf);
    printf("vkCreateXlibSurfaceKHR=%d surface=%p\n",vr,(void*)(uintptr_t)surf);
    if(vr!=VK_SUCCESS) return 23;

    uint32_t pc=0; vkEnumeratePhysicalDevices(inst,&pc,NULL);
    if(!pc){puts("physical_device=none"); return 24;}
    VkPhysicalDevice *pd=calloc(pc,sizeof(*pd)); vkEnumeratePhysicalDevices(inst,&pc,pd);
    VkPhysicalDevice phys=pd[0]; free(pd);
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(phys,&props);
    printf("physical_device=%s api=%u.%u.%u\n",props.deviceName,VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion),VK_VERSION_PATCH(props.apiVersion));

    uint32_t qn=0; vkGetPhysicalDeviceQueueFamilyProperties(phys,&qn,NULL);
    VkQueueFamilyProperties *qp=calloc(qn,sizeof(*qp)); vkGetPhysicalDeviceQueueFamilyProperties(phys,&qn,qp);
    uint32_t qidx=UINT32_MAX;
    for(uint32_t i=0;i<qn;i++){ VkBool32 sup=0; vkGetPhysicalDeviceSurfaceSupportKHR(phys,i,surf,&sup); if(sup && (qp[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)){qidx=i;break;} }
    free(qp);
    printf("present_queue=%s index=%u\n",qidx==UINT32_MAX?"FAIL":"PASS",qidx);
    if(qidx==UINT32_MAX) return 25;

    uint32_t dn=0; vkEnumerateDeviceExtensionProperties(phys,NULL,&dn,NULL);
    VkExtensionProperties *dp=calloc(dn,sizeof(*dp)); vkEnumerateDeviceExtensionProperties(phys,NULL,&dn,dp);
    int has_swap=has_ext(dp,dn,VK_KHR_SWAPCHAIN_EXTENSION_NAME); free(dp);
    printf("device_ext.swapchain=%d\n",has_swap);
    if(!has_swap) return 26;

    VkSurfaceCapabilitiesKHR caps; vr=vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys,surf,&caps);
    printf("surface_caps=%d minImages=%u maxImages=%u currentExtent=%ux%u\n",vr,caps.minImageCount,caps.maxImageCount,caps.currentExtent.width,caps.currentExtent.height);
    if(vr!=VK_SUCCESS) return 27;
    uint32_t fn=0; vkGetPhysicalDeviceSurfaceFormatsKHR(phys,surf,&fn,NULL);
    VkSurfaceFormatKHR *fmts=calloc(fn,sizeof(*fmts)); vkGetPhysicalDeviceSurfaceFormatsKHR(phys,surf,&fn,fmts);
    printf("surface_formats=%u\n",fn); if(!fn) return 28;
    VkSurfaceFormatKHR fmt=fmts[0]; free(fmts);

    float prio=1.0f; VkDeviceQueueCreateInfo qci={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,NULL,0,qidx,1,&prio};
    const char *dexts[]={VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo dci={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,NULL,0,1,&qci,0,NULL,1,dexts,NULL};
    VkDevice dev=VK_NULL_HANDLE; vr=vkCreateDevice(phys,&dci,NULL,&dev);
    printf("vkCreateDevice=%d\n",vr); if(vr!=VK_SUCCESS) return 29;

    uint32_t count=caps.minImageCount<2?2:caps.minImageCount;
    if(caps.maxImageCount && count>caps.maxImageCount) count=caps.maxImageCount;
    VkExtent2D ext=caps.currentExtent;
    if(ext.width==UINT32_MAX){ext.width=320;ext.height=180;}
    VkCompositeAlphaFlagBitsKHR alpha=VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if(!(caps.supportedCompositeAlpha&alpha)){
      VkCompositeAlphaFlagBitsKHR opts[]={VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR};
      for(int i=0;i<3;i++) if(caps.supportedCompositeAlpha&opts[i]){alpha=opts[i];break;}
    }
    VkSwapchainCreateInfoKHR sw={VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,NULL,0,surf,count,fmt.format,fmt.colorSpace,ext,1,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,VK_SHARING_MODE_EXCLUSIVE,0,NULL,caps.currentTransform,alpha,VK_PRESENT_MODE_FIFO_KHR,VK_TRUE,VK_NULL_HANDLE};
    VkSwapchainKHR sc=VK_NULL_HANDLE; vr=vkCreateSwapchainKHR(dev,&sw,NULL,&sc);
    printf("vkCreateSwapchainKHR=%d swapchain=%p\n",vr,(void*)(uintptr_t)sc);
    if(vr==VK_SUCCESS){uint32_t ic=0;vkGetSwapchainImagesKHR(dev,sc,&ic,NULL);printf("swapchain_images=%u\n",ic);puts("TEST14_RESULT=PASS_XLIB_SWAPCHAIN");}
    else puts("TEST14_RESULT=FAIL_SWAPCHAIN");
    if(sc) vkDestroySwapchainKHR(dev,sc,NULL);
    vkDestroyDevice(dev,NULL); vkDestroySurfaceKHR(inst,surf,NULL); XDestroyWindow(dpy,win); XCloseDisplay(dpy); vkDestroyInstance(inst,NULL);
    return vr==VK_SUCCESS?0:30;
}
