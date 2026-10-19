# xrNetServer — X-Ray net transport (DirectPlay-based).
# On POSIX the DP transport compiles against Include/POSIXShims/dplay/dplay8.h
# and links against the in-module stub (dplay_stub_posix.cpp): connection
# attempts fail cleanly, singleplayer is unaffected. Multiplayer is
# Windows-only.

file(GLOB XRNETSERVER_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrNetServer ${XRNETSERVER_SOURCES})

target_include_directories(xrNetServer PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

if(NOT MSVC)
    target_compile_definitions(xrNetServer PRIVATE _MT)
    target_compile_options(xrNetServer PRIVATE -w -fdelayed-template-parsing)
    target_link_options(xrNetServer PRIVATE "-undefined" "dynamic_lookup")
endif()

target_link_libraries(xrNetServer PUBLIC xrCore)

set_target_properties(xrNetServer PROPERTIES PREFIX "")
