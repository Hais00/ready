/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Original read-only observer for an ISOLATED Wine source snapshot. Never linked
 * into the product/default provider. Struct names/sizes are compiled from Wine's
 * public Vulkan declarations; failed memory reads are reported, not dereferenced.
 */
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>

static int ready_read(const void *pointer,void *destination,size_t size)
{
    mach_vm_size_t copied=0;
    return mach_vm_read_overwrite(mach_task_self(),(mach_vm_address_t)(uintptr_t)pointer,
        size,(mach_vm_address_t)(uintptr_t)destination,&copied)==KERN_SUCCESS && copied==size;
}
static void ready_json(FILE *file,const char *text)
{
    fputc('"',file);
    for(;text&&*text;text++){unsigned char value=*text;if(value=='"'||value=='\\')fputc('\\',file);if(value>=32)fputc(value,file);}
    fputc('"',file);
}
#include "ready_vulkan_type_sizes.h"

static void ready_chain(FILE *file,const void *root,unsigned depth)
{
    const void *seen[128];unsigned count=0;const void *pointer=root;
    fputc('[',file);
    while(pointer&&count<128)
    {
        VkBaseInStructure header;unsigned i;int cycle=0;
        for(i=0;i<count;i++)if(seen[i]==pointer){cycle=1;break;}
        if(count)fputc(',',file);
        fprintf(file,"{\"address\":\"%p\"",pointer);
        if(cycle){fputs(",\"cycle\":true}",file);break;}
        if(!ready_read(pointer,&header,sizeof(header))){fputs(",\"readable\":false}",file);break;}
        seen[count++]=pointer;
        fprintf(file,",\"readable\":true,\"sType\":%u,\"expectedSize\":%zu,\"type\":",(unsigned)header.sType,ready_type_size(header.sType));
        ready_json(file,ready_type_name(header.sType));
        fprintf(file,",\"next\":\"%p\"",(void*)header.pNext);
        if(depth<3&&header.sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_LIST_KHR)
        {
            VkPhysicalDeviceLayeredApiPropertiesListKHR list;
            if(ready_read(pointer,&list,sizeof(list)))
            {
                fprintf(file,",\"layeredApiCount\":%u,\"layeredArray\":\"%p\",\"layeredEntries\":[",list.layeredApiCount,(void*)list.pLayeredApis);
                for(unsigned n=0;n<list.layeredApiCount&&n<4;n++)
                {
                    if(n)fputc(',',file);
                    ready_chain(file,&list.pLayeredApis[n],depth+1);
                }
                fputc(']',file);
            }
        }
        if(depth<3&&header.sType==VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_VULKAN_PROPERTIES_KHR)
        {
            VkPhysicalDeviceLayeredApiVulkanPropertiesKHR layered;
            if(ready_read(pointer,&layered,sizeof(layered)))
            {
                fprintf(file,",\"embeddedPropertiesSType\":%u,\"embeddedPropertiesNext\":\"%p\",\"embeddedChain\":",(unsigned)layered.properties.sType,layered.properties.pNext);
                ready_chain(file,layered.properties.pNext,depth+1);
            }
        }
        fputc('}',file);pointer=header.pNext;
    }
    fputc(']',file);
}
static void ready_call_trace(const char *phase,VkPhysicalDevice device,const void *root,const void *target)
{
    const char *path=getenv("READY_VKD3D_CALL_TRACE");FILE *file;int fd;struct stat info;Dl_info image;mach_port_t thread;
    if(!path||path[0]!='/')return;
    fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW,0600);
    if(fd<0)return;
    if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_uid!=geteuid()){close(fd);return;}
    flock(fd,LOCK_EX);file=fdopen(fd,"a");if(!file){close(fd);return;}
    thread=mach_thread_self();
    fprintf(file,"{\"pid\":%u,\"thread\":%u,\"phase\":",(unsigned)getpid(),(unsigned)thread);ready_json(file,phase);
    mach_port_deallocate(mach_task_self(),thread);
    fprintf(file,",\"physicalDevice\":\"%p\",\"root\":\"%p\",\"target\":\"%p\",\"targetImage\":",(void*)device,root,target);
    memset(&image,0,sizeof(image));if(target)dladdr(target,&image);ready_json(file,image.dli_fname);
    fputs(",\"targetSymbol\":",file);ready_json(file,image.dli_sname);
    fputs(",\"chain\":",file);ready_chain(file,root,0);fputs("}\n",file);fclose(file);
}
