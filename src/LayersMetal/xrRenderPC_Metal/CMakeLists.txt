# xrRender_METAL — native Metal renderer for the monolith (p5).
# Architecture mirrors the ported GL renderer (xrRenderPC_GL): the shared
# OpenXRay-derived logic layers (xrRender / xrRender_R2, staged under
# LayersOGL/) are recompiled against the Metal device layer
# (src/LayersMetal/xrRenderMetal + the PC-layer files next to this file).
# Device API seam: USE_METAL branches in the staged headers + the
# mtlR_Backend_Runtime.h runtime. Shaders: Anomaly's own r2 DX9 HLSL tree,
# compiled at runtime HLSL→DXC/SPIR-V→SPIRV-Cross→MSL (MetalShaderCompiler).

file(GLOB RMTL_DEVICE_SOURCES "${XRAY_SOURCE_DIR}/src/LayersMetal/xrRenderMetal/*.cpp" "${XRAY_SOURCE_DIR}/src/LayersMetal/xrRenderMetal/*.mm")
file(GLOB RMTL_PC_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrRender_METAL SHARED
    ${RMTL_DEVICE_SOURCES}
    ${RMTL_PC_SOURCES}
    # vendored dev helpers (shader-cache CRC over IReader; JPEG screenshot path)
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/FileCRC32.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/Media/Image.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/Media/ImageJPEG.cpp"
    # shared logic layers (same curated list as xrRender_GL, minus GL device files)
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Animation.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder_R2.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder_StandartBinding.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ColorMapManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DUtils.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DXRenderBase.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_CACHE.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_Decompress.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_soft.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_VS.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailModel.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_box.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cone.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cylinder.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere_part.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxDebugRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxEnvironmentRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxFontRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxLensFlareRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxObjectSpaceRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxParticleCustom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRainRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRenderFactory.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxStatGraphRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltDescRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUISequenceVideoItem.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIShader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxWallMarkArray.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ETextureParams.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FBasicVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FHierrarhyVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FLOD.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FProgressive.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FSkinned.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FTreeVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/HOM.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_DB.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_gi.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Package.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Render_Direct_ComputeXFS.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Render_Direct.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_smapvis.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/LightTrack.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_vis.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ModelPool.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStrip.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStripObjects.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/occRasterizer_core.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/occRasterizer.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffect.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffectDef.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleGroup.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/PSLibrary.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_DBG.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_hemi.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_Runtime.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_tree.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_xform.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r_constants.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_build.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_render.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_render_lods.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_DStreams.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Loader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Reset.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Resources.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__occlusion.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__pixel_calculator.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector_detect.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector_traversal.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sync_point.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Shader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Atomic.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Constant.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Matrix.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonAnimated.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonCustom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonRigid.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonX.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXSkinXW_CPP.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXSkinXW_SSE.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/TextureDescrManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/tss_def.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/VertexCache.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/WallmarksEngine.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xr_effgamma.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrRender_console.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrStripify.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_bloom_build.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_BmmD_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_combine.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_aref.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_flat.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_model.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_detail_still_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Selection.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Wire.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct_cascade.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_mask.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_occq.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_point.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_reflected.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_spot.cpp
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Lm(EbB).cpp"
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_luminance.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Model_EbB_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Particle_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Screen_SET.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_ssao.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_tree_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/uber_deffer.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_blenders.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_loader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_calculate.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_lights.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_render.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_accum_omnipart_geom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_accum_point_geom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_accum_reflected.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_accum_spot_geom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_draw_volume.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_enable_scissor.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_phase_accumulator.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_phase_bloom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_phase_luminance.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_phase_PP.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_phase_smap_S.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_R_rain.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_accum_point.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_accum_spot.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_create_minmaxSM.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_draw_rain.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_mark_msaa_edges.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_phase_ssao.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_phase_smap_D.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_phase_occq.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r3_rendertarget_phase_scene.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/render_phase_sun.cpp
    # Device blenders (script-level; identical across backends — reused from
    # the staged tree like the shared logic layers)
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glMinMaxSMBlender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glMSAABlender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glRainBlender.cpp
    # Metal substrate (device/swapchain/shader compiler/translation/state)
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_device.mm"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_state.mm"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_shader_compiler.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_dxc.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_dx9_translate.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_spirv_reflect.cpp"
)

