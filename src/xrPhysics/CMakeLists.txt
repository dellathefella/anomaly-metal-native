# xrPhysics — ODE-backed physics module (Windows: xrPhysics.dll).
# Cross-module engine symbols (Device, GameMtlLib, ...) resolve at load time
# via -undefined dynamic_lookup, mirroring the Windows import-lib model.

file(GLOB XRPCORE_SUB
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/dcylinder/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/tri-colliderknoopc/*.cpp"
)

if(NOT WIN32)
    # included directly by dTriList.cpp (see header comment) — not a TU
    list(FILTER XRPCORE_SUB EXCLUDE REGEX "/dcTriListCollider\\.cpp$")
endif()

add_library(xrPhysics ${XRPCORE_SUB})

target_include_directories(xrPhysics PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Layers"
    "${XRAY_SOURCE_DIR}/src/xrSound"
    "${XRAY_SOURCE_DIR}/src/xrServerEntities"
    "${XRAY_SOURCE_DIR}/src/3rd party"
)

target_compile_definitions(xrPhysics PRIVATE XRPHYSICS_EXPORTS dSINGLE)

if(NOT MSVC)
    target_compile_definitions(xrPhysics PRIVATE _MT)
    target_compile_options(xrPhysics PRIVATE -w -fms-extensions -fno-operator-names)
    target_link_options(xrPhysics PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrPhysics PUBLIC xrCore xrCDB xrODE xrSound)

set_target_properties(xrPhysics PROPERTIES PREFIX "")
