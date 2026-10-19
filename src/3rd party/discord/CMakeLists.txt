# discord — Anomaly's bundled discord-game-sdk C++ wrapper.
# Portable C++; the proprietary discord_game_sdk shared library is loaded at
# runtime. The engine disables rich presence on macOS (Init_Discord guard),
# so nothing here is actually invoked on Apple platforms.

file(GLOB DISCORD_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(xrDiscord ${DISCORD_SOURCES})

target_include_directories(xrDiscord
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

if(NOT MSVC)
    target_compile_options(xrDiscord PRIVATE -w)
    target_link_options(xrDiscord PRIVATE "-undefined" "dynamic_lookup")
endif()

set_target_properties(xrDiscord PROPERTIES PREFIX "")
