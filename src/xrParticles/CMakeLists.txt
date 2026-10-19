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

# p4: particle_actions_collection.cpp uses <tbb/parallel_for.h>. The bundled
# "3rd party/tbb" headers are pre-oneTBB (old ABI: tbb::task_group_context
# without detail::r1) and brew oneTBB does not export those symbols — pick the
# brew headers first so the emitted references match the linked library.
if(APPLE)
    target_include_directories(xrParticles BEFORE PRIVATE "/opt/homebrew/include")
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew/opt/tbb")
    find_package(TBB CONFIG)
    if(TARGET TBB::tbb)
        target_link_libraries(xrParticles PRIVATE TBB::tbb)
    endif()
endif()

if(NOT MSVC)
    target_compile_definitions(xrParticles PRIVATE _MT)
    target_compile_options(xrParticles PRIVATE -w -fdelayed-template-parsing -fms-extensions -fno-operator-names)
    target_link_options(xrParticles PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrParticles PUBLIC xrCore)

set_target_properties(xrParticles PROPERTIES PREFIX "")
