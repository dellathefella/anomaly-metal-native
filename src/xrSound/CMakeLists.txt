# xrSound — OpenAL sound subsystem (Windows: xrSound.dll via DirectSound-era
# shell + OpenAL; the actual backend here is the OpenAL "CoreA" path).
# macOS: brew openal-soft + libvorbis, tbb for parallel source loading.

file(GLOB XRSOUND_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

if(NOT WIN32)
    # DirectSound GUID definitions (dead with the OpenAL backend)
    list(FILTER XRSOUND_SOURCES EXCLUDE REGEX "/guids\\.cpp$")
endif()

add_library(xrSound ${XRSOUND_SOURCES})

target_include_directories(xrSound PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src/3rd party/openal/include"
)

if(NOT MSVC)
    target_compile_definitions(xrSound PRIVATE _MT)
    target_compile_options(xrSound PRIVATE -w -fdelayed-template-parsing)
    target_link_options(xrSound PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrSound PUBLIC xrCore xrCDB)

if(APPLE)
    # openal-soft is keg-only; teach pkg-config about it
    set(ENV{PKG_CONFIG_PATH} "$ENV{PKG_CONFIG_PATH}:/opt/homebrew/opt/openal-soft/lib/pkgconfig")
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(XR_AUDIO IMPORTED_TARGET openal vorbisfile vorbis ogg)
        if(TARGET PkgConfig::XR_AUDIO)
            target_link_libraries(xrSound PRIVATE PkgConfig::XR_AUDIO)
        endif()
    endif()
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew/opt/tbb")
    find_package(TBB CONFIG)
    if(TARGET TBB::tbb)
        target_link_libraries(xrSound PRIVATE TBB::tbb)
    endif()
endif()

set_target_properties(xrSound PROPERTIES PREFIX "")
