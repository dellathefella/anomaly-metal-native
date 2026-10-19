# xrGame — game logic module (Windows: xrGame.dll). The monolith vcxproj also
# compiles xrServerEntities/*.cpp here (there is no separate xrServerEntities
# project), so those sources join this target. Cross-module engine/renderer
# symbols resolve at load time via -undefined dynamic_lookup.

file(GLOB XRGAME_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ai/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ik/*.cpp"
    "${XRAY_SOURCE_DIR}/src/xrServerEntities/*.cpp"
)

# Mirrored from the monolith xrGame.vcxproj <ExcludedFromBuild>true</ExcludedFromBuild>
# entries (dead code: DynamicHeightMap.cpp references ODE XRC BBox APIs that no
# longer exist anywhere in the tree; the *_test.cpp files likewise don't compile).
list(REMOVE_ITEM XRGAME_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/DynamicHeightMap.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/debug_make_final_test.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/static_cast_checked_test.cpp"
    # vcxproj ExcludedFromBuild in Release (body unguarded, needs USE_PROFILER/DEBUG)
    "${CMAKE_CURRENT_SOURCE_DIR}/profiler.cpp"
)

add_library(xrGame SHARED ${XRGAME_SOURCES})

target_include_directories(xrGame PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/ui"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/xrEngine"
    "${XRAY_SOURCE_DIR}/src/Layers"
    "${XRAY_SOURCE_DIR}/src/xrSound"
    "${XRAY_SOURCE_DIR}/src/xrServerEntities"
    "${XRAY_SOURCE_DIR}/src/xrPhysics"
    "${XRAY_SOURCE_DIR}/src/xrParticles"
    "${XRAY_SOURCE_DIR}/src/3rd party"
    "${XRAY_SOURCE_DIR}/src/3rd party/luabind"
)

target_compile_definitions(xrGame PRIVATE XRGAME_EXPORTS LUABIND_DONT_COPY_STRINGS)

if(NOT MSVC)
    target_compile_definitions(xrGame PRIVATE _MT)
    target_compile_options(xrGame PRIVATE -w -fdelayed-template-parsing -fms-extensions -fno-operator-names)
    target_precompile_headers(xrGame PRIVATE stdafx.h)
    target_link_options(xrGame PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrGame
    PUBLIC
    xrCore
    xrCDB
    xrXMLParser
    xrEngine
    xrPhysics
    xrSound
    xrParticles
    xrNetServer
    xrODE
    xrDiscord
    luabind
)

if(APPLE)
    # Intel TBB (Actor.cpp etc. use tbb::parallel_for)
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew/opt/tbb")
    find_package(TBB CONFIG)
    if(TARGET TBB::tbb)
        target_link_libraries(xrGame PRIVATE TBB::tbb)
    endif()
endif()

set_target_properties(xrGame PROPERTIES PREFIX "")
