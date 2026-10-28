# Native Vulkan Properties2 isolation

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
native evidence is about 310 KB, with an approximately 19 KB executable. A signal
failure would be repeated under LLDB for a real native backtrace, without changing
security settings; no native failure occurred, so no debugger trace was needed.

The earlier strict open-source Wine run records an exception in
`vkGetPhysicalDeviceProperties2` in `Evidence/runtime-vkd3d-winecx-open.log`. Native
success narrows that discrepancy to the Windows chain, Wine conversion/dispatch, or
Unix interop path. It does **not** by itself identify which Wine component is wrong
or prove that Wine submits a byte-identical filtered chain. No upstream source,
default runtime configuration, or advertised hardware capability was changed.
