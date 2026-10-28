/* SPDX-License-Identifier: GPL-3.0-only */
/* The exact Ready PE64 shader/readback body, compiled with the public PE32 ABI.
 * Wine's pD3DCompile and COM declarations retain WINAPI/stdcall on i386.
 * No DXMT implementation source is included or modified. */
#define mainCRTStartup ready_shader_readback_entry
#include "../DXMTIntegration/dxmt_shader_probe.c"
#undef mainCRTStartup
_Static_assert(sizeof(void *) == 4, "This shader probe must be compiled as PE32");
void mainCRTStartup(void)
{
    output("{\"abiProbe\":true,\"pointerBits\":");
    number(sizeof(void *) * 8);
    output("}\n");
    ready_shader_readback_entry();
}
