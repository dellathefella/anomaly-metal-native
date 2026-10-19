# xrCore — platform layer. On Apple/POSIX platforms we keep the monolith-era
# API surface but add XR_PLATFORM_POSIX branches (backported from OpenXRay dev).

file(GLOB XRCORE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

# Windows-only or tool-only sources
list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/blackbox/")
if(NOT WIN32)
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/rt_miniacc\\.cpp$")
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/xrMemory_debug\\.cpp$")
    # Dead code upstream too: Anomaly excludes these from its Release builds
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/LocatorAPI_Notifications\\.cpp$")
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/xrDebug\\.cpp$")
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/FileSystem_borland\\.cpp$")
    # x86 asm processor-specific memcpy/memfill; replaced by portable impl
    list(FILTER XRCORE_SOURCES EXCLUDE REGEX "/xrMemory_pso_(Copy|Fill|Fill32)\\.cpp$")
endif()

add_library(xrCore ${XRCORE_SOURCES})

target_include_directories(xrCore
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${XRAY_SOURCE_DIR}/src"
    "${XRAY_SOURCE_DIR}/src/Include"

    PRIVATE
    "${XRAY_SOURCE_DIR}/src/3rd party"
    "${XRAY_SOURCE_DIR}/src/3rd party/DXERR"
)

find_package(lzo CONFIG QUIET)
find_library(LZO_LIBRARY lzo2 NAMES lzo lzo2)
find_path(LZO_INCLUDE_DIR lzo/lzo1x.h)

target_link_libraries(xrCore
    PUBLIC
    pthread
)

if(TARGET SDL2::SDL2)
    target_link_libraries(xrCore PUBLIC SDL2::SDL2)
elseif(TARGET SDL2::SDL2-static)
    target_link_libraries(xrCore PUBLIC SDL2::SDL2-static)
else()
    target_include_directories(xrCore PRIVATE ${SDL2_INCLUDE_DIRS})
    target_link_libraries(xrCore PRIVATE ${SDL2_LIBRARIES})
endif()

if(LZO_LIBRARY)
    target_link_libraries(xrCore PRIVATE "${LZO_LIBRARY}")
    if(LZO_INCLUDE_DIR)
        target_include_directories(xrCore PRIVATE "${LZO_INCLUDE_DIR}")
    endif()
    target_compile_definitions(xrCore PRIVATE XR_HAVE_LZO)
endif()

if(APPLE)
    target_link_libraries(xrCore PRIVATE "-framework CoreFoundation" "-framework Foundation")
else()
    target_link_libraries(xrCore PRIVATE dl)
endif()

target_compile_definitions(xrCore
    PRIVATE
    XRCORE_EXPORTS
    PURE_ALLOC
)

if(NOT WIN32)
    # Monolith-era headers guard on MSVC's _MT
    target_compile_definitions(xrCore PRIVATE _MT)
endif()

if(MSVC)
    target_compile_options(xrCore PRIVATE /W3)
else()
    target_compile_options(xrCore PRIVATE -fms-extensions -w -Wno-register)
endif()

target_precompile_headers(xrCore PRIVATE stdafx.h)

set_target_properties(xrCore PROPERTIES PREFIX "")
