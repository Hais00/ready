/* SPDX-License-Identifier: GPL-3.0-only
 * Read-only native reproduction of the vkd3d-proton v3.0.1 Properties2 chain.
 * Uses actual Khronos Vulkan headers; never changes advertised capabilities.
 * Table order is the SOURCE prepend order in libs/vkd3d/device.c, so the
 * submitted pNext traversal order is its reverse, exactly like vk_prepend_struct.
 */
#include <vulkan/vulkan.h>
#ifndef READY_PROPERTIES_WINDOWS
#include <dlfcn.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifndef READY_PROPERTIES_WINDOWS
#include <sys/sysctl.h>
#endif

typedef struct {
    const char *name, *type;
    size_t size;
    VkStructureType sType;
    const char *required[3];
} PropertyCase;
#define C(name,type,stype,a,b,c) {#name,#type,sizeof(type),stype,{a,b,c}}
static const PropertyCase cases[] = {
 C(vulkan_1_1_properties,VkPhysicalDeviceVulkan11Properties,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES,NULL,NULL,NULL),
 C(vulkan_1_2_properties,VkPhysicalDeviceVulkan12Properties,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES,NULL,NULL,NULL),
 C(vulkan_1_3_properties,VkPhysicalDeviceVulkan13Properties,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES,NULL,NULL,NULL),
 C(push_descriptor_properties,VkPhysicalDevicePushDescriptorPropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PUSH_DESCRIPTOR_PROPERTIES_KHR,"VK_KHR_push_descriptor",NULL,NULL),
 C(conservative_rasterization_properties,VkPhysicalDeviceConservativeRasterizationPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CONSERVATIVE_RASTERIZATION_PROPERTIES_EXT,"VK_EXT_conservative_rasterization",NULL,NULL),
 C(custom_border_color_properties,VkPhysicalDeviceCustomBorderColorPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_PROPERTIES_EXT,"VK_EXT_custom_border_color",NULL,NULL),
 C(device_generated_commands_properties,VkPhysicalDeviceDeviceGeneratedCommandsPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEVICE_GENERATED_COMMANDS_PROPERTIES_EXT,"VK_EXT_device_generated_commands",NULL,NULL),
 C(robustness2_properties,VkPhysicalDeviceRobustness2PropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_PROPERTIES_EXT,"VK_EXT_robustness2",NULL,NULL),
 C(xfb_properties,VkPhysicalDeviceTransformFeedbackPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT,"VK_EXT_transform_feedback",NULL,NULL),
 C(vertex_divisor_properties,VkPhysicalDeviceVertexAttributeDivisorPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_PROPERTIES_EXT,"VK_EXT_vertex_attribute_divisor",NULL,NULL),
 C(external_memory_host_properties,VkPhysicalDeviceExternalMemoryHostPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT,"VK_EXT_external_memory_host",NULL,NULL),
 C(shader_core_properties,VkPhysicalDeviceShaderCorePropertiesAMD,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_CORE_PROPERTIES_AMD,"VK_AMD_shader_core_properties",NULL,NULL),
 C(shader_core_properties2,VkPhysicalDeviceShaderCoreProperties2AMD,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_CORE_PROPERTIES_2_AMD,"VK_AMD_shader_core_properties2",NULL,NULL),
 C(shader_sm_builtins_properties,VkPhysicalDeviceShaderSMBuiltinsPropertiesNV,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_SM_BUILTINS_PROPERTIES_NV,"VK_NV_shader_sm_builtins",NULL,NULL),
 C(acceleration_structure_properties,VkPhysicalDeviceAccelerationStructurePropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR,"VK_KHR_acceleration_structure","VK_KHR_ray_tracing_pipeline","VK_KHR_deferred_host_operations"),
 C(ray_tracing_pipeline_properties,VkPhysicalDeviceRayTracingPipelinePropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_PROPERTIES_KHR,"VK_KHR_acceleration_structure","VK_KHR_ray_tracing_pipeline","VK_KHR_deferred_host_operations"),
 C(fragment_shading_rate_properties,VkPhysicalDeviceFragmentShadingRatePropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_PROPERTIES_KHR,"VK_KHR_fragment_shading_rate",NULL,NULL),
 C(mesh_shader_properties,VkPhysicalDeviceMeshShaderPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT,"VK_EXT_mesh_shader",NULL,NULL),
 C(shader_module_identifier_properties,VkPhysicalDeviceShaderModuleIdentifierPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_MODULE_IDENTIFIER_PROPERTIES_EXT,"VK_EXT_shader_module_identifier",NULL,NULL),
 C(maintenance_5_properties,VkPhysicalDeviceMaintenance5PropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_PROPERTIES_KHR,"VK_KHR_maintenance5",NULL,NULL),
 C(maintenance_6_properties,VkPhysicalDeviceMaintenance6PropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_PROPERTIES_KHR,"VK_KHR_maintenance6",NULL,NULL),
 C(maintenance_7_properties,VkPhysicalDeviceMaintenance7PropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_7_PROPERTIES_KHR,"VK_KHR_maintenance7",NULL,NULL),
 C(layered_props_list,VkPhysicalDeviceLayeredApiPropertiesListKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_LIST_KHR,"VK_KHR_maintenance7",NULL,NULL),
 C(maintenance_10_properties,VkPhysicalDeviceMaintenance10PropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_10_PROPERTIES_KHR,"VK_KHR_maintenance10",NULL,NULL),
 C(compute_shader_derivatives_properties_khr,VkPhysicalDeviceComputeShaderDerivativesPropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_COMPUTE_SHADER_DERIVATIVES_PROPERTIES_KHR,"VK_KHR_compute_shader_derivatives",NULL,NULL),
 C(descriptor_buffer_properties,VkPhysicalDeviceDescriptorBufferPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,"VK_EXT_descriptor_buffer",NULL,NULL),
 C(graphics_pipeline_library_properties,VkPhysicalDeviceGraphicsPipelineLibraryPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GRAPHICS_PIPELINE_LIBRARY_PROPERTIES_EXT,"VK_EXT_graphics_pipeline_library",NULL,NULL),
 C(line_rasterization_properties,VkPhysicalDeviceLineRasterizationPropertiesEXT,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LINE_RASTERIZATION_PROPERTIES_EXT,"VK_EXT_line_rasterization",NULL,NULL),
 C(memory_decompression_properties,VkPhysicalDeviceMemoryDecompressionPropertiesNV,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_DECOMPRESSION_PROPERTIES_NV,"VK_NV_memory_decompression",NULL,NULL),
 C(image_alignment_control_properties,VkPhysicalDeviceImageAlignmentControlPropertiesMESA,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_ALIGNMENT_CONTROL_PROPERTIES_MESA,"VK_MESA_image_alignment_control",NULL,NULL),
 C(cooperative_matrix_properties,VkPhysicalDeviceCooperativeMatrixPropertiesKHR,VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_COOPERATIVE_MATRIX_PROPERTIES_KHR,"VK_KHR_cooperative_matrix",NULL,NULL)
};
#undef C
#define COUNT (sizeof(cases)/sizeof(cases[0]))
#define CHECK(call) do{VkResult result=(call);if(result!=VK_SUCCESS){fprintf(stderr,"%s returned %d\n",#call,result);return 2;}}while(0)
#define LOAD(name) PFN_##name name=(PFN_##name)get(instance,#name)
static void json_string(const char *value){putchar('"');for(;*value;value++){unsigned char c=*value;if(c=='"'||c=='\\')putchar('\\');if(c>=32)putchar(c);}putchar('"');}
static int has(const VkExtensionProperties *extensions,uint32_t count,const char *name){for(uint32_t i=0;i<count;i++)if(!strcmp(extensions[i].extensionName,name))return 1;return 0;}
static int supported(const PropertyCase *entry,const VkExtensionProperties *extensions,uint32_t count){for(size_t i=0;i<3;i++)if(entry->required[i]&&!has(extensions,count,entry->required[i]))return 0;return 1;}

