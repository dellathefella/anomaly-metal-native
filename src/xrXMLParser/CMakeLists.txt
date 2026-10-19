# xrXMLParser — tinyxml + X-Ray XML layer (ICF, xrXML_reader).
file(GLOB XRXML_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrXMLParser ${XRXML_SOURCES})

target_include_directories(xrXMLParser
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(xrXMLParser PUBLIC xrCore)

if(NOT MSVC)
    target_compile_definitions(xrXMLParser PRIVATE _MT)
    target_compile_options(xrXMLParser PRIVATE -w)
    target_precompile_headers(xrXMLParser PRIVATE stdafx.h)
endif()

set_target_properties(xrXMLParser PROPERTIES PREFIX "")
