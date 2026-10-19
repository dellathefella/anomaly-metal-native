# xrAPI — shared renderer/engine globals (Render, DU, UIRender, ...).
# Windows builds this as a DLL from xrAPI.cpp; POSIX builds a dylib from the
# standalone globals file so engine + renderer share one copy of each symbol.

if(NOT WIN32)
    add_library(xrAPI SHARED xrAPI_posix.cpp)
    target_include_directories(xrAPI PRIVATE "${XRAY_SOURCE_DIR}/src/Include")
    set_target_properties(xrAPI PROPERTIES PREFIX "")
endif()
