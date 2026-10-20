// xrRender_METAL.cpp — monolith renderer-module entry for the ported OpenXRay GL
// renderer (p4).
//
// On Windows the monolith engine LoadLibrary()s xrRender_PC_R2.dll; here xr_3da
// links xrRender_METAL.dylib directly and EngineAPI::Initialize calls
// DllMainXrRenderR2(). The renderer globals (Render/RenderFactory/DU/UIRender/
// vid_mode_token) live in the xrAPI dylib — this entry fills them with the GL
// implementations from the staged OpenXRay layers (xrRenderOGL_shared /
// xrRenderOGL_r2 / xrRenderGL).
//
// The OpenXRay original of this file implemented dev's newer RendererModule
// plugin API; the monolith uses the classic DllMain + RenderFactory model, so
// that entry is replaced by the bridge below. Factory method bodies (monolith
// dxRenderFactory -> GL classes) live in xrRender_METAL_factory.cpp.

#include "stdafx.h"

// Staged internal factory (render_metal::RenderFactoryImpl)…
#include "Layers/xrRender/dxRenderFactory.h"
// …and the monolith boundary class whose RenderFactoryImpl instance the
// engine's FactoryPtr binds to (defined in xrRender_METAL_factory.cpp). The
// relative include bypasses the identically named staged header.
#include "../../Layers/xrRender/dxRenderFactory.h"
#include "Layers/xrRender/dxUIRender.h"
#include "Layers/xrRender/D3DUtils.h"
#include "Include/xrAPI/xrAPI.h"

// GL implementation objects, provided by the staged OpenXRay layers.
namespace xray::render::render_metal
{
	extern CRender RImplementation;
} // namespace xray::render::render_metal

using namespace xray::render::render_metal;

// xrAPI-owned globals; the engine reads these after DllMainXrRenderR2.
// (Defined in Layers/xrAPI/xrAPI_posix.cpp — we only assign.)

// Engine-referenced capability flag (xrEngine/EngineAPI.cpp) — declared
// extern "C" there under STATIC_RENDERER_R2, so the definition must be too.
extern "C" bool SupportsAdvancedRendering()
{
	return true;
}

BOOL __cdecl DllMainXrRenderR2(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		::Render = &RImplementation;
		::RenderFactory = &::RenderFactoryImpl; // boundary facade (xrRender_METAL_factory.cpp)
		::DU = &DUImpl;
		::UIRender = &UIRenderImpl;
		break;
	case DLL_PROCESS_DETACH:
		::Render = nullptr;
		::RenderFactory = nullptr;
		::DU = nullptr;
		::UIRender = nullptr;
		break;
	}
	return TRUE;
}
