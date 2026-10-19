# ODE (monolith's bundled fork) — rigid-body physics backend for xrPhysics.
# Mirrors contrib/msvc7/ode_default (the project xrPhysics references on MSVC):
# defines dSINGLE + dNODEBUG, sources = ode/src + default integrator.

file(GLOB ODE_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/ode/src/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/ode/src/*.c"
)

add_library(xrODE ${ODE_SOURCES}
    contrib/msvc7/ode_default/de_padf_integration.cpp
)

target_include_directories(xrODE
    PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_compile_definitions(xrODE
    PUBLIC
    dSINGLE
    "$<$<CONFIG:Release>:dNODEBUG>"
)

if(NOT MSVC)
    target_compile_definitions(xrODE PRIVATE _MT)
    target_compile_options(xrODE PRIVATE -w)
    target_link_options(xrODE PRIVATE "-undefined" "dynamic_lookup")
endif()

set_target_properties(xrODE PROPERTIES PREFIX "")
