# cximage — trimmed fork vendored from the monolith (core + JPEG codec only).
# Used by xrGame (screenshot_manager, UIServerInfo) for JPEG encode/decode.
# JPEG backend: brew jpeg-turbo (libjpeg API compatible) via the
# Include/POSIXShims/jpeg/ prefix shim.

file(GLOB CXIMAGE_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(cximage STATIC ${CXIMAGE_SOURCES})

target_include_directories(cximage
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_compile_definitions(cximage PRIVATE CXIMAGE_BUILD)

# JPEG backend: brew jpeg-turbo (libjpeg API compatible); cximage's
# <jpeg/jpeglib.h> include form is served by Include/POSIXShims/jpeg/.
find_package(JPEG QUIET)
if(TARGET JPEG::JPEG)
    target_link_libraries(cximage PUBLIC JPEG::JPEG)
endif()

target_compile_options(cximage PRIVATE -w)