typedef struct {unsigned char *allocation;VkBaseOutStructure *payload;size_t size;VkStructureType sType;void *next;} Guard;
static Guard guards[64];static size_t guard_count;
static void *allocate_guarded(size_t size,VkStructureType sType){
    if(guard_count>=64)exit(70);
    unsigned char *memory=malloc(size+128);if(!memory)exit(71);memset(memory,0xa5,size+128);memset(memory+64,0,size);
    VkBaseOutStructure *payload=(VkBaseOutStructure *)(memory+64);payload->sType=sType;
    guards[guard_count++]=(Guard){memory,payload,size,sType,NULL};return payload;
}
static int intact(void){
    for(size_t i=0;i<guard_count;i++){
        Guard *guard=&guards[i];
        for(size_t n=0;n<64;n++)if(guard->allocation[n]!=0xa5||guard->allocation[64+guard->size+n]!=0xa5)return 0;
        if(guard->payload->sType!=guard->sType||guard->payload->pNext!=guard->next)return 0;
    }
    return 1;
}

int main(int argc,char **argv){
    if(argc!=3){fprintf(stderr,"usage: ReadyVulkanPropertiesProbe /absolute/libvulkan.dylib list|base|core|full|CASE\n");return 64;}
    const char *mode=argv[2];setvbuf(stdout,NULL,_IOLBF,BUFSIZ);
    printf("{\"stage\":\"start\",\"pointerBytes\":%zu,\"rootSType\":%u,\"rootSize\":%zu}\n",sizeof(void*),(unsigned)VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,sizeof(VkPhysicalDeviceProperties2));fflush(stdout);
#ifdef READY_PROPERTIES_WINDOWS
    void *library=(void *)LoadLibraryA(argv[1]);if(!library){fprintf(stderr,"LoadLibraryA failed: %lu\n",GetLastError());return 2;}
    PFN_vkGetInstanceProcAddr get=(PFN_vkGetInstanceProcAddr)GetProcAddress((HMODULE)library,"vkGetInstanceProcAddr");
#else
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!library){fprintf(stderr,"dlopen: %s\n",dlerror());return 2;}
    PFN_vkGetInstanceProcAddr get=(PFN_vkGetInstanceProcAddr)dlsym(library,"vkGetInstanceProcAddr");
