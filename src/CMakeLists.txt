# Monolith modules, in dependency order. Renderer layers and Windows-only
# utilities are excluded on Apple platforms until ported.
add_subdirectory("3rd party/LuaJIT-proj")
add_subdirectory("3rd party/luabind")
add_subdirectory("3rd party/ode")
add_subdirectory("3rd party/crypto")
add_subdirectory("3rd party/discord")
add_subdirectory("3rd party/cximage")
add_subdirectory(xrCore)
add_subdirectory(xrCDB)
add_subdirectory(xrXMLParser)
add_subdirectory("Layers/xrAPI")
add_subdirectory(xrNetServer)
add_subdirectory(xrSound)
add_subdirectory(xrCPU_Pipe)
add_subdirectory(xrPhysics)
add_subdirectory(xrParticles)
add_subdirectory(xrGame)
add_subdirectory(xrEngine)

# p4: ported OpenXRay GL renderer (OFF by default until the interface bridge lands)
option(XRAY_RENDERER_GL "Build the ported OpenXRay GL renderer" OFF)
if(XRAY_RENDERER_GL)
	add_subdirectory("LayersOGL/xrRenderPC_GL")
	# STATIC_RENDERER_R2 model: engine renderer calls are undefined symbols
	# resolved via dynamic_lookup — loading xrRender_GL as a xr_3da dependency
	# registers them at launch.
	target_link_libraries(xr_3da PRIVATE xrRender_GL)
endif()

# p5: native Metal renderer. Currently the metal_poc foundation (runtime
# HLSL->SPIR-V->MSL shader pipeline + Metal device/render proof-of-life); the
# xrRenderMetal device backend builds on top of it.
option(XRAY_RENDERER_METAL "Build the native Metal renderer foundations" OFF)
if(XRAY_RENDERER_METAL)
	add_subdirectory("LayersMetal")
endif()
