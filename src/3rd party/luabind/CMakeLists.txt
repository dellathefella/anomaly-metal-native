# luabind (monolith's beta7-devel.rc4 fork) — C++ <-> Lua bindings used
# throughout xrGame/xrServerEntities. Built against the vendored xrLuaJIT.
file(GLOB LUABIND_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp")

add_library(luabind ${LUABIND_SOURCES} luabind_memory.cpp library_linkage.cpp)

target_include_directories(luabind
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(luabind PUBLIC xrLuaJIT)

# The monolith's luabind fork still uses boost mpl/function/bind/preprocessor;
# use the boost that shipped with the monolith SDK (vendored copy).
target_include_directories(luabind PRIVATE "${XRAY_SOURCE_DIR}/src/3rd party")

target_precompile_headers(luabind PRIVATE pch.h)

if(NOT MSVC)
    # The monolith-era luabind relies on MSVC's delayed template-body parsing
    # (bodies reference classes completed later in the same header).
    target_compile_options(luabind PRIVATE -w -fdelayed-template-parsing)
    target_compile_definitions(luabind PRIVATE _MT)
endif()

set_target_properties(luabind PROPERTIES PREFIX "")
