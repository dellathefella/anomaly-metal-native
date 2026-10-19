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