#endif
    if(!get)return 2;
    printf("{\"stage\":\"loader-loaded\",\"library\":\"%p\",\"getInstanceProcAddr\":\"%p\"}\n",library,(void *)get);fflush(stdout);
    PFN_vkEnumerateInstanceVersion enumerateVersion=(PFN_vkEnumerateInstanceVersion)get(NULL,"vkEnumerateInstanceVersion");
    uint32_t version=VK_API_VERSION_1_0;if(enumerateVersion)CHECK(enumerateVersion(&version));
    PFN_vkEnumerateInstanceExtensionProperties enumerateExtensions=(PFN_vkEnumerateInstanceExtensionProperties)get(NULL,"vkEnumerateInstanceExtensionProperties");
    uint32_t count=0;CHECK(enumerateExtensions(NULL,&count,NULL));VkExtensionProperties *instanceExtensions=calloc(count,sizeof(*instanceExtensions));CHECK(enumerateExtensions(NULL,&count,instanceExtensions));
    int portability=has(instanceExtensions,count,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);free(instanceExtensions);
    const char *enabled[]={VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="ready-properties2-native-diagnostic",.apiVersion=VK_API_VERSION_1_3};
    VkInstanceCreateInfo createInfo={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.flags=portability?VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR:0,.enabledExtensionCount=portability?1:0,.ppEnabledExtensionNames=enabled};
    PFN_vkCreateInstance create=(PFN_vkCreateInstance)get(NULL,"vkCreateInstance");VkInstance instance;
    printf("{\"stage\":\"before-create-instance\",\"function\":\"%p\"}\n",(void *)create);fflush(stdout);
    CHECK(create(&createInfo,NULL,&instance));
    printf("{\"stage\":\"instance-created\",\"instance\":\"%p\"}\n",(void *)instance);fflush(stdout);
    LOAD(vkEnumeratePhysicalDevices);LOAD(vkGetPhysicalDeviceProperties);LOAD(vkGetPhysicalDeviceProperties2);LOAD(vkEnumerateDeviceExtensionProperties);LOAD(vkDestroyInstance);
    if(!vkGetPhysicalDeviceProperties2){fprintf(stderr,"Core Properties2 entry point unavailable\n");return 2;}
    printf("{\"stage\":\"before-enumerate-physical-devices\",\"instance\":\"%p\",\"function\":\"%p\"}\n",(void *)instance,(void *)vkEnumeratePhysicalDevices);fflush(stdout);
    count=0;CHECK(vkEnumeratePhysicalDevices(instance,&count,NULL));if(!count)return 3;VkPhysicalDevice *devices=calloc(count,sizeof(*devices));CHECK(vkEnumeratePhysicalDevices(instance,&count,devices));VkPhysicalDevice gpu=devices[0];free(devices);
    printf("{\"stage\":\"physical-device-selected\",\"physicalDevice\":\"%p\",\"legacyPFN\":\"%p\",\"properties2PFN\":\"%p\"}\n",(void *)gpu,(void *)vkGetPhysicalDeviceProperties,(void *)vkGetPhysicalDeviceProperties2);fflush(stdout);
    VkPhysicalDeviceProperties legacy;memset(&legacy,0,sizeof(legacy));vkGetPhysicalDeviceProperties(gpu,&legacy);
    printf("{\"stage\":\"legacy-properties-returned\",\"vendorID\":%u,\"apiVersion\":%u}\n",legacy.vendorID,legacy.apiVersion);fflush(stdout);
    printf("{\"stage\":\"before-enumerate-device-extensions\",\"physicalDevice\":\"%p\",\"function\":\"%p\"}\n",(void *)gpu,(void *)vkEnumerateDeviceExtensionProperties);fflush(stdout);
    count=0;CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&count,NULL));VkExtensionProperties *extensions=calloc(count,sizeof(*extensions));CHECK(vkEnumerateDeviceExtensionProperties(gpu,NULL,&count,extensions));
    int translated=0;
