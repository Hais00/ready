/* SPDX-License-Identifier: GPL-3.0-only */
/* A real Windows Vulkan window: a render-pass clear presents through Wine's Metal surface. */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stddef.h>
typedef void *HWND;typedef void *HINSTANCE;typedef uint32_t DWORD;typedef uint16_t WCHAR;
typedef intptr_t (__stdcall *WndProc)(HWND,uint32_t,uintptr_t,intptr_t);
#define IMPORT __declspec(dllimport)
IMPORT void *__stdcall GetModuleHandleW(const WCHAR *);
IMPORT void *__stdcall LoadLibraryA(const char *);
IMPORT void *__stdcall GetProcAddress(void *,const char *);
IMPORT void __stdcall ExitProcess(DWORD);
IMPORT int __cdecl printf(const char *,...);
IMPORT void *__cdecl calloc(size_t,size_t);
IMPORT void __cdecl free(void *);
IMPORT int __cdecl strcmp(const char *,const char *);
struct WindowClass {uint32_t style;WndProc proc;int clsExtra,wndExtra;HINSTANCE instance;void *icon,*cursor,*background;const WCHAR *menu,*name;};
struct Message {HWND hwnd;uint32_t message;uintptr_t wparam;intptr_t lparam;uint32_t time;int x,y;uint32_t privateValue;};
struct Rect {int left,top,right,bottom;};
IMPORT uint16_t __stdcall RegisterClassW(const struct WindowClass *);
IMPORT HWND __stdcall CreateWindowExW(DWORD,const WCHAR *,const WCHAR *,DWORD,int,int,int,int,HWND,void *,HINSTANCE,void *);
IMPORT intptr_t __stdcall DefWindowProcW(HWND,uint32_t,uintptr_t,intptr_t);
IMPORT int __stdcall ShowWindow(HWND,int);
IMPORT int __stdcall UpdateWindow(HWND);
IMPORT int __stdcall PeekMessageW(struct Message *,HWND,uint32_t,uint32_t,uint32_t);
IMPORT int __stdcall TranslateMessage(const struct Message *);
IMPORT intptr_t __stdcall DispatchMessageW(const struct Message *);
IMPORT int __stdcall DestroyWindow(HWND);
IMPORT void __stdcall PostQuitMessage(int);
IMPORT int __stdcall GetClientRect(HWND,struct Rect *);
int _fltused=0;

typedef struct {VkStructureType sType;const void *pNext;VkFlags flags;HINSTANCE hinstance;HWND hwnd;} Win32SurfaceInfo;
typedef VkResult (VKAPI_PTR *CreateWin32Surface)(VkInstance,const Win32SurfaceInfo *,const VkAllocationCallbacks *,VkSurfaceKHR *);
#define CHECK(call) do {VkResult result=(call);if(result!=VK_SUCCESS){printf("{\"stage\":\"%s\",\"vkResult\":%d}\n",#call,result);return 2;}}while(0)
#define LI(name) PFN_##name name=(PFN_##name)getProc(instance,#name)
#define LD(name) PFN_##name name=(PFN_##name)vkGetDeviceProcAddr(device,#name)

static intptr_t __stdcall windowProc(HWND hwnd,uint32_t msg,uintptr_t wp,intptr_t lp){
    if(msg==0x10){DestroyWindow(hwnd);return 0;}if(msg==2){PostQuitMessage(0);return 0;}return DefWindowProcW(hwnd,msg,wp,lp);
}

