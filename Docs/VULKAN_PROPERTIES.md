# Vulkan Properties2 isolation

The original GPL-3.0-only probe in `Scripts/runtime_vulkan_properties_probe.c` uses
public Khronos Vulkan headers and dynamically loads the configured public Vulkan
loader. It creates an instance and queries properties; it creates no Vulkan device,
window, surface, or GPU work and uses no Wine or Apple evaluation component.

```sh
python3 Scripts/runtime_vulkan_properties_probe.py
python3 Scripts/runtime_vulkan_properties_probe.py --driver kosmic --case layered_props_list
```

The runner builds a thin x86_64 executable, verifies actual Rosetta translation, and
sets deterministic loader/ICD paths from the frozen runtime configuration. It removes
inherited Vulkan/Mesa/MoltenVK/Wine/Apple debug or feature-override environment variables.
No reported feature or property is modified.

## Source and exact chain

- vkd3d-proton **v3.0.1**, provenance in `Vendor/vkd3d-proton.source.json`:
  [upstream tagged source](https://github.com/HansKristian-Work/vkd3d-proton/blob/v3.0.1/libs/vkd3d/device.c).
  The source archive SHA-256 is `3882a57dbd6e4f25424c46b0170ea17a1b639e74c12f84d1c37f156d99ff9a08`.
- Public **Vulkan-Headers v1.4.366**, with provenance and hashes in
  `Runtime/vulkan-headers-1.4.366.artifact.json`:
  [upstream headers](https://github.com/KhronosGroup/Vulkan-Headers/tree/v1.4.366).
- Exact source/header/loader/ICD/binary hashes are recorded with each run.

The typed table contains all 31 property-structure prepends in
`vkd3d_physical_device_info_init`. The runner checks both field order and `sType`
assignments against the actual downloaded source. It uses the same advertised
extension gates, including all three ray-tracing extension prerequisites, and reverses
the prepend order when submitting the chain. Unsupported structures are not queried.

`VK_KHR_maintenance7` includes its original nested list, layered-API entry, Vulkan
properties entry, and driver-properties entry. The embedded
`vk_layered_props.properties.sType` remains **zero**, as in vkd3d's zero-initialized
source; this reproduction does not silently repair that input. The native full,
base/core, and single-structure queries place 64-byte canaries around the typed root
and every linked/nested structure, and check that extensible headers remain intact.

## Observed native result

On Apple M1, all **31 native query cases** passed:

| ICD | Advertised API | Active source property structures | Queries | Result |
| --- | --- | --- | --- | --- |
| KosmicKrisp | 1.4.363 | 13 | 16: base/core/full + each active structure | Returned, guards/headers intact |
| MoltenVK | 1.3.357 | 12 | 15: base/core/full + each active structure | Returned, guards/headers intact |

Both full chains include the maintenance7 nested shape; KosmicKrisp additionally
includes maintenance10. `VK_EXT_mesh_shader` was not advertised and was correctly
excluded. These results do not establish support for missing D3D12 features or valid
D3D12 device creation.

`Evidence/runtime-vulkan-properties.json` contains the full inventory and each
query result; per-case raw logs are ignored repository artifacts. Total generated
native evidence is about 451 KB, with a small standalone executable. A signal
failure would be repeated under LLDB for a real native backtrace, without changing
security settings; no native failure occurred, so no debugger trace was needed.

## PE64 through the real public Wine interface

```sh
python3 Scripts/runtime_vulkan_properties_windows_probe.py
```

`runtime_vulkan_properties_windows_probe.c` reuses the same typed property/guard
implementation. It compiles against public Wine Windows/CRT headers and the same
Khronos headers, using their real Windows `VKAPI_PTR` calling convention and public
Kernel32/UCRT import archives. No proprietary Windows SDK or handwritten ABI
structure is involved. It loads `vulkan-1.dll` and `vkGetInstanceProcAddr` dynamically.

Each query runs in its own PE64 process. Two fresh UUID prefixes receive their
matching **pure** PE32 bootstrap before Wineboot. Stage output records function
pointers, instance/physical-device handles, `sType`, `sizeof`, and every guarded
structure before the query. A successful result must also match the legacy query's
device name, vendor/device IDs, and API version. A Wine Unix-call exception invalidates
the result even if this void API subsequently returns. File-backed output avoids
mistaking inherited service pipe handles for a query that is still running.

All **62 Windows queries passed**:

| Pure provider | KosmicKrisp | MoltenVK |
| --- | --- | --- |
| Wine 11.20 | 16/16 | 15/15 |
| WineCX 11.19 | 16/16 | 15/15 |

This includes base with no chain, core, full, every supported single property, and
the original maintenance7 nested shape. All roots are 840 bytes; the `sizeof` and
`sType` of all 31 source property types match the native build in all four contexts.
Guards/headers remain intact, base values match legacy values, and there are no
Properties2 Unix-call exceptions. The native image trace verifies the selected
frozen public Vulkan loader in all four contexts; no D3DMetal framework is loaded.
Both private prefixes are stopped, waited, and removed with exact-prefix cleanup.

`Evidence/runtime-vulkan-properties-windows.json` contains the aggregate counts,
provenance, inventories, stages, and per-case outcomes; ignored per-case files retain
raw output. Native and Windows evidence together occupy about 1.94 MB. No failing
property query occurred, so no debugger backtrace was needed.

## Generated Wine conversion defect isolated

The earlier native/PE64 matrices remain source-hash-bound controls. Subsequent capture of the **actual** VKD3D sequence identified a Wine-generated input conversion defect rather than a driver failure. This section supersedes the earlier inability to isolate that exception; it does not claim a full Vulkan conformance run or open D3D12 support.

`VkPhysicalDeviceLayeredApiVulkanPropertiesKHR.properties` is an embedded extensible `VkPhysicalDeviceProperties2`. The [Khronos structure contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceLayeredApiVulkanPropertiesKHR.html) permits only driver-properties and device-ID-properties nodes in its embedded `pNext` chain (VUID `pNext-10011`). Its surrounding Vulkan-specific entry is [ignored for a non-Vulkan layered API](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceLayeredApiPropertiesKHR.html). Those rules do not justify passing an uninitialized host pointer into Wine's copyback traversal.

Wine 11.20's generated W2H64/W2H32 code allocates the outer layered Vulkan node but originally initializes only its outer header. It leaves the entire embedded `properties` header/chain uninitialized. The recursive H2W converters already exist and traverse that uninitialized host chain after the driver returns. Actual caller pointer/structure captures and a deterministic scratch-poison control separate this converter defect from speculation about the hardware, ABI, or driver.

### Paired deterministic control

The diagnostic variants poison only the conversion context scratch buffer with `0xA5`; no caller input, hardware feature, returned capability, or production module is poisoned. The standalone control explicitly initializes the embedded `properties.sType` to `VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2` and supplies a valid driver-properties chain, compiled with real public headers and each guest ABI.

| Guest | Original converter + poison | Recursive W2H fix + same poison |
|---|---|---|
| PE64 | FAIL, exit 3, Properties2 Unix-call exception after host return | PASS, exit 0; root/canary/header/base checks intact |
| PE32 | FAIL, exit 3, `thunk32` host return then copyback exception | PASS, exit 0; `pointerBytes=4`, embedded header and all guards intact, base matches legacy |

In the original host trace, embedded `sType=2779096485` and `pNext=0xa5a5a5a5a5a5a5a5`. With the fix, the host embedded header matches the input, its driver node is a readable converted host allocation, and caller headers/pointers survive copyback. PE32 uses the actual i386 Wine Kernel32/UCRT import archives and Khronos Windows calling convention. Host logging uses host types; guest sizes/guards are compiled into the actual PE program, with no handwritten layout or ABI approximation.

Actual VKD3D's zero-initialized embedded `sType` remains **zero** in the captured upstream sequence. The fix transfers the caller header as supplied; it does not silently replace it. The initialized standalone control avoids blaming the converter failure on that zero header. No claim is made that zero would be valid if an implementation actually consumed that Vulkan-specific nested query.

### Minimal generator and generated-code fix

The generator incorrectly treats a returned-only embedded extensible structure as having no input requirements. Its payload is output, but its `sType` and `pNext` remain input state. The fix allows input conversion for such embedded chain-bearing structures and adds forward declarations for the resulting recursive Properties2 conversion cycle.

Using **the generator's own pinned registry version 1.4.363**, unmodified regeneration matches the checked-in Wine `vulkan_thunks.c` byte-for-byte:
`f2d2be281bd8b63486453be523e040934187b9a654715275302ef14df0978dea`.
The fixed generator emits exactly the reviewed minimal C changes in both W2H64 and W2H32, plus their forward declarations; the other generated interfaces remain unchanged. Fixed generated C SHA256:
`8d25e39333f9f5cccaa3ad172bca1605512a2b7252a02f7cf280a4603cf1b772`.
No Khronos XML edit is needed; `returnedonly` was being interpreted too broadly by Wine.

The public LGPL recipe and locked inputs are:

- `Scripts/runtime_wine_layered_w2h.py`
- `Scripts/runtime_wine_layered_w2h.lock.json`
- `Scripts/runtime_wine_layered_w2h.patch` (generator and generated C)

Original Wine/generated-code notices are retained. The observer and poison variants are diagnostic copies only. No upstream PR or external message was made.

```sh
# Regenerate and prove the original/fixed outputs in a private source layout.
python3 Scripts/runtime_wine_layered_w2h.py

# Rebuild only winevulkan.so in a same-level COW build clone; never install it.
python3 Scripts/runtime_wine_layered_w2h.py --build

# Deterministic paired controls (independent private prefixes).
python3 Scripts/runtime_vkd3d_call_trace.py --variant poison --program layered-valid --icd kosmic
python3 Scripts/runtime_vkd3d_call_trace.py --variant fixed-poison --program layered-valid --icd kosmic
python3 Scripts/runtime_vkd3d_call_trace.py --variant poison --program layered-valid --icd kosmic --bits 32
python3 Scripts/runtime_vkd3d_call_trace.py --variant fixed-poison --program layered-valid --icd kosmic --bits 32
```

### Uninstrumented asset and remaining device gates

The uninstrumented candidate contains neither observer nor poison. Its exact module/recipe/config/source hashes and compile/link commands are retained in `Evidence/runtime-wine-layered-w2h-asset.json`. Current private build:
`Runtime/build-layered-w2h-6b34f195d697/dlls/winevulkan/winevulkan.so`, module SHA256
`d4453f2861468a66b61bf9ccafb751b586c0b52714de1fb73cf4bda54217faec`.
It was copied only into diagnostic Wine COW clones. The uninstrumented asset also passes the initialized public property control in both PE32 and PE64, with embedded-header/canary/base checks intact.

Actual VKD3D with that uninstrumented asset returns a clean unsupported-device result, with no Properties2 Unix-call exception. Its log reports missing **transform feedback** and warns that `VK_EXT_dynamic_rendering_unused_attachments` is absent. This is **not open-source D3D12 readiness** and no missing feature is advertised as supported. Other device/renderer requirements may remain after those gates.

The paired reports are `Evidence/runtime-vkd3d-call-{poison,fixed-poison}-layered-valid-kosmic{,-pe32}.json` with exact traces/logs. The actual caller reports are `runtime-vkd3d-call-fixed-vkd3d-kosmic.json` and `runtime-vkd3d-call-fixed-asset-vkd3d-kosmic.json`. The asset is prepared for a future immutable runtime generation; no active provider, default config, vendor source, or hardware capability was modified. Promotion requires a separate immutable candidate with focused affected-API and real Wine/GPU regressions and an available rollback path. The previous 31-native/62-PE64 matrices are not relabelled as post-fix conformance results.
