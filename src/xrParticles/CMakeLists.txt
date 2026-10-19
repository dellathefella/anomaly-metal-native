# xrParticles — particle system module (Windows: xrParticles.dll).
# References engine + renderer globals (Device, EffectShaders) which resolve
# at load time via dynamic_lookup.

file(GLOB XRPARTICLES_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrParticles ${XRPARTICLES_SOURCES})

target_include_directories(xrParticles PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Layers"
    "${XRAY_SOURCE_DIR}/src/3rd party"
)

if(NOT MSVC)
    target_compile_definitions(xrParticles PRIVATE _MT)
    target_compile_options(xrParticles PRIVATE -w -fdelayed-template-parsing -fms-extensions -fno-operator-names)
    target_link_options(xrParticles PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrParticles PUBLIC xrCore)

set_target_properties(xrParticles PROPERTIES PREFIX "")
