# tests — small runtime harnesses linked against the engine libs
add_executable(xr_smoke xr_smoke.cpp)
target_link_libraries(xr_smoke PRIVATE xrCore)
target_include_directories(xr_smoke PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src/xrCore")
if(NOT WIN32)
    target_compile_definitions(xr_smoke PRIVATE _MT)
endif()
set_target_properties(xr_smoke PROPERTIES
    BUILD_RPATH "${CMAKE_BINARY_DIR}/bin"
    INSTALL_RPATH "@loader_path"
)

add_executable(xr_lua_smoke xr_lua_smoke.cpp)
target_link_libraries(xr_lua_smoke PRIVATE xrLuaJIT)
set_target_properties(xr_lua_smoke PROPERTIES
    BUILD_RPATH "${CMAKE_BINARY_DIR}/bin"
    INSTALL_RPATH "@loader_path"
)

add_executable(xr_fs_get xr_fs_get.cpp)
target_link_libraries(xr_fs_get PRIVATE xrCore)
target_include_directories(xr_fs_get PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src/xrCore")
if(NOT WIN32)
    target_compile_definitions(xr_fs_get PRIVATE _MT)
endif()
set_target_properties(xr_fs_get PROPERTIES
    BUILD_RPATH "${CMAKE_BINARY_DIR}/bin"
    INSTALL_RPATH "@loader_path"
)
