cmake_minimum_required(VERSION 3.22)
project(xray-monolith LANGUAGES C CXX ASM)

if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(APPLE)
    # LuaJIT's Makefile-driven build rejects three-part Darwin deployment
    # targets (e.g. 25.6.0); pin a valid two-part version by default.
    if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET OR CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "")
        set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "macOS deployment target" FORCE)
    endif()
endif()

set(XRAY_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

# X-Ray convention: dylibs without "lib" prefix, found via rpath
set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)
set(CMAKE_INSTALL_RPATH "@loader_path" "@loader_path/../lib")
set(CMAKE_BUILD_RPATH "@loader_path" "@loader_path/../lib")

option(BUILD_SHARED_LIBS "Build engine modules as shared libraries" ON)
option(XR_PLATFORM_MACOS "macOS platform layer" ${APPLE})

if(NOT MSVC)
    # Monolith-era code uses MSVC identifier extensions: `or`, `and` as names,
    # Microsoft-style struct/union extensions, __int64, etc.
    add_compile_options(-fms-extensions -fno-operator-names)
endif()

if(NOT WIN32)
    # d3d9.h/d3d9types.h type+constant shims for engine-core modules
    # (renderer layers are not built on POSIX).
    include_directories("${CMAKE_CURRENT_SOURCE_DIR}/src/Include/POSIXShims")
endif()

find_package(SDL2 REQUIRED)
find_package(OpenGL)

add_subdirectory(src)

option(XR_BUILD_TESTS "Build small runtime test harnesses" ON)
if(XR_BUILD_TESTS)
    add_subdirectory(tests)
endif()
