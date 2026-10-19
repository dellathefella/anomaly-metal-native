# xrRender_GL — OpenXRay GL renderer ported into the monolith tree (p4).
# Internal layers come from the staged OpenXRay sources (xrRenderOGL_shared /
# xrRenderOGL_r2 / xrRenderGL); the boundary to xrEngine/xrGame is bridged in
# the monolith entry (DllMainXrRenderR2 + RenderFactory) inside this target.
# Source list mirrors OpenXRay's curated device-agnostic subset, remapped to
# the staged locations. Expect interface-adaptation work: this target is
# compiled against the MONOLITH engine/xrRender interface headers.

file(GLOB RGL_PC_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
file(GLOB RGL_GL_SOURCES "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/*.cpp")
# p4: vendored dev helpers (shader-cache CRC over IReader + #include scan; the
# monolith xrCore already exports the crc32() it calls) and the Media image
# save path (JPEG) used by the GL screenshot family.
list(APPEND RGL_PC_SOURCES
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/FileCRC32.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/Media/Image.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/Media/ImageJPEG.cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrCore/Text/StringConversion.cpp"
)

add_library(xrRender_GL SHARED
    ${RGL_PC_SOURCES}
    ${RGL_GL_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/xrRender_GL.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/xrRender_GL_factory.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Animation.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Animation.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/AnimationKeyCalculate.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_CLSID.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder_R2.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Blender_Recorder_StandartBinding.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/BufferUtils.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ColorMapManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ColorMapManager.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DUtils.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DUtils.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DXRenderBase.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/D3DXRenderBase.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailFormat.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_CACHE.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_Decompress.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_soft.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailManager_VS.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailModel.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/DetailModel.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_box.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_box.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cone.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cone.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cylinder.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_cylinder.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere_part.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/du_sphere_part.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxDebugRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxDebugRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxEnvironmentRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxEnvironmentRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxFontRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxFontRender.h


    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxLensFlareRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxLensFlareRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxObjectSpaceRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxObjectSpaceRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxParticleCustom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxParticleCustom.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRainRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRainRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRenderFactory.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxRenderFactory.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxStatGraphRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxStatGraphRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltDescRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltDescRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxThunderboltRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIRender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUISequenceVideoItem.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUISequenceVideoItem.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIShader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxUIShader.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxWallMarkArray.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/dxWallMarkArray.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ETextureParams.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ETextureParams.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FBasicVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FBasicVisual.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FHierrarhyVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FHierrarhyVisual.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FLOD.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FLOD.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FProgressive.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FProgressive.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FSkinned.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FSkinned.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FSkinnedTypes.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FTreeVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FTreeVisual.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FVF.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FVisual.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/FVisual.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/HOM.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/HOM.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/HWCaps.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/IRenderDetailModel.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/KinematicAnimatedDefs.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/KinematicsAddBoneTransform.hpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_DB.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_DB.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_gi.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_gi.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Package.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Package.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Render_Direct_ComputeXFS.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Render_Direct.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Light_Render_Direct.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_smapvis.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_smapvis.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/LightTrack.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/LightTrack.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/light_vis.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ModelPool.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ModelPool.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStrip.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStrip.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStripObjects.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/NvTriStripObjects.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/occRasterizer_core.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/occRasterizer.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/occRasterizer.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffect.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffectDef.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffectDef.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleEffect.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleGroup.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ParticleGroup.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/PSLibrary.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/PSLibrary.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/QueryHelper.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_DBG.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_hemi.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_hemi.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_Runtime.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_Runtime.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_tree.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_tree.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_xform.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_Backend_xform.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r_constants_cache.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r_constants.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r_constants.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_build.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_render.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_render_lods.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__dsgraph_types.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_DStreams.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/R_DStreams.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Loader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Reset.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ResourceManager_Resources.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__occlusion.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__occlusion.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__pixel_calculator.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__pixel_calculator.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector_detect.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sector_traversal.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r_sun_cascades.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sync_point.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/r__sync_point.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Shader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/Shader.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/ShaderResourceTraits.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Atomic.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Atomic.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Constant.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Constant.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Matrix.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Matrix.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_RT.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SH_Texture.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonAnimated.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonAnimated.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonCustom.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonCustom.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonRigid.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonX.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonX.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXSkinXW.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXSkinXW_CPP.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXSkinXW_SSE.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/SkeletonXVertRender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/TextureDescrManager.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/TextureDescrManager.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/tss_def.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/tss_def.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/tss.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/VertexCache.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/VertexCache.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/WallmarksEngine.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/WallmarksEngine.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xr_effgamma.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xr_effgamma.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrRender_console.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrRender_console.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrStripify.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/xrStripify.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_bloom_build.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_bloom_build.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_BmmD_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_combine.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_combine.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_aref.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_aref.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_flat.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_flat.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_model.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_deffer_model.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_detail_still_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Selection.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Selection.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Wire.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Editor_Wire.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct_cascade.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct_cascade.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_direct.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_mask.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_mask.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_occq.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_occq.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_point.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_point.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_reflected.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_reflected.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_spot.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_light_spot.h
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Lm(EbB).cpp"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Lm(EbB).h"
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_luminance.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_luminance.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Model_EbB_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Particle_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Screen_SET.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_Screen_SET.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_ssao.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/blender_ssao.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/Blender_tree_deferred.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/dx11MinMaxSMBlender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/dx11MSAABlender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/dx11RainBlender.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glMinMaxSMBlender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glMSAABlender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/glRainBlender.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/uber_deffer.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender/blenders/uber_deffer.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_blenders.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_loader.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_calculate.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_lights.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_render.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_R_sun_support.h
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
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_rendertarget_wallmarks.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/r2_types.h
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
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2/SMAP_Allocator.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/Blender_Recorder_GL.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/CommonTypes.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glBufferUtils.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glDetailManager_VS.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glHWCaps.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glHW.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glHW.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glR_Backend_Runtime.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glr_constants.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glr_constants_cache.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glr_screenshot.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glResourceManager_Resources.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glResourceManager_Scripting.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glSH_RT.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glSH_Texture.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glState.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glState.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glStateUtils.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glStateUtils.h
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glTexture.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glTextureUtils.cpp
    ${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL/glTextureUtils.h
    ${XRAY_SOURCE_DIR}/src/3rd\ party/glad/gl.c
    ${XRAY_SOURCE_DIR}/src/3rd\ party/glad/gl.h
    ${XRAY_SOURCE_DIR}/src/3rd\ party/KHR/khrplatform.h
)

target_include_directories(xrRender_GL
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    # Staged OpenXRay renderer layers (OpenXRay layout under LayersOGL/). These
    # precede the monolith src root so bare renderer-internal includes hit the
    # OpenXRay headers; "Layers/xrRender/..." style includes resolve through the
    # LayersOGL/Layers symlinks. Anything not staged falls through to the
    # monolith tree (xrEngine, Layers/xrRender, Include/xrRender boundary).
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRenderGL"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender_R2"
    "${XRAY_SOURCE_DIR}/src/LayersOGL/xrRender"
    "${XRAY_SOURCE_DIR}/src/LayersOGL"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/3rd party"
    "${XRAY_SOURCE_DIR}/src/3rd party/luabind"
    "${XRAY_SOURCE_DIR}/src/3rd party/glad"
    "${XRAY_SOURCE_DIR}/src/3rd party/KHR"
)

target_compile_definitions(xrRender_GL
    PRIVATE
    RENDERER_EXPORTS
    USE_OGL
    _MT
    _DLL
    RENDER_NAMESPACE=render_gl
    $<$<CONFIG:Debug>:_DEBUG>
)

# glad is C: keep it out of the C++ PCH (C-mode lookup cannot see libc++ headers)
set_source_files_properties("${XRAY_SOURCE_DIR}/src/3rd party/glad/gl.c"
    PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE)

# Monolith-era template code (luabind etc.) needs MSVC-style late template parsing
target_compile_options(xrRender_GL PRIVATE -fdelayed-template-parsing)

target_link_libraries(xrRender_GL
    PRIVATE
    xrAPI
    xrCore
    xrCDB
    xrEngine
    xrParticles
    luabind
    OpenGL::GL
)

# p4: brew jpeg-turbo for the vendored Media JPEG encoder (same backend as cximage)
find_package(JPEG QUIET)
if(TARGET JPEG::JPEG)
    target_link_libraries(xrRender_GL PRIVATE JPEG::JPEG)
endif()

set_target_properties(xrRender_GL PROPERTIES OUTPUT_NAME "xrRender_GL" PREFIX "")

# Renderer has its own stdafx (OpenXRay layout); do NOT reuse the xrGame PCH.
target_precompile_headers(xrRender_GL PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/stdafx.h")
