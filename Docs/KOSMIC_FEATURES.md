# Kosmickrisp 26.3.0-rc2: DXVK feature gap and rasterization plan

Evidence collected on Apple M1, macOS 27, 2026-10-27. No Mesa, Wine, or installed runtime was changed for this investigation. Probes and documentation are original GPL-3.0-only code; a contribution to Mesa must retain the applicable upstream MIT license.

## Measured result

DXVK 3.1.1 cannot currently create its device with this Kosmickrisp runtime. Exactly two of its **53 mandatory feature/extension entries** are absent:

| Requirement | ARM64 ICD | x86_64 ICD via Rosetta |
|---|---|---|
| `fillModeNonSolid` | false | false |
| `geometryShader` | false | false |
| Other 51 mandatory entries | advertised | advertised |
| API >= 1.3 | 1.4.363 | 1.4.363 |
| Graphics queue | present | present |
| Push constants >= 256 bytes (without descriptor heap) | 256 | 256 |
| `VK_KHR_portability_subset` | absent | absent |

The query reports what the driver advertises. It does not prove correctness of all 51 advertised features, image-format suitability for a particular game, or successful DXVK rendering. DXVK reports the first missing feature; repairing `fillModeNonSolid` alone would expose the independent `geometryShader` rejection next.

Evidence:

- `Evidence/stores-kosmic-features-arm64.json`
- `Evidence/stores-kosmic-features-x86_64.json`
- `Synthetic/KosmicFeaturesProbe.c`: queries all 53 entries, API, queue, and push-constant limit without creating a device or changing features.

The list comes directly from `Vendor/dxvk/src/dxvk/dxvk_device_info.cpp`, `DxvkDeviceCapabilities::getFeatureList()` and `checkDeviceCompatibility()`. DXVK's minimum API is in `dxvk_instance.h`; `MaxTotalPushDataSize` is 256 in `dxvk_limits.h`.

## Why fill mode is missing

`Vendor/mesa/src/kosmickrisp/vulkan/kk_physical_device.c` initializes a zeroed `vk_features` structure and does not set `fillModeNonSolid` or `geometryShader`. This is not a 4 KB/16 KB memory-page or DART issue: these are graphics-driver capabilities.

Mesa's shared Vulkan code already stores static `polygonMode` and tracks the `RS_POLYGON_MODE` dirty bit (`src/vulkan/runtime/vk_graphics_state.c`). Kosmickrisp's `kk_flush_dynamic_state()` in `vulkan/kk_cmd_draw.c` handles cull mode, front face, depth bias, and other raster state, but does not consume `dyn->rs.polygon_mode` at all. Its C/Objective-C bridge has no triangle-fill wrapper. Thus advertising the feature without implementing the command path would permit pipelines whose actual rasterization remains filled.

Metal has actual hardware-backed line rasterization: `MTLTriangleFillModeFill` and `MTLTriangleFillModeLines`, selected by `setTriangleFillMode:` on both Metal 3 and Metal 4 render encoders. There is no Metal triangle-fill **point** enum. The local SDK confirms this in `Metal.framework/Headers/MTLRenderCommandEncoder.h` and `MTL4RenderCommandEncoder.h`.

