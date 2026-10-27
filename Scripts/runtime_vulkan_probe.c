/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Exercise a real ICD, device, queue, GPU transfer, and host-visible readback. */
#include <vulkan/vulkan.h>
#if defined(_WIN32)
#include <stddef.h>
int _fltused=0;
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *,const char *);
__declspec(dllimport) int __stdcall FreeLibrary(void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned long);
__declspec(dllimport) int __cdecl printf(const char *,...);
__declspec(dllimport) void *__cdecl calloc(size_t,size_t);
__declspec(dllimport) void __cdecl free(void *);
__declspec(dllimport) int __cdecl strcmp(const char *,const char *);
#define RTLD_NOW 0
#define RTLD_LOCAL 0
#define stderr NULL
#define fprintf(stream, ...) printf(__VA_ARGS__)
static void *dlopen(const char *path,int flags){(void)flags;return LoadLibraryA(path);}
static void *dlsym(void *handle,const char *name){return GetProcAddress(handle,name);}
static int dlclose(void *handle){return FreeLibrary(handle);}
static const char *dlerror(void){return "Windows LoadLibraryA/GetProcAddress failed";}
#else
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#endif

#define LOAD_INSTANCE(name) PFN_##name name = (PFN_##name)getProc(instance, #name)
#define CHECK(call) do { VkResult r=(call); if(r!=VK_SUCCESS){fprintf(stderr,"%s failed: %d\n",#call,r);return 2;} } while(0)

