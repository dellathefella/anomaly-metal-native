# xrEngine — engine core (window/device orchestration, levels, EFL, input).
# On POSIX: dinput/xinput backends are excluded (SDL input lands in p3 t2);
# the D3D surface is covered by Include/POSIXShims.

file(GLOB XRENGINE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

if(NOT WIN32)
    # DirectInput/XInput backends — replaced by the SDL input port.
    list(FILTER XRENGINE_SOURCES EXCLUDE REGEX "/Xr_input\\.cpp$")
    list(FILTER XRENGINE_SOURCES EXCLUDE REGEX "/xr_input_xinput\\.cpp$")
    # Win32 AVI intro player (Video for Windows) — intro is skipped, no refs.
    list(FILTER XRENGINE_SOURCES EXCLUDE REGEX "/tntQAVI\\.cpp$")
    # entry point lives in the xr_3da executable target below
    list(FILTER XRENGINE_SOURCES EXCLUDE REGEX "/xray_main_sdl\\.cpp$")
endif()

add_library(xrEngine ${XRENGINE_SOURCES})

target_include_directories(xrEngine
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    PRIVATE
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/xrCDB"
    "${XRAY_SOURCE_DIR}/src/Include"
    "${XRAY_SOURCE_DIR}/src/3rd party"
    "${XRAY_SOURCE_DIR}/src/3rd party/luabind"
)

target_link_libraries(xrEngine
    PUBLIC
    xrCore
    xrCDB
    xrAPI
    xrNetServer
    xrSound
    xrDiscord
    luabind
)

if(NOT MSVC)
    target_compile_definitions(xrEngine PRIVATE _MT ENGINE_BUILD STATIC_RENDERER_R2)
    target_compile_options(xrEngine PRIVATE -w -fdelayed-template-parsing)
    target_precompile_headers(xrEngine PRIVATE stdafx.h)
    target_link_options(xrEngine PRIVATE "-undefined" "dynamic_lookup")
else()
    target_compile_definitions(xrEngine PRIVATE ENGINE_BUILD STATIC_RENDERER_R2)
endif()

# brew-provided media codecs (movie textures / ogg vorbis)
if(APPLE)
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(XR_MEDIA IMPORTED_TARGET ogg vorbisfile theora libjpeg)
        if(TARGET PkgConfig::XR_MEDIA)
            target_link_libraries(xrEngine PRIVATE PkgConfig::XR_MEDIA)
        endif()
    endif()

    # ICU (brew, keg-only) — x_ray.cpp uses ucnv_* for cp1251 presence text
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew/opt/icu4c")
    find_package(ICU COMPONENTS uc)
    if(ICU_FOUND)
        target_include_directories(xrEngine PRIVATE ${ICU_INCLUDE_DIRS})
        target_link_libraries(xrEngine PRIVATE ICU::uc)
    endif()
endif()

# xr_3da — the game executable (mirrors the MSVC setup where xrEngine.vcxproj
# produces xr_3da.exe). Renderer/game modules are dlopen'd at runtime.
if(NOT WIN32)
    add_executable(xr_3da xray_main_sdl.cpp)
    target_include_directories(xr_3da PRIVATE
        "${XRAY_SOURCE_DIR}/src"
        "${XRAY_SOURCE_DIR}/src/Include"
        "${XRAY_SOURCE_DIR}/src/3rd party/luabind"
    )
    target_compile_definitions(xr_3da PRIVATE _MT ENGINE_BUILD STATIC_RENDERER_R2)
    target_link_libraries(xr_3da PRIVATE xrEngine)
    if(APPLE)
        target_link_options(xr_3da PRIVATE "-undefined" "dynamic_lookup")
    endif()
endif()

set_target_properties(xrEngine PROPERTIES PREFIX "")
