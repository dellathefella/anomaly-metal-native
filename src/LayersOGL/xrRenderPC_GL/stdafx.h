#pragma once

// D3D9 type set must precede the engine headers so the engine's POSIX shim
// (Include/POSIXShims/d3d9types.h) stands down (see XRAY_D3D9_TYPES_PROVIDED).
#include "Common/d3d9compat.hpp"

// OpenXRay's GL error-check macro lives in dev's xrDebug_macros.h; the monolith
// xrCore has no CHK_GL — define the release form here (renderer TUs only).
#ifndef CHK_GL
#define CHK_GL(expr) expr
#endif

// OpenXRay's xr_types.h spelling used by the staged layers (xrCore untouched).
using cpcstr = const char* const;

#pragma warning(disable:4995)
#include "xrEngine/stdafx.h"

// Dear ImGui texture id + xrImTextureData (OpenXRay's render.h): the staged
// renderer only passes GL names through these; imgui itself is not linked in
// this port. imgui 1.92 defines: typedef ImU64 ImTextureID.
typedef uint64_t ImTextureID;
struct xrImTextureData
{
	ImTextureID texture{};
	Fvector2 size{};
};
#pragma warning(default:4995)
#pragma warning(disable:4714)
#pragma warning( 4 : 4018 )
#pragma warning( 4 : 4244 )
#pragma warning(disable:4237)

#include "xrEngine/vis_common.h"
#include "xrEngine/Render.h"
#include "xrEngine/IGame_Level.h"

#include "xrParticles/psystem.h"

#include "glad/gl.h"
#include <SDL_opengl.h>
#include <SDL_opengl_glext.h>

#define R_GL 0
#define R_R1 1
#define R_R2 2
#define R_R3 3
#define R_R4 4
#define RENDER R_GL

// p4: dev's parallel-context counts (dev's xrEngine/Engine.h). The GL port
// renders on one immediate context, but staged graph arrays keep dev sizing.
#define R__NUM_SUN_CASCADES (3u)
#define R__NUM_AUX_CONTEXTS (1u)
#define R__NUM_PARALLEL_CONTEXTS (R__NUM_SUN_CASCADES + R__NUM_AUX_CONTEXTS)
#define R__NUM_CONTEXTS (R__NUM_PARALLEL_CONTEXTS + 1/* imm */)

// p4: the IRender boundary (IRender_interface/IRender_Sector/IRender_Light…)
// must precede the staged layers so every renderer TU sees the same types
// regardless of staged include order.
#include "xrEngine/Render.h"

// p4: synchronous task-shim (dev's xrCore/Threading; staged headers use Task
// by pointer/reference without including it themselves).
#include "xrCore/Threading/TaskManager.hpp"

#include "Layers/xrRenderGL/CommonTypes.h"

#include "Layers/xrRenderGL/glHW.h"
#include "Layers/xrRender/Debug/dxPixEventWrapper.h"

#include "Layers/xrRender/Shader.h"

#include "Layers/xrRender/R_Backend.h"
#include "Layers/xrRender/R_Backend_Runtime.h"

#include "Layers/xrRender/Blender.h"
#include "Layers/xrRender/Blender_CLSID.h"

#include "Common/_d3d_extensions.h"

#include "Layers/xrRender/ResourceManager.h"
#include "Layers/xrRender/xrRender_console.h"

#include "r2.h"
#include "gl_rendertarget.h"

namespace xray::render::RENDER_NAMESPACE
{
IC void jitter(CBlender_Compile& C)
{
    C.r_Sampler("jitter0", JITTER(0), true, D3DTADDRESS_WRAP, D3DTEXF_POINT, D3DTEXF_NONE, D3DTEXF_POINT);
    C.r_Sampler("jitter1", JITTER(1), true, D3DTADDRESS_WRAP, D3DTEXF_POINT, D3DTEXF_NONE, D3DTEXF_POINT);
    C.r_Sampler("jitter2", JITTER(2), true, D3DTADDRESS_WRAP, D3DTEXF_POINT, D3DTEXF_NONE, D3DTEXF_POINT);
    C.r_Sampler("jitter3", JITTER(3), true, D3DTADDRESS_WRAP, D3DTEXF_POINT, D3DTEXF_NONE, D3DTEXF_POINT);
}
} // namespace xray::render::RENDER_NAMESPACE
