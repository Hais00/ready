/* SPDX-License-Identifier: GPL-3.0-only */
/* Read-only query of all 53 DXVK 3.1.1 required feature/extension entries.
 * This creates no Vulkan device and never changes advertised capabilities. */
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(call) do { VkResult r=(call); if(r!=VK_SUCCESS){fprintf(stderr,"%s: %d\n",#call,r);return 2;} }while(0)
#define LOAD(name) PFN_##name name=(PFN_##name)get(instance,#name)
static int has(const VkExtensionProperties *e,uint32_t n,const char *s){for(uint32_t i=0;i<n;i++)if(!strcmp(e[i].extensionName,s))return 1;return 0;}
static void string(const char *s){putchar('"');for(;*s;s++){unsigned char c=*s;if(c=='"'||c=='\\')putchar('\\');if(c>=32)putchar(c);}putchar('"');}
int main(int argc,char **argv){
 if(argc!=2){fprintf(stderr,"usage: KosmicFeaturesProbe /absolute/path/libvulkan.dylib\n");return 1;}
 void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
 PFN_vkGetInstanceProcAddr get=(PFN_vkGetInstanceProcAddr)dlsym(lib,"vkGetInstanceProcAddr");if(!get)return 2;
 PFN_vkCreateInstance create=(PFN_vkCreateInstance)get(NULL,"vkCreateInstance");
 PFN_vkEnumerateInstanceExtensionProperties enumExt=(PFN_vkEnumerateInstanceExtensionProperties)get(NULL,"vkEnumerateInstanceExtensionProperties");
 uint32_t n=0;CHECK(enumExt(NULL,&n,NULL));VkExtensionProperties *exts=calloc(n,sizeof(*exts));CHECK(enumExt(NULL,&n,exts));int portability=has(exts,n,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);free(exts);
 const char *instanceExt[]={VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
 VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="ready-kosmic-features",.apiVersion=VK_API_VERSION_1_3};
 VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.flags=portability?VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR:0,.enabledExtensionCount=portability?1:0,.ppEnabledExtensionNames=instanceExt};VkInstance instance;CHECK(create(&ci,NULL,&instance));
 LOAD(vkEnumeratePhysicalDevices);LOAD(vkGetPhysicalDeviceFeatures2);LOAD(vkGetPhysicalDeviceProperties);LOAD(vkEnumerateDeviceExtensionProperties);LOAD(vkGetPhysicalDeviceQueueFamilyProperties);LOAD(vkDestroyInstance);
 n=0;CHECK(vkEnumeratePhysicalDevices(instance,&n,NULL));if(!n)return 3;VkPhysicalDevice *devices=calloc(n,sizeof(*devices));CHECK(vkEnumeratePhysicalDevices(instance,&n,devices));VkPhysicalDevice gpu=devices[0];free(devices);
 VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(gpu,&props);
 n=0;CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&n,NULL));exts=calloc(n,sizeof(*exts));CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&n,exts));
 VkPhysicalDeviceMaintenance6FeaturesKHR khrMaintenance6={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR};
 VkPhysicalDeviceMaintenance5FeaturesKHR khrMaintenance5={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR,.pNext=&khrMaintenance6};
 VkPhysicalDeviceRobustness2FeaturesEXT extRobustness2={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,.pNext=&khrMaintenance5};
 VkPhysicalDeviceDepthClipEnableFeaturesEXT extDepthClipEnable={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT,.pNext=&extRobustness2};
 VkPhysicalDeviceVulkan13Features vk13={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,.pNext=&extDepthClipEnable};
 VkPhysicalDeviceVulkan12Features vk12={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,.pNext=&vk13};
 VkPhysicalDeviceVulkan11Features vk11={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,.pNext=&vk12};
 VkPhysicalDeviceFeatures2 core={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&vk11};vkGetPhysicalDeviceFeatures2(gpu,&core);
 int khrLoadStoreOpNone=has(exts,n,VK_KHR_LOAD_STORE_OP_NONE_EXTENSION_NAME);
 int khrSwapchain=has(exts,n,VK_KHR_SWAPCHAIN_EXTENSION_NAME);
 /* DXVK's extension table requires these extension names in addition to bits. */
 if(!has(exts,n,VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME))extDepthClipEnable.depthClipEnable=0;
 if(!has(exts,n,VK_EXT_ROBUSTNESS_2_EXTENSION_NAME)){extRobustness2.robustBufferAccess2=0;extRobustness2.nullDescriptor=0;}
 if(!has(exts,n,VK_KHR_MAINTENANCE_5_EXTENSION_NAME))khrMaintenance5.maintenance5=0;
 if(!has(exts,n,VK_KHR_MAINTENANCE_6_EXTENSION_NAME))khrMaintenance6.maintenance6=0;
 int portabilitySubset=has(exts,n,"VK_KHR_portability_subset");free(exts);
 uint32_t nq=0;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&nq,NULL);VkQueueFamilyProperties *queues=calloc(nq,sizeof(*queues));vkGetPhysicalDeviceQueueFamilyProperties(gpu,&nq,queues);int graphics=0;for(uint32_t i=0;i<nq;i++)if(queues[i].queueCount&&(queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT))graphics=1;free(queues);
 struct Entry{const char *name;int supported;} entries[]={
  {"core.features.depthBiasClamp",core.features.depthBiasClamp},
  {"core.features.depthClamp",core.features.depthClamp},
  {"core.features.dualSrcBlend",core.features.dualSrcBlend},
  {"core.features.fillModeNonSolid",core.features.fillModeNonSolid},
  {"core.features.fragmentStoresAndAtomics",core.features.fragmentStoresAndAtomics},
  {"core.features.fullDrawIndexUint32",core.features.fullDrawIndexUint32},
  {"core.features.geometryShader",core.features.geometryShader},
  {"core.features.imageCubeArray",core.features.imageCubeArray},
  {"core.features.independentBlend",core.features.independentBlend},
  {"core.features.multiDrawIndirect",core.features.multiDrawIndirect},
  {"core.features.multiViewport",core.features.multiViewport},
  {"core.features.occlusionQueryPrecise",core.features.occlusionQueryPrecise},
  {"core.features.robustBufferAccess",core.features.robustBufferAccess},
  {"core.features.sampleRateShading",core.features.sampleRateShading},
  {"core.features.samplerAnisotropy",core.features.samplerAnisotropy},
  {"core.features.shaderClipDistance",core.features.shaderClipDistance},
  {"core.features.shaderCullDistance",core.features.shaderCullDistance},
  {"core.features.shaderImageGatherExtended",core.features.shaderImageGatherExtended},
  {"core.features.shaderInt16",core.features.shaderInt16},
  {"core.features.shaderInt64",core.features.shaderInt64},
  {"core.features.shaderSampledImageArrayDynamicIndexing",core.features.shaderSampledImageArrayDynamicIndexing},
  {"core.features.textureCompressionBC",core.features.textureCompressionBC},
  {"vk11.shaderDrawParameters",vk11.shaderDrawParameters},
  {"vk11.storageBuffer16BitAccess",vk11.storageBuffer16BitAccess},
  {"vk12.bufferDeviceAddress",vk12.bufferDeviceAddress},
  {"vk12.descriptorIndexing",vk12.descriptorIndexing},
  {"vk12.storageBuffer8BitAccess",vk12.storageBuffer8BitAccess},
  {"vk12.descriptorBindingSampledImageUpdateAfterBind",vk12.descriptorBindingSampledImageUpdateAfterBind},
  {"vk12.descriptorBindingUpdateUnusedWhilePending",vk12.descriptorBindingUpdateUnusedWhilePending},
  {"vk12.descriptorBindingPartiallyBound",vk12.descriptorBindingPartiallyBound},
  {"vk12.hostQueryReset",vk12.hostQueryReset},
  {"vk12.runtimeDescriptorArray",vk12.runtimeDescriptorArray},
  {"vk12.samplerMirrorClampToEdge",vk12.samplerMirrorClampToEdge},
  {"vk12.scalarBlockLayout",vk12.scalarBlockLayout},
  {"vk12.shaderInt8",vk12.shaderInt8},
  {"vk12.timelineSemaphore",vk12.timelineSemaphore},
  {"vk12.uniformBufferStandardLayout",vk12.uniformBufferStandardLayout},
  {"vk12.vulkanMemoryModel",vk12.vulkanMemoryModel},
  {"vk13.inlineUniformBlock",vk13.inlineUniformBlock},
  {"vk13.computeFullSubgroups",vk13.computeFullSubgroups},
  {"vk13.dynamicRendering",vk13.dynamicRendering},
  {"vk13.maintenance4",vk13.maintenance4},
  {"vk13.shaderDemoteToHelperInvocation",vk13.shaderDemoteToHelperInvocation},
  {"vk13.shaderZeroInitializeWorkgroupMemory",vk13.shaderZeroInitializeWorkgroupMemory},
  {"vk13.subgroupSizeControl",vk13.subgroupSizeControl},
  {"vk13.synchronization2",vk13.synchronization2},
  {"extDepthClipEnable.depthClipEnable",extDepthClipEnable.depthClipEnable},
  {"extRobustness2.robustBufferAccess2",extRobustness2.robustBufferAccess2},
  {"extRobustness2.nullDescriptor",extRobustness2.nullDescriptor},
  {"khrLoadStoreOpNone",khrLoadStoreOpNone},
  {"khrMaintenance5.maintenance5",khrMaintenance5.maintenance5},
  {"khrMaintenance6.maintenance6",khrMaintenance6.maintenance6},
  {"khrSwapchain",khrSwapchain},
 };
 const size_t total=sizeof(entries)/sizeof(entries[0]);unsigned missing=0;for(size_t i=0;i<total;i++)if(!entries[i].supported)missing++;
 printf("{\"schema\":1,\"device\":");string(props.deviceName);printf(",\"api\":\"%u.%u.%u\",\"requiredEntryCount\":%zu,\"graphicsQueue\":%s,\"apiAtLeast13\":%s,\"maxPushConstantsSize\":%u,\"portabilitySubset\":%s,\"features\":{",VK_API_VERSION_MAJOR(props.apiVersion),VK_API_VERSION_MINOR(props.apiVersion),VK_API_VERSION_PATCH(props.apiVersion),total,graphics?"true":"false",props.apiVersion>=VK_API_VERSION_1_3?"true":"false",props.limits.maxPushConstantsSize,portabilitySubset?"true":"false");
 for(size_t i=0;i<total;i++){if(i)putchar(',');string(entries[i].name);printf(":%s",entries[i].supported?"true":"false");}
 printf("},\"missingFeatures\":[");int comma=0;for(size_t i=0;i<total;i++)if(!entries[i].supported){if(comma++)putchar(',');string(entries[i].name);}
 int compatible=!missing&&graphics&&props.apiVersion>=VK_API_VERSION_1_3&&props.limits.maxPushConstantsSize>=256;
 printf("],\"requiredFeaturesSatisfied\":%s,\"rasterizationVerified\":false}\n",compatible?"true":"false");vkDestroyInstance(instance,NULL);dlclose(lib);return 0;
}