target_include_directories(xrRender_METAL
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src/LayersMetal"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/xrRenderMetal"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/xrRenderPC_Metal"
    # Staged OpenXRay renderer layers (via LayersMetal/Layers symlinks):
    # "Layers/xrRender/..." hits the shared logic layers, "Layers/xrRenderMetal/..."
    # the Metal device layer. Anything else falls through to the monolith tree.
    "${XRAY_SOURCE_DIR}/src/LayersMetal"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender"
    "${XRAY_SOURCE_DIR}/src/LayersOGL"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/3rd party"
    "${XRAY_SOURCE_DIR}/src/3rd party/luabind"
    "${XRAY_SOURCE_DIR}/src/3rd party/bcdec"
    "${XRAY_SOURCE_DIR}/src/3rd party/KHR"
    # SPIRV-Cross + DXC headers (same deps the LayersMetal tools resolve)
    "${SPIRV_CROSS_INCLUDE_DIR}"
    "${XR_DXC_INCLUDE_DIR}"
    ${SDL2_INCLUDE_DIRS}
)

target_compile_definitions(xrRender_METAL
    PRIVATE
    RENDERER_EXPORTS
    USE_METAL
    _MT
    _DLL
    RENDER_NAMESPACE=render_metal
    $<$<CONFIG:Debug>:_DEBUG>
)

target_compile_options(xrRender_METAL PRIVATE -fdelayed-template-parsing)
# p5 launch220: line tables for crash symbolication (tiny size cost, no codegen change)
target_compile_options(xrRender_METAL PRIVATE -gline-tables-only)

find_library(METAL_FRAMEWORK Metal)
find_library(FOUNDATION_FRAMEWORK Foundation)
find_library(QUARTZCORE_FRAMEWORK QuartzCore)
find_library(COCOA_FRAMEWORK Cocoa)

# ObjC++ TUs (.mm) need ARC. CMake compiles .mm as ObjC++ and generates the
# matching ObjC++ PCH variant automatically — no -x override.
set(RMTL_MM_SOURCES
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_device.mm"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_state.mm"
)
file(GLOB RMTL_DEVICE_MM "${XRAY_SOURCE_DIR}/src/LayersMetal/xrRenderMetal/*.mm")
set_source_files_properties(${RMTL_MM_SOURCES} ${RMTL_DEVICE_MM} PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
    SKIP_PRECOMPILE_HEADERS TRUE)

# Metal substrate files (mtl_dxc/mtl_shader_compiler/...) must NOT see the
# renderer PCH: DXC's WinAdapter.h and the engine's D3D9 type shim define
# conflicting Windows typedefs. They compiled fine as standalone TUs.
set_source_files_properties(
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_shader_compiler.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_dxc.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_dx9_translate.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersMetal/mtl_spirv_reflect.cpp"
    PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE)

# In-process DXC + on-disk MSL cache config (mirrors the LayersMetal tools)
if(XR_DXC_EXECUTABLE)
    target_compile_definitions(xrRender_METAL PRIVATE DXC_PATH="${XR_DXC_EXECUTABLE}")
else()
    target_compile_definitions(xrRender_METAL PRIVATE DXC_PATH="")
endif()
if(XR_DXCOMPILER_LIBRARY)
    target_compile_definitions(xrRender_METAL PRIVATE DXCOMPILER_PATH="${XR_DXCOMPILER_LIBRARY}")
else()
    target_compile_definitions(xrRender_METAL PRIVATE DXCOMPILER_PATH="")
endif()

target_link_libraries(xrRender_METAL
    PRIVATE
    xrAPI
    xrCore
    xrCDB
    xrEngine
    xrParticles
    luabind
    ${SDL2_LIBRARIES}
    ${METAL_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
    ${QUARTZCORE_FRAMEWORK}
    ${COCOA_FRAMEWORK}
    "${SPIRV_CROSS_MSL_LIBRARY}"
    "${SPIRV_CROSS_GLSL_LIBRARY}"
    "${SPIRV_CROSS_CORE_LIBRARY}"
)

find_package(JPEG QUIET)
if(TARGET JPEG::JPEG)
    target_link_libraries(xrRender_METAL PRIVATE JPEG::JPEG)
endif()

# Same cross-module model as the engine dylibs — xrGame-owned symbols resolve
# at launch via two-level lookup fallback.
target_link_options(xrRender_METAL PRIVATE "-undefined" "dynamic_lookup")
# MetalFX spatial scaler for present-time upscaling (t4; macOS 14+, guarded at
# runtime with __builtin_available).
target_link_options(xrRender_METAL PRIVATE "-framework" "MetalFX")

set_target_properties(xrRender_METAL PROPERTIES OUTPUT_NAME "xrRender_METAL" PREFIX "")

# Renderer has its own stdafx (OpenXRay layout); do NOT reuse the xrGame PCH.
target_precompile_headers(xrRender_METAL PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/stdafx.h")