#ifndef READY_PROPERTIES_WINDOWS
    size_t translated_size=sizeof(translated);sysctlbyname("sysctl.proc_translated",&translated,&translated_size,NULL,0);
#endif
    if(!strcmp(mode,"list")){
        printf("{\"stage\":\"inventory\",\"headerVersion\":%u,\"loaderVersion\":%u,\"deviceAPIVersion\":%u,\"translated\":%s,\"pointerBytes\":%zu,\"device\":",VK_HEADER_VERSION,version,legacy.apiVersion,translated?"true":"false",sizeof(void*));json_string(legacy.deviceName);
        printf(",\"cases\":[");for(size_t i=0;i<COUNT;i++){if(i)putchar(',');printf("{\"name\":");json_string(cases[i].name);printf(",\"type\":");json_string(cases[i].type);printf(",\"sType\":%u,\"size\":%zu,\"supported\":%s}",(unsigned)cases[i].sType,cases[i].size,supported(&cases[i],extensions,count)?"true":"false");}printf("],\"extensions\":[");
        for(uint32_t i=0;i<count;i++){if(i)putchar(',');printf("{\"name\":");json_string(extensions[i].extensionName);printf(",\"specVersion\":%u}",extensions[i].specVersion);}puts("]}");
        free(extensions);vkDestroyInstance(instance,NULL);return 0;
    }
    VkPhysicalDeviceProperties2 *embedded=NULL; VkStructureType embeddedSType=0; void *embeddedNext=NULL;
    VkPhysicalDeviceProperties2 *properties=allocate_guarded(sizeof(*properties),VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2);
    void *selected[COUNT];memset(selected,0,sizeof(selected));int matched=!strcmp(mode,"base")||!strcmp(mode,"core")||!strcmp(mode,"full")||!strcmp(mode,"layered_props_list_initialized");
    for(size_t i=0;i<COUNT;i++){
        int choose=(!strcmp(mode,"full")||(!strcmp(mode,"core")&&i<3)||!strcmp(mode,cases[i].name)||(!strcmp(mode,"layered_props_list_initialized")&&!strcmp(cases[i].name,"layered_props_list")));
        if(!strcmp(mode,cases[i].name))matched=1;
        if(!choose||!supported(&cases[i],extensions,count))continue;
        VkBaseOutStructure *node=allocate_guarded(cases[i].size,cases[i].sType);selected[i]=node;
        node->pNext=properties->pNext;properties->pNext=node;
        if(!strcmp(cases[i].name,"layered_props_list")){
            VkPhysicalDeviceLayeredApiPropertiesListKHR *list=(void *)node;
            VkPhysicalDeviceLayeredApiPropertiesKHR *layered=allocate_guarded(sizeof(*layered),VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR);
            VkPhysicalDeviceLayeredApiVulkanPropertiesKHR *vulkan=allocate_guarded(sizeof(*vulkan),VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_VULKAN_PROPERTIES_KHR);
            VkPhysicalDeviceDriverPropertiesKHR *driver=allocate_guarded(sizeof(*driver),VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES_KHR);
            list->layeredApiCount=1;list->pLayeredApis=layered;layered->pNext=vulkan;
            /* Exact vkd3d-proton source shape: embedded properties.sType stays 0
             * after memset. Do not silently repair it in this reproduction. */
            vulkan->properties.pNext=driver;
            if(!strcmp(mode,"layered_props_list_initialized"))vulkan->properties.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            embedded=&vulkan->properties;embeddedSType=embedded->sType;embeddedNext=embedded->pNext;
        }
    }
    if(!matched)return 64;
    if(strcmp(mode,"base")&&strcmp(mode,"core")&&strcmp(mode,"full")){
        int available=0;for(size_t i=0;i<COUNT;i++)available|=selected[i]!=NULL;
        if(!available){printf("{\"skipped\":true,\"case\":");json_string(mode);puts(",\"reason\":\"source extension gate not advertised\"}");free(extensions);vkDestroyInstance(instance,NULL);return 77;}
    }
    for(size_t i=0;i<guard_count;i++)guards[i].next=guards[i].payload->pNext;
    printf("{\"stage\":\"before-query\",\"case\":");json_string(mode);printf(",\"rootPointer\":\"%p\",\"rootSType\":%u,\"rootSize\":%zu,\"properties2PFN\":\"%p\",\"chain\":[",(void *)properties,(unsigned)properties->sType,sizeof(*properties),(void *)vkGetPhysicalDeviceProperties2);int comma=0;
    for(size_t i=COUNT;i>0;i--)if(selected[i-1]){if(comma++)putchar(',');json_string(cases[i-1].name);}printf("],\"guardedStructs\":[");
    for(size_t i=0;i<guard_count;i++){if(i)putchar(',');printf("{\"sType\":%u,\"size\":%zu,\"pointer\":\"%p\",\"pNext\":\"%p\"}",(unsigned)guards[i].sType,guards[i].size,(void*)guards[i].payload,guards[i].next);}puts("]}");fflush(stdout);
    vkGetPhysicalDeviceProperties2(gpu,properties);
    int matches=!strcmp(properties->properties.deviceName,legacy.deviceName)&&properties->properties.vendorID==legacy.vendorID&&properties->properties.deviceID==legacy.deviceID&&properties->properties.apiVersion==legacy.apiVersion;
    int embeddedIntact=!embedded||(embedded->sType==embeddedSType&&embedded->pNext==embeddedNext);
    int guardIntact=intact()&&embeddedIntact,valid=guardIntact&&matches;printf("{\"stage\":\"after-query\",\"case\":");json_string(mode);printf(",\"returned\":true,\"guardAndHeadersIntact\":%s,\"device\":",guardIntact?"true":"false");json_string(properties->properties.deviceName);
    printf(",\"vendorID\":%u,\"apiVersion\":%u,\"baseMatchesLegacy\":%s,\"embeddedHeaderIntact\":%s,\"pointerBytes\":%zu,\"guardedStructCount\":%zu}\n",properties->properties.vendorID,properties->properties.apiVersion,matches?"true":"false",embeddedIntact?"true":"false",sizeof(void*),guard_count);
    for(size_t i=0;i<guard_count;i++)free(guards[i].allocation);free(extensions);vkDestroyInstance(instance,NULL);return valid?0:4;
}
