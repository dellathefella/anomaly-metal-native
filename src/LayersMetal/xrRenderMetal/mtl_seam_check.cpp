// mtl_seam_check.cpp — p5 compile-seam smoke TU.
// Includes the full renderer stdafx graph (staged xrRender/xrRender_R2 headers
// + the Metal device layer) so header-level USE_METAL branch errors surface in
// one translation unit before the full 150-TU build runs.
#include "stdafx.h"

namespace xray::render::render_metal
{
// Instantiate the seam vocabulary (compile-time only).
static void seam_probe()
{
	CHW* hw = &HW;
	(void)hw;

	D3D_VIEWPORT vp{ 0, 0, 640, 480, 0.f, 1.f };
	(void)vp;

	VertexElement ve{};
	(void)ve;

	// CBackend inline runtime compiles?
	CBackend& cmd = RImplementation.get_imm_context().cmd_list;
	cmd.set_RT(nullptr, 0);
	cmd.set_ZB(nullptr);
	cmd.set_CullMode(CULL_NONE);
	cmd.set_Z(TRUE);
	cmd.set_ZFunc(D3DCMP_LESSEQUAL);
	cmd.set_Scissor(nullptr);
	cmd.SetViewport(vp);
	cmd.set_Vertices(nullptr, 0);
	cmd.set_Indices(nullptr);
	cmd.Render(D3DPT_POINTLIST, 0, 0);
}
} // namespace xray::render::render_metal
