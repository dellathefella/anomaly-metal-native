# xrCDB — static collision DB + spatial queries (Opcode AABB trees in-tree).
# On POSIX, xr_area_raypick.cpp is deferred: it implements CObjectSpace::Ray*
# helpers that include xrEngine headers (xr_object.h/cl_intersect.h), so it
# compiles together with the engine (p3).

file(GLOB XRCDB_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

if(NOT WIN32)
    # xr_area_raypick.cpp: CObjectSpace::Ray* helpers that include xrEngine
    # headers — compiled together with the engine (p3).
    list(FILTER XRCDB_SOURCES EXCLUDE REGEX "/xr_area_raypick\\.cpp$")
    # cl_raypick.cpp: dead source — its cl_RAPID.h is absent from the monolith
    # repo entirely (nothing else references it).
    list(FILTER XRCDB_SOURCES EXCLUDE REGEX "/cl_raypick\\.cpp$")
endif()

add_library(xrCDB ${XRCDB_SOURCES})

target_include_directories(xrCDB
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    PRIVATE
    "${XRAY_SOURCE_DIR}/src/3rd party"
)

target_link_libraries(xrCDB PUBLIC xrCore)

if(NOT MSVC)
    target_compile_definitions(xrCDB PRIVATE _MT)
    target_compile_options(xrCDB PRIVATE -w)
    target_precompile_headers(xrCDB PRIVATE StdAfx.h)
endif()

set_target_properties(xrCDB PROPERTIES PREFIX "")

if(APPLE)
    # ::Render & friends live in the renderer/engine modules (not yet ported);
    # resolve them at final-executable load, like static-lib linkage on MSVC.
    target_link_options(xrCDB PRIVATE "-undefined" "dynamic_lookup")
endif()