static int run(void){
    HINSTANCE module=GetModuleHandleW(NULL);struct WindowClass cls={0x20,windowProc,0,0,module,NULL,NULL,NULL,NULL,L"ReadyVulkanProbe"};
    if(!RegisterClassW(&cls))return 1;
    HWND hwnd=CreateWindowExW(0,L"ReadyVulkanProbe",L"Ready · Windows Vulkan presentation probe",0x00cf0000,80,80,960,600,NULL,NULL,module,NULL);
    if(!hwnd)return 1;ShowWindow(hwnd,5);UpdateWindow(hwnd);
    void *loader=LoadLibraryA("vulkan-1.dll");if(!loader){printf("vulkan-1.dll unavailable\n");return 2;}
    PFN_vkGetInstanceProcAddr getProc=(PFN_vkGetInstanceProcAddr)GetProcAddress(loader,"vkGetInstanceProcAddr");
    PFN_vkCreateInstance create=(PFN_vkCreateInstance)getProc(NULL,"vkCreateInstance");
    const char *extensions[]={"VK_KHR_surface","VK_KHR_win32_surface"};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Ready Windows Vulkan present probe",.apiVersion=VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.enabledExtensionCount=2,.ppEnabledExtensionNames=extensions};VkInstance instance;CHECK(create(&ici,NULL,&instance));
    LI(vkEnumeratePhysicalDevices);LI(vkGetPhysicalDeviceProperties);LI(vkGetPhysicalDeviceQueueFamilyProperties);LI(vkGetPhysicalDeviceSurfaceSupportKHR);LI(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);LI(vkGetPhysicalDeviceSurfaceFormatsKHR);LI(vkCreateDevice);LI(vkGetDeviceProcAddr);LI(vkDestroySurfaceKHR);LI(vkDestroyInstance);
    VkSurfaceKHR surface;CreateWin32Surface createSurface=(CreateWin32Surface)getProc(instance,"vkCreateWin32SurfaceKHR");Win32SurfaceInfo wi={VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,NULL,0,module,hwnd};CHECK(createSurface(instance,&wi,NULL,&surface));
    uint32_t count=0;CHECK(vkEnumeratePhysicalDevices(instance,&count,NULL));if(!count)return 2;VkPhysicalDevice *physical=calloc(count,sizeof(*physical));CHECK(vkEnumeratePhysicalDevices(instance,&count,physical));VkPhysicalDevice gpu=physical[0];free(physical);
    VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(gpu,&properties);
    uint32_t queueCount=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queueCount,NULL);VkQueueFamilyProperties *families=calloc(queueCount,sizeof(*families));vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queueCount,families);uint32_t family=0;
    for(;family<queueCount;family++){VkBool32 support=0;CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(gpu,family,surface,&support));if(support&&(families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))break;}free(families);if(family==queueCount)return 2;
    float priority=1.0f;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};const char *deviceExtensions[]={"VK_KHR_swapchain"};VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=1,.ppEnabledExtensionNames=deviceExtensions};VkDevice device;CHECK(vkCreateDevice(gpu,&dci,NULL,&device));
    LD(vkGetDeviceQueue);LD(vkCreateSwapchainKHR);LD(vkGetSwapchainImagesKHR);LD(vkCreateImageView);LD(vkCreateRenderPass);LD(vkCreateFramebuffer);LD(vkCreateCommandPool);LD(vkAllocateCommandBuffers);LD(vkCreateSemaphore);LD(vkAcquireNextImageKHR);LD(vkResetCommandBuffer);LD(vkBeginCommandBuffer);LD(vkCmdBeginRenderPass);LD(vkCmdEndRenderPass);LD(vkEndCommandBuffer);LD(vkQueueSubmit);LD(vkQueuePresentKHR);LD(vkQueueWaitIdle);LD(vkDeviceWaitIdle);LD(vkDestroySemaphore);LD(vkDestroyCommandPool);LD(vkDestroyFramebuffer);LD(vkDestroyRenderPass);LD(vkDestroyImageView);LD(vkDestroySwapchainKHR);LD(vkDestroyDevice);
    VkQueue queue;vkGetDeviceQueue(device,family,0,&queue);
    VkSurfaceCapabilitiesKHR caps;CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu,surface,&caps));
    uint32_t formatCount=0;CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surface,&formatCount,NULL));if(!formatCount)return 2;VkSurfaceFormatKHR *formats=calloc(formatCount,sizeof(*formats));CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surface,&formatCount,formats));VkSurfaceFormatKHR format=formats[0];for(uint32_t i=0;i<formatCount;i++)if(formats[i].format==VK_FORMAT_B8G8R8A8_UNORM)format=formats[i];free(formats);
    struct Rect rect;GetClientRect(hwnd,&rect);VkExtent2D extent=caps.currentExtent;if(extent.width==0xffffffffu)extent=(VkExtent2D){(uint32_t)(rect.right-rect.left),(uint32_t)(rect.bottom-rect.top)};
    uint32_t images=caps.minImageCount>2?caps.minImageCount:2;if(caps.maxImageCount&&images>caps.maxImageCount)images=caps.maxImageCount;
    VkSwapchainCreateInfoKHR sci={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,.surface=surface,.minImageCount=images,.imageFormat=format.format,.imageColorSpace=format.colorSpace,.imageExtent=extent,.imageArrayLayers=1,.imageUsage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE,.preTransform=caps.currentTransform,.compositeAlpha=VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,.presentMode=VK_PRESENT_MODE_FIFO_KHR,.clipped=VK_TRUE};VkSwapchainKHR swapchain;CHECK(vkCreateSwapchainKHR(device,&sci,NULL,&swapchain));
    CHECK(vkGetSwapchainImagesKHR(device,swapchain,&images,NULL));VkImage *backbuffers=calloc(images,sizeof(*backbuffers));CHECK(vkGetSwapchainImagesKHR(device,swapchain,&images,backbuffers));VkImageView *views=calloc(images,sizeof(*views));VkFramebuffer *framebuffers=calloc(images,sizeof(*framebuffers));
    VkAttachmentDescription attachment={.format=format.format,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR,.storeOp=VK_ATTACHMENT_STORE_OP_STORE,.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED,.finalLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR};VkAttachmentReference reference={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription subpass={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&reference};VkRenderPassCreateInfo rp={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=1,.pAttachments=&attachment,.subpassCount=1,.pSubpasses=&subpass};VkRenderPass renderPass;CHECK(vkCreateRenderPass(device,&rp,NULL,&renderPass));
    for(uint32_t i=0;i<images;i++){VkImageViewCreateInfo vi={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=backbuffers[i],.viewType=VK_IMAGE_VIEW_TYPE_2D,.format=format.format,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};CHECK(vkCreateImageView(device,&vi,NULL,&views[i]));VkFramebufferCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,.renderPass=renderPass,.attachmentCount=1,.pAttachments=&views[i],.width=extent.width,.height=extent.height,.layers=1};CHECK(vkCreateFramebuffer(device,&fi,NULL,&framebuffers[i]));}
    VkCommandPoolCreateInfo cp={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=family};VkCommandPool pool;CHECK(vkCreateCommandPool(device,&cp,NULL,&pool));VkCommandBufferAllocateInfo cba={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};VkCommandBuffer cmd;CHECK(vkAllocateCommandBuffers(device,&cba,&cmd));VkSemaphoreCreateInfo se={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};VkSemaphore acquired,rendered;CHECK(vkCreateSemaphore(device,&se,NULL,&acquired));CHECK(vkCreateSemaphore(device,&se,NULL,&rendered));
    uint32_t frame=0;int running=1;for(;frame<600&&running;frame++){
        struct Message message;while(PeekMessageW(&message,NULL,0,0,1)){if(message.message==0x12){running=0;break;}TranslateMessage(&message);DispatchMessageW(&message);}if(!running)break;
        uint32_t image;VkResult acquire=vkAcquireNextImageKHR(device,swapchain,UINT64_MAX,acquired,VK_NULL_HANDLE,&image);if(acquire!=VK_SUCCESS&&acquire!=VK_SUBOPTIMAL_KHR){printf("acquire=%d\n",acquire);break;}
        CHECK(vkResetCommandBuffer(cmd,0));VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};CHECK(vkBeginCommandBuffer(cmd,&begin));
        VkClearValue clear={.color={{0.035f,0.09f,0.15f,1.0f}}};VkRenderPassBeginInfo pass={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,.renderPass=renderPass,.framebuffer=framebuffers[image],.renderArea={{0,0},extent},.clearValueCount=1,.pClearValues=&clear};vkCmdBeginRenderPass(cmd,&pass,VK_SUBPASS_CONTENTS_INLINE);vkCmdEndRenderPass(cmd);CHECK(vkEndCommandBuffer(cmd));
        VkPipelineStageFlags stage=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.waitSemaphoreCount=1,.pWaitSemaphores=&acquired,.pWaitDstStageMask=&stage,.commandBufferCount=1,.pCommandBuffers=&cmd,.signalSemaphoreCount=1,.pSignalSemaphores=&rendered};CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));VkPresentInfoKHR present={.sType=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,.waitSemaphoreCount=1,.pWaitSemaphores=&rendered,.swapchainCount=1,.pSwapchains=&swapchain,.pImageIndices=&image};VkResult pr=vkQueuePresentKHR(queue,&present);CHECK(vkQueueWaitIdle(queue));if(pr!=VK_SUCCESS&&pr!=VK_SUBOPTIMAL_KHR){printf("present=%d\n",pr);break;}
    }
    CHECK(vkDeviceWaitIdle(device));printf("{\"device\":\"%s\",\"presentedFrames\":%u,\"width\":%u,\"height\":%u,\"directToDisplayVerified\":false}\n",properties.deviceName,frame,extent.width,extent.height);
    vkDestroySemaphore(device,acquired,NULL);vkDestroySemaphore(device,rendered,NULL);vkDestroyCommandPool(device,pool,NULL);for(uint32_t i=0;i<images;i++){vkDestroyFramebuffer(device,framebuffers[i],NULL);vkDestroyImageView(device,views[i],NULL);}vkDestroyRenderPass(device,renderPass,NULL);vkDestroySwapchainKHR(device,swapchain,NULL);vkDestroyDevice(device,NULL);vkDestroySurfaceKHR(instance,surface,NULL);vkDestroyInstance(instance,NULL);DestroyWindow(hwnd);return frame>=60?0:3;
}
void mainCRTStartup(void){ExitProcess((DWORD)run());}