int main(int argc, char **argv) {
    if(argc!=2){fprintf(stderr,"usage: runtime_vulkan_probe /absolute/path/libvulkan.dylib\n");return 1;}
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!lib){fprintf(stderr,"dlopen: %s\n",dlerror());return 2;}
    PFN_vkGetInstanceProcAddr getProc=(PFN_vkGetInstanceProcAddr)dlsym(lib,"vkGetInstanceProcAddr");
    if(!getProc){fprintf(stderr,"missing vkGetInstanceProcAddr\n");return 2;}
    PFN_vkCreateInstance createInstance=(PFN_vkCreateInstance)getProc(NULL,"vkCreateInstance");
    PFN_vkEnumerateInstanceExtensionProperties enumExt=(PFN_vkEnumerateInstanceExtensionProperties)getProc(NULL,"vkEnumerateInstanceExtensionProperties");
    uint32_t extCount=0;CHECK(enumExt(NULL,&extCount,NULL));
    VkExtensionProperties *exts=calloc(extCount,sizeof(*exts));CHECK(enumExt(NULL,&extCount,exts));
    int portability=0;for(uint32_t i=0;i<extCount;i++)if(!strcmp(exts[i].extensionName,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME))portability=1;
    free(exts);
    const char *extensions[]={VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="ready-runtime-probe",.apiVersion=VK_API_VERSION_1_3};
    VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.enabledExtensionCount=portability?1:0,.ppEnabledExtensionNames=extensions,.flags=portability?VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR:0};
    VkInstance instance;CHECK(createInstance(&ci,NULL,&instance));
    LOAD_INSTANCE(vkEnumeratePhysicalDevices);LOAD_INSTANCE(vkGetPhysicalDeviceProperties);LOAD_INSTANCE(vkGetPhysicalDeviceQueueFamilyProperties);LOAD_INSTANCE(vkGetPhysicalDeviceMemoryProperties);LOAD_INSTANCE(vkCreateDevice);LOAD_INSTANCE(vkGetDeviceProcAddr);LOAD_INSTANCE(vkEnumerateDeviceExtensionProperties);LOAD_INSTANCE(vkDestroyInstance);
    uint32_t count=0;CHECK(vkEnumeratePhysicalDevices(instance,&count,NULL));if(!count){fprintf(stderr,"no physical devices\n");return 3;}
    VkPhysicalDevice *physical=calloc(count,sizeof(*physical));CHECK(vkEnumeratePhysicalDevices(instance,&count,physical));
    VkPhysicalDevice gpu=physical[0];free(physical);VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(gpu,&props);
    uint32_t queueCount=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queueCount,NULL);VkQueueFamilyProperties *families=calloc(queueCount,sizeof(*families));vkGetPhysicalDeviceQueueFamilyProperties(gpu,&queueCount,families);
    uint32_t family=0;for(;family<queueCount;family++)if(families[family].queueFlags&VK_QUEUE_TRANSFER_BIT)break;free(families);if(family==queueCount)return 3;
    float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
    uint32_t deviceExtCount=0;CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&deviceExtCount,NULL));exts=calloc(deviceExtCount,sizeof(*exts));CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&deviceExtCount,exts));
    int subset=0;for(uint32_t i=0;i<deviceExtCount;i++)if(!strcmp(exts[i].extensionName,"VK_KHR_portability_subset"))subset=1;free(exts);const char *deviceExts[]={"VK_KHR_portability_subset"};
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=subset?1:0,.ppEnabledExtensionNames=deviceExts};VkDevice device;CHECK(vkCreateDevice(gpu,&di,NULL,&device));
#define LD(name) PFN_##name name=(PFN_##name)vkGetDeviceProcAddr(device,#name)
    LD(vkGetDeviceQueue);LD(vkCreateBuffer);LD(vkGetBufferMemoryRequirements);LD(vkAllocateMemory);LD(vkBindBufferMemory);LD(vkCreateCommandPool);LD(vkAllocateCommandBuffers);LD(vkBeginCommandBuffer);LD(vkCmdFillBuffer);LD(vkEndCommandBuffer);LD(vkQueueSubmit);LD(vkQueueWaitIdle);LD(vkMapMemory);LD(vkUnmapMemory);LD(vkDestroyCommandPool);LD(vkDestroyBuffer);LD(vkFreeMemory);LD(vkDestroyDevice);
    VkQueue queue;vkGetDeviceQueue(device,family,0,&queue);
    VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=4096,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};VkBuffer buffer;CHECK(vkCreateBuffer(device,&bi,NULL,&buffer));
    VkMemoryRequirements req;vkGetBufferMemoryRequirements(device,buffer,&req);VkPhysicalDeviceMemoryProperties mem;vkGetPhysicalDeviceMemoryProperties(gpu,&mem);
    uint32_t type=0;for(;type<mem.memoryTypeCount;type++)if((req.memoryTypeBits&(1u<<type))&&((mem.memoryTypes[type].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)))break;
    if(type==mem.memoryTypeCount){fprintf(stderr,"no coherent host-visible type\n");return 3;}
    VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=type};VkDeviceMemory memory;CHECK(vkAllocateMemory(device,&ai,NULL,&memory));CHECK(vkBindBufferMemory(device,buffer,memory,0));
    VkCommandPoolCreateInfo pi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=family};VkCommandPool pool;CHECK(vkCreateCommandPool(device,&pi,NULL,&pool));
    VkCommandBufferAllocateInfo ca={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};VkCommandBuffer cmd;CHECK(vkAllocateCommandBuffers(device,&ca,&cmd));
    VkCommandBufferBeginInfo cb={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};CHECK(vkBeginCommandBuffer(cmd,&cb));vkCmdFillBuffer(cmd,buffer,0,4096,0x7ab31e55);CHECK(vkEndCommandBuffer(cmd));VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));CHECK(vkQueueWaitIdle(queue));
    uint32_t *mapped;CHECK(vkMapMemory(device,memory,0,4096,0,(void **)&mapped));int valid=1;for(int i=0;i<1024;i++)if(mapped[i]!=0x7ab31e55)valid=0;vkUnmapMemory(device,memory);
    printf("{\"device\":\"%s\",\"api\":\"%u.%u.%u\",\"driverVersion\":%u,\"transferBytes\":4096,\"readbackVerified\":%s}\n",props.deviceName,VK_API_VERSION_MAJOR(props.apiVersion),VK_API_VERSION_MINOR(props.apiVersion),VK_API_VERSION_PATCH(props.apiVersion),props.driverVersion,valid?"true":"false");
    vkDestroyCommandPool(device,pool,NULL);vkDestroyBuffer(device,buffer,NULL);vkFreeMemory(device,memory,NULL);vkDestroyDevice(device,NULL);vkDestroyInstance(instance,NULL);dlclose(lib);return valid?0:4;
}
#if defined(_WIN32)
void mainCRTStartup(void){char *args[]={"runtime_vulkan_probe","vulkan-1.dll"};ExitProcess((unsigned long)main(2,args));}
#endif