Primary API references: [Apple fill modes](https://developer.apple.com/documentation/metal/mtltrianglefillmode), [Apple encoder method](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/settrianglefillmode(_:)).

## Actual GPU pixel proof

`Synthetic/KosmicWireframeProbe.m` compiles a tiny native MSL vertex/fragment shader, draws the same triangle into three adjacent viewports, switches fill -> lines -> fill within one encoder, and blits the resulting private texture to a CPU-visible buffer. The Metal 4 test explicitly makes its texture resident and waits on a shared GPU completion event before readback.

All four cases passed on M1: Metal 3 and Metal 4, triangle list and triangle strip. Each filled tile has **4,608 white pixels**; each wireframe tile has **286**, with a black interior pixel. Restoring fill produces an image byte-identical to the original filled tile. The full evidence is `Evidence/stores-metal-wireframe.json`.

This proves that Metal 4 wireframe rasterization can be used by Kosmickrisp. It does **not** test a patched Kosmickrisp Vulkan pipeline, point polygon semantics, geometry shaders, DXVK compatibility, presentation, or a game.

## A correct line-mode patch

A plausible small first patch, retaining Mesa's upstream license:

1. Add a fill enum and `mtl_set_triangle_fill_mode()` bridge declaration, Objective-C implementation calling `[enc setTriangleFillMode:]`, and the corresponding non-Apple stub. Relevant files are `bridge/mtl_types.h`, `bridge/mtl_encoder.h`, `bridge/mtl_encoder.m`, and `bridge/stubs/mtl_encoder.c`.
2. Map Vulkan FILL and LINE explicitly, either locally or through `bridge/vk_to_mtl_map.{h,c}`. Do not map POINT to LINE and claim correct support.
3. In `kk_flush_dynamic_state()`, consume `IS_DIRTY(RS_POLYGON_MODE)` and set the real Metal encoder state. Ensure the call occurs after `cs_get_render()`, which can create a new encoder and mark graphics state dirty. Set FILL explicitly when switching away from LINE. Existing `cs_start_render()` and compute/render transitions invoke `kk_cmd_buffer_dirty_all_gfx()`; verify the new state follows those paths.
4. Keep triangle topology unchanged for line mode. Metal then performs triangle assembly, winding/culling, clipping, and edge rasterization. Converting all triangle draws into line lists is unnecessary and risks losing triangle semantics.
5. Leave `fillModeNonSolid` false until the complete advertised contract is implemented and validated, or until a legitimate portability-subset policy is implemented and the full Windows Vulkan/DXVK path supports that policy.

The Vulkan core feature means **both point and wireframe polygon modes**. [Vulkan features](https://docs.vulkan.org/spec/latest/chapters/features.html) and [rasterization validity rules](https://docs.vulkan.org/spec/latest/chapters/primsrast.html) distinguish this from a portability implementation that explicitly exposes `pointPolygons = false`. Kosmickrisp currently exposes no portability subset. Adding that extension is a separate policy/compatibility change, not a one-line substitute; our DXVK source search found no explicit handling of it, so enabling it through Wine must be verified before relying on it.

## Point polygons need a separate implementation

Simply changing `MTLPrimitiveTypeTriangle` to `Point` is insufficient. Polygon mode operates on assembled, culled polygons, whereas standalone point topology changes primitive assembly. A correct implementation must preserve at least triangle-list/strip/fan expansion, indexed and indirect draws, primitive restart, face culling, degenerate and clipped triangles, vertex/instance/base offsets, provoking/interpolated data, depth bias behavior, and tessellation output.

The bundled MoltenVK source provides an architectural comparison, not proof of Kosmickrisp support:

- `GPUObjects/MVKPipeline.mm` sets the pipeline topology class to POINT for static point polygon mode; its `isRenderingPoints()` comments explicitly explain the static-vs-dynamic topology-class limitation.
- `Commands/MVKCommandEncoderState.mm` warns about dynamic point mode.
- `GPUObjects/MVKDevice.mm` exposes portability `pointPolygons = false` even though it sets core `fillModeNonSolid = true`.
- `Vulkan/mvk_datatypes.mm` maps POINT to a line fallback where that mapping is reached. Copying that fallback without its portability restrictions would not establish correct point rasterization.

A Kosmickrisp implementation could lower point polygons through a GPU preprocessing/primitive-expansion path, possibly reusing its existing Poly machinery. This needs pipeline keys and actual draw-path work, not only dynamic-state wiring. Raster conformance tests must decide which optimization is valid; there is no native Metal point-polygon fill switch.

## Geometry shader is the larger independent gap

Kosmickrisp already has compute-assisted tessellation, but the inspected `kk_shader.c` stage lowering implements VERTEX, TESS_CTRL, TESS_EVAL, and FRAGMENT paths without a corresponding GEOMETRY lowering. Its comments mentioning geometry do not establish a complete implementation. `kk_unroll_geometry()` in `kk_cmd_draw.c` expands input topology/index buffers; it is not an arbitrary SPIR-V geometry-shader executor.

Mesa offers reusable open-source machinery:

- `src/poly/nir/poly_nir_lower_gs.c` and `poly_nir.h`: `poly_nir_lower_gs()` generates count, copy/raster, and pre-GS variants plus `poly_gs_info`.
- `src/poly/geometry.h`: output allocation/count/index and indirect draw helpers.
- `src/asahi/vulkan/hk_shader.c`: Honeykrisp calls `poly_nir_lower_gs()` and compiles the resulting variants.
- `src/asahi/vulkan/hk_cmd_draw.c`: `hk_launch_gs_prerast()` orchestrates allocation, compute dispatch, and final raster draw.

A plausible Kosmickrisp design is to adapt this shared Poly lowering, compile generated stages through its NIR-to-MSL path, dispatch the necessary compute stages with Metal-visible buffers, and render the generated vertex/index stream. Honeykrisp's native AGX command encoding cannot simply be copied into a Metal driver. Kosmickrisp needs its own resource/residency, synchronization, allocation-failure, indirect-command, and pipeline-cache integration.

Validation must include primitive emission and `EndPrimitive`, all supported input/output primitive modes, invocation count, `PrimitiveID`, layered/viewport output, interpolation and clipping, indexed/indirect/multi-draw paths, and pipeline transitions with and without GS. Transform feedback and nonzero geometry streams are additional advertised-extension contracts; do not enable those merely because base GS starts working.

## Mandatory DXVK entries queried

Core 1.0 (22): `depthBiasClamp`, `depthClamp`, `dualSrcBlend`, `fillModeNonSolid`, `fragmentStoresAndAtomics`, `fullDrawIndexUint32`, `geometryShader`, `imageCubeArray`, `independentBlend`, `multiDrawIndirect`, `multiViewport`, `occlusionQueryPrecise`, `robustBufferAccess`, `sampleRateShading`, `samplerAnisotropy`, `shaderClipDistance`, `shaderCullDistance`, `shaderImageGatherExtended`, `shaderInt16`, `shaderInt64`, `shaderSampledImageArrayDynamicIndexing`, `textureCompressionBC`.

Core 1.1 (2): `shaderDrawParameters`, `storageBuffer16BitAccess`.

Core 1.2 (14): `bufferDeviceAddress`, `descriptorIndexing`, `storageBuffer8BitAccess`, `descriptorBindingSampledImageUpdateAfterBind`, `descriptorBindingUpdateUnusedWhilePending`, `descriptorBindingPartiallyBound`, `hostQueryReset`, `runtimeDescriptorArray`, `samplerMirrorClampToEdge`, `scalarBlockLayout`, `shaderInt8`, `timelineSemaphore`, `uniformBufferStandardLayout`, `vulkanMemoryModel`.

Core 1.3 (8): `inlineUniformBlock`, `computeFullSubgroups`, `dynamicRendering`, `maintenance4`, `shaderDemoteToHelperInvocation`, `shaderZeroInitializeWorkgroupMemory`, `subgroupSizeControl`, `synchronization2`.

Extensions/features (7): `VK_EXT_depth_clip_enable.depthClipEnable`, `VK_EXT_robustness2.robustBufferAccess2`, `VK_EXT_robustness2.nullDescriptor`, `VK_KHR_load_store_op_none`, `VK_KHR_maintenance5.maintenance5`, `VK_KHR_maintenance6.maintenance6`, `VK_KHR_swapchain`.

The probe gates these extension-specific feature bits on the extension names that this DXVK version uses. It also checks Vulkan >= 1.3, a graphics queue, and >= 256 push-constant bytes. Descriptor heap is optional and absent from this runtime; the 256-byte fallback limit is satisfied.

## Acceptance checks before calling a patched runtime usable

After an isolated Mesa build (not performed here):

1. Vulkan raster test with actual SPIR-V shaders, offscreen color attachment, barriers, image-to-buffer copy, and CPU assertions for filled versus edge-only output. Test line->fill restoration both within an encoder and after render/compute transitions. Do not force an unsupported feature at device creation merely to make the test run.
2. Expand coverage to indexed, strip/fan with restart, indirect, instanced/base-vertex, viewport/scissor, front/back culling, clipping and depth bias; compare required Vulkan line rasterization rules, not only a screenshot.
3. Separate point-polygon and geometry-shader output readbacks, including topology/primitive-ID/layer semantics. Use relevant Vulkan CTS cases where available.
4. Requery all 53 mandatory entries on ARM64 and x86_64; only enable implemented features. Repeat the actual Windows Wine->Vulkan->Kosmickrisp DXVK probe. Device creation passing is a milestone, not a game-compatibility claim.

## Reproduction (small local artifacts)

From the launcher root, using components already present:

```sh
mkdir -p Build/KosmicFeasibility
clang -Wall -Wextra -Werror -I Runtime/vulkan-sdk-1.4.366/include Synthetic/KosmicFeaturesProbe.c -o Build/KosmicFeasibility/features-arm64
VK_DRIVER_FILES="$PWD/Runtime/mesa-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" Build/KosmicFeasibility/features-arm64 "$PWD/Runtime/vulkan-sdk-1.4.366/lib/libvulkan.1.4.366.dylib"
clang -arch x86_64 -Wall -Wextra -Werror -I Runtime/vulkan-sdk-1.4.366/include Synthetic/KosmicFeaturesProbe.c -o Build/KosmicFeasibility/features-x86_64
VK_DRIVER_FILES="$PWD/Runtime/mesa-x64-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json" arch -x86_64 Build/KosmicFeasibility/features-x86_64 "$PWD/Runtime/vulkan-sdk-1.4.366/lib/libvulkan.1.4.366.dylib"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Metal Synthetic/KosmicWireframeProbe.m -o Build/KosmicFeasibility/metal-wireframe
Build/KosmicFeasibility/metal-wireframe
```

These builds are tiny; no source package or SDK was downloaded and no installed runtime file was modified.
