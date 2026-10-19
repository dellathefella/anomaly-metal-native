# xrCPU_Pipe — CPU skinning / threading API (ttapi_*) for xrPhysics.
# SSE skinning paths compile through vendored sse2neon on arm64.

file(GLOB XRCPU_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrCPU_Pipe ${XRCPU_SOURCES})

target_include_directories(xrCPU_Pipe PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Layers"
    "${XRAY_SOURCE_DIR}/src/3rd party"
)

if(NOT MSVC)
    target_compile_definitions(xrCPU_Pipe PRIVATE _MT)
    target_compile_options(xrCPU_Pipe PRIVATE -w -fdelayed-template-parsing -fms-extensions -fno-operator-names)
    target_link_options(xrCPU_Pipe PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrCPU_Pipe PUBLIC xrCore)

set_target_properties(xrCPU_Pipe PROPERTIES PREFIX "")
