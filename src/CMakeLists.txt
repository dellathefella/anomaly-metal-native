# Monolith modules, in dependency order. Renderer layers and Windows-only
# utilities are excluded on Apple platforms until ported.
add_subdirectory("3rd party/LuaJIT-proj")
add_subdirectory("3rd party/luabind")
add_subdirectory(xrCore)
add_subdirectory(xrCDB)
add_subdirectory(xrXMLParser)
