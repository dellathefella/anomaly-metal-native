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

if(NOT SPIRV_CROSS_INCLUDE_DIR OR NOT SPIRV_CROSS_MSL_LIBRARY OR
   NOT SPIRV_CROSS_GLSL_LIBRARY OR NOT SPIRV_CROSS_CORE_LIBRARY)
	message(WARNING "LayersMetal: SPIRV-Cross not found — metal_poc disabled")
	return()
endif()
if(NOT XR_DXC_EXECUTABLE)
	message(WARNING "LayersMetal: dxc not found — metal_poc disabled")
	return()
endif()

add_executable(metal_poc metal_poc.mm)
# Objective-C++ (Metal) with ARC; linked via the C++ driver.
set_source_files_properties(metal_poc.mm PROPERTIES
	COMPILE_FLAGS "-x objective-c++ -fobjc-arc")
target_include_directories(metal_poc PRIVATE "${SPIRV_CROSS_INCLUDE_DIR}")
find_library(METAL_FRAMEWORK NAMES Metal)
find_library(FOUNDATION_FRAMEWORK NAMES Foundation)
target_link_libraries(metal_poc PRIVATE
	"${SPIRV_CROSS_MSL_LIBRARY}"
	"${SPIRV_CROSS_GLSL_LIBRARY}"
	"${SPIRV_CROSS_CORE_LIBRARY}"
	"${METAL_FRAMEWORK}"
	"${FOUNDATION_FRAMEWORK}")
target_compile_definitions(metal_poc PRIVATE DXC_PATH="${XR_DXC_EXECUTABLE}")
