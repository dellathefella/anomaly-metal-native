# xrGame — game logic module (Windows: xrGame.dll). The monolith vcxproj also
# compiles xrServerEntities/*.cpp here (there is no separate xrServerEntities
# project), so those sources join this target. Cross-module engine/renderer
# symbols resolve at load time via -undefined dynamic_lookup.

file(GLOB XRGAME_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ui/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ai/*.cpp"
    # p4: the monolith AI tree lives in ai/<monster>/ subdirectories (67 + 82
    # sources) — the flat glob above missed them, leaving CAI_Stalker et al. undefined.
    "${CMAKE_CURRENT_SOURCE_DIR}/ai/*/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ai/*/*/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ik/*.cpp"
    "${XRAY_SOURCE_DIR}/src/xrServerEntities/*.cpp"
)

# p4: lua-extensions — the monolith vcxproj compiles these four files into
# xrGame.dll; script_storage.cpp registers them via luaopen_lua_extensions.
list(APPEND XRGAME_SOURCES
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/base.cpp"
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/script_additional_libs.cpp"
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/lfs.c"
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/lmarshal.c"
    # p4: CObjectSpace::Ray* helpers — excluded from xrCDB (needs xrEngine
    # headers); xrGame is the first-loaded image so the flat namespace finds
    # them for xrEngine/xrPhysics/xrRender_GL too.
    "${XRAY_SOURCE_DIR}/src/xrCDB/xr_area_raypick.cpp"
    # p4: the monolith vcxproj also compiles these non-.cpp sources — the IK
    # solver (.cxx) and the atlas stats name table (.c) were missed by the
    # *.cpp globs, leaving Limb:: and ATLAS_GET_STAT_NAME undefined.
    "${XRAY_SOURCE_DIR}/src/xrGame/ik/aint.cxx"
    "${XRAY_SOURCE_DIR}/src/xrGame/ik/eqn.cxx"
    "${XRAY_SOURCE_DIR}/src/xrGame/ik/eulersolver.cxx"
    "${XRAY_SOURCE_DIR}/src/xrGame/ik/jtlimits.cxx"
    "${XRAY_SOURCE_DIR}/src/xrGame/ik/limb.cxx"
    "${XRAY_SOURCE_DIR}/src/xrGame/atlas_stalkercoppc_v1.c"
)

# p4: legacy C/C++ files predating the engine PCH — keep them out of it (the
# C file cannot parse the C++ PCH; the .cxx solver is self-contained).
set_source_files_properties(
    "${XRAY_SOURCE_DIR}/src/xrGame/atlas_stalkercoppc_v1.c"
    PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE
)

# The .c files compile as C: the C++ PCH cannot be parsed in C mode (same
# rule as glad in xrRender_GL).
set_source_files_properties(
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/lfs.c"
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions/lmarshal.c"
    PROPERTIES SKIP_PRECOMPILE_HEADERS TRUE
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
    # DEBUG-only UI test screen; touches CGameFont's #ifdef DEBUG member
    "${CMAKE_CURRENT_SOURCE_DIR}/ui/UIDebugFonts.cpp"
    # legacy rat FSM (ExcludedFromBuild Release|x64 upstream): references rat
    # FSM identifiers that no longer exist anywhere in the tree
    "${CMAKE_CURRENT_SOURCE_DIR}/ai/monsters/rats/ai_rat_fsm.cpp"
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
    "${XRAY_SOURCE_DIR}/src/3rd party/lua-extensions"
    # monolith SDK headers (cs/lua_studio_backend etc. via lua_studio.h)
    "${XRAY_SOURCE_DIR}/sdk/include"
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
    cximage
    # p4: save signing / checksum helpers (crypto::, xr_dsa/xr_sha) referenced
    # by xrGame's game_save + script engine.
    xrcrypto
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
