#pragma once

// D3D9 type set must precede the engine headers so the engine's POSIX shim
// (Include/POSIXShims/d3d9types.h) stands down (see XRAY_D3D9_TYPES_PROVIDED).
#include "Common/d3d9compat.hpp"

// OpenXRay's GL error-check macro lives in dev's xrDebug_macros.h; the monolith
// xrCore has no CHK_GL — define the release form here (renderer TUs only).
#ifndef CHK_GL
#define CHK_GL(expr) expr
#endif

// p4: dev's assert-with-recovery form; release builds strip the assert, so the
// cure clause is a no-op here.
#ifndef R_ASSERT1_CURE
#define R_ASSERT1_CURE(FUNC, CURE) R_ASSERT1(FUNC)
#endif

// p4: dev's Tracy profiling macros — no-op in the port (xrCore has no tracy).
#ifndef ZoneScoped
#define ZoneScoped
#define ZoneScopedN(x)
#endif

// p4: dev's path-delimiter macro (rgl_shaders cache paths) and cpstr spelling
// (xrCore/xr_types.h). POSIX separator for gamedata-relative paths.
#ifndef DELIMITER
#define DELIMITER "/"
#endif
#ifndef cpstr
using cpstr = char* const;
#endif

// p4: dev's global SoC-resources toggle (xrEngine/defines.h); the monolith has
// no such switch — defined false in xrRender_GL_factory.cpp.
extern bool ShadowOfChernobylMode;

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
// regardless of staged include order. CameraManager.h brings SPPInfo
// (SetPostProcessParams) which the staged r2.h references unqualified.
#include "xrEngine/Render.h"
#include "xrEngine/CameraManager.h"

// p4: dev's SpatialBase (default ISpatial implementation, dev xrCDB/ISpatial.h)
// on top of the monolith's ISpatial — the staged light class derives from it.
// The monolith ISpatial already provides the virtuals the staged overrides
// target (spatial_move/spatial_sector_point/dcast_Light) and `spatial`.
#include "xrCDB/ISpatial.h"
class SpatialBase : public virtual ISpatial
{
public:
	explicit SpatialBase(ISpatial_DB& space) : ISpatial(&space) {}
	virtual ~SpatialBase() {}

	virtual bool spatial_inside() { return spatial.sector != nullptr; }
};

// p4: dev's CRenderDevice::mInvView (per-frame inverse view held by the dev
// device) — the monolith device has no such member; compute on demand (only
// shadow/accum pass call sites).
ICF Fmatrix xr_inv_view()
{
	Fmatrix m;
	m.invert(Device.mView); // 4x3 invert — view matrices are affine (dev mInvView use-sites)
	return m;
}

// p4: dev's size-less strconcat overloads (xrCore/string_concatenations.h) for
// fixed char arrays. Implemented as a manual append loop because some staged
// call sites pass more string args than the monolith's strconcat overloads
// (max 6) accept.
inline pcstr xr_strcat_arg(pcstr s) { return s; }
template <class T, class = std::enable_if_t<!std::is_convertible_v<const T&, pcstr>>>
inline pcstr xr_strcat_arg(const T& v) { return v.c_str(); }
template <size_t Size, class... Args>
inline LPSTR strconcat(char (&dest)[Size], const Args&... sources)
{
	const char* arr[] = { xr_strcat_arg(sources)... };
	dest[0] = '\0';
	for (const char* s : arr)
	{
		const size_t used = std::strlen(dest);
		if (used + 1 >= Size)
			break;
		std::strncat(dest, s, Size - used - 1);
	}
	return dest;
}

// p4: dev containers key std::unordered_map by shared_str; the monolith's
// shared_str has no std::hash specialization (MSVC-era stdext::hash_map).
#include <string_view>
namespace std
{
	template <>
	struct hash<shared_str>
	{
		size_t operator()(const shared_str& v) const
		{
			return std::hash<std::string_view>{}(v.c_str() ? std::string_view(v.c_str()) : std::string_view());
		}
	};
} // namespace std

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
