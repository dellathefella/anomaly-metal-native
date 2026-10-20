# LayersMetal — native Metal renderer (p5).
#
# Currently: metal_poc, the proof-of-life that validates the two foundations
# every native Metal renderer needs on this machine —
#   * runtime shader pipeline  HLSL -> SPIR-V (DXC) -> MSL (SPIRV-Cross)
#   * Metal device + render pipeline + offscreen draw + CPU readback
# It is the seed of the future xrRenderMetal device backend.

if(NOT APPLE)
	return()
endif()

# --- deps: SPIRV-Cross (brew static libs) + DXC (built in repos/dxc) --------
find_path(SPIRV_CROSS_INCLUDE_DIR spirv_cross/spirv_cross.hpp
	HINTS /opt/homebrew/include /usr/local/include)
find_library(SPIRV_CROSS_MSL_LIBRARY  NAMES spirv-cross-msl
	HINTS /opt/homebrew/lib /usr/local/lib)
find_library(SPIRV_CROSS_GLSL_LIBRARY NAMES spirv-cross-glsl
	HINTS /opt/homebrew/lib /usr/local/lib)
find_library(SPIRV_CROSS_CORE_LIBRARY NAMES spirv-cross-core
	HINTS /opt/homebrew/lib /usr/local/lib)

get_filename_component(_xr_repo_root "${CMAKE_SOURCE_DIR}/.." ABSOLUTE)
find_program(XR_DXC_EXECUTABLE NAMES dxc
	HINTS "${_xr_repo_root}/repos/dxc/build-mac/bin"
	DOC "Path to the DXC HLSL compiler executable")
find_file(XR_DXCOMPILER_LIBRARY NAMES libdxcompiler.dylib
	HINTS "${_xr_repo_root}/repos/dxc/build-mac/lib"
	DOC "Path to the DXC compiler dylib (in-process HLSL backend)")
set(XR_DXC_INCLUDE_DIR "${_xr_repo_root}/repos/dxc/include")

if(NOT SPIRV_CROSS_INCLUDE_DIR OR NOT SPIRV_CROSS_MSL_LIBRARY OR
   NOT SPIRV_CROSS_GLSL_LIBRARY OR NOT SPIRV_CROSS_CORE_LIBRARY)
	message(WARNING "LayersMetal: SPIRV-Cross not found — metal_poc disabled")
	return()
endif()
if(NOT XR_DXC_EXECUTABLE AND NOT XR_DXCOMPILER_LIBRARY)
	message(WARNING "LayersMetal: neither dxc CLI nor libdxcompiler found — metal_poc disabled")
	return()
endif()

add_executable(metal_poc metal_poc.mm mtl_shader_compiler.cpp mtl_dxc.cpp mtl_dx9_translate.cpp)
add_executable(metal_shader_batch metal_shader_batch.mm mtl_shader_compiler.cpp mtl_dxc.cpp mtl_dx9_translate.cpp)
# Swapchain validation tool: CAMetalLayer on the SDL2 window (MetalDevice).
add_executable(metal_swap_test metal_swap_test.mm mtl_device.mm mtl_shader_compiler.cpp mtl_dxc.cpp mtl_dx9_translate.cpp)
# Resource/state substrate validation: buffers, textures, samplers, cbuffers,
# pipeline cache, depth, blend — offscreen, on-device.
add_executable(metal_devicetest metal_devicetest.mm mtl_device.mm mtl_state.mm mtl_shader_compiler.cpp mtl_dxc.cpp mtl_dx9_translate.cpp)

# Objective-C++ (Metal) with ARC; linked via the C++ driver. The DXC/SPIRV-Cross
# compiler sources are pure C++ (WinAdapter.h macros stay out of .mm TUs).
set_source_files_properties(metal_poc.mm PROPERTIES
	COMPILE_FLAGS "-x objective-c++ -fobjc-arc")
set_source_files_properties(metal_shader_batch.mm PROPERTIES
	COMPILE_FLAGS "-x objective-c++ -fobjc-arc")
set_source_files_properties(metal_swap_test.mm mtl_device.mm PROPERTIES
	COMPILE_FLAGS "-x objective-c++ -fobjc-arc")
set_source_files_properties(metal_devicetest.mm mtl_state.mm PROPERTIES
	COMPILE_FLAGS "-x objective-c++ -fobjc-arc")

find_library(METAL_FRAMEWORK NAMES Metal)
find_library(FOUNDATION_FRAMEWORK NAMES Foundation)
find_library(QUARTZCORE_FRAMEWORK NAMES QuartzCore)
find_library(COREGRAPHICS_FRAMEWORK NAMES CoreGraphics) # CGSessionCopyCurrentDictionary

foreach(_mtl_tool metal_poc metal_shader_batch metal_swap_test metal_devicetest)
	target_include_directories(${_mtl_tool} PRIVATE
		"${CMAKE_CURRENT_SOURCE_DIR}"
		"${SPIRV_CROSS_INCLUDE_DIR}"
		"${XR_DXC_INCLUDE_DIR}"
		${SDL2_INCLUDE_DIRS})
	target_link_libraries(${_mtl_tool} PRIVATE
		"${SPIRV_CROSS_MSL_LIBRARY}"
		"${SPIRV_CROSS_GLSL_LIBRARY}"
		"${SPIRV_CROSS_CORE_LIBRARY}"
		"${METAL_FRAMEWORK}"
		"${QUARTZCORE_FRAMEWORK}"
		"${COREGRAPHICS_FRAMEWORK}"
		"${FOUNDATION_FRAMEWORK}")
	if(XR_DXC_EXECUTABLE)
		target_compile_definitions(${_mtl_tool} PRIVATE DXC_PATH="${XR_DXC_EXECUTABLE}")
	else()
		target_compile_definitions(${_mtl_tool} PRIVATE DXC_PATH="")
	endif()
	if(XR_DXCOMPILER_LIBRARY)
		target_compile_definitions(${_mtl_tool} PRIVATE DXCOMPILER_PATH="${XR_DXCOMPILER_LIBRARY}")
	else()
		target_compile_definitions(${_mtl_tool} PRIVATE DXCOMPILER_PATH="")
	endif()
endforeach()

# SDL2 (sdl2-compat config package) for the window-attach path in mtl_device.mm.
target_link_libraries(metal_swap_test PRIVATE ${SDL2_LIBRARIES})
target_link_libraries(metal_devicetest PRIVATE ${SDL2_LIBRARIES})

# Default shader corpus for metal_shader_batch: the searge-coc r2 tree
# (Anomaly-lineage DX9 HLSL). Override by passing a root path on the CLI.
set(XR_METAL_CORPUS_DIR "${_xr_repo_root}/repos/searge-coc/res/gamedata/shaders/r2"
	CACHE PATH "DX9 shader corpus for metal_shader_batch")
target_compile_definitions(metal_shader_batch PRIVATE XR_METAL_CORPUS_DIR="${XR_METAL_CORPUS_DIR}")
