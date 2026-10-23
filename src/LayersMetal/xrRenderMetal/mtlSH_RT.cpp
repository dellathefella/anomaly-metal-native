// mtlSH_RT.cpp — CRT (render target) on the Metal substrate (p5 t2).
// Mirror of glSH_RT.cpp. Metal render passes take textures directly, so
// pRT/pZRT are the same id<MTLTexture> (color and depth both live as
// textures; the pass manager derives the attachment role from the format).
// Depth targets land on Depth32Float_Stencil8 — GL parity (the GL port maps
// every DX9 depth format to GL_DEPTH24_STENCIL8), so stencil is always
// available. MSAA stays disabled (r2 never requests >1 on this port).
#include "stdafx.h"
#pragma hdrstop

#include "Layers/xrRender/ResourceManager.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "Layers/xrRenderMetal/mtlRuntime.h"
#include "Layers/xrRenderMetal/mtl_dx9_format.h"

namespace xray::render::RENDER_NAMESPACE
{
CRT::~CRT()
{
    destroy();

    // release external reference
    RImplementation.Resources->_DeleteRT(this);
}

void CRT::set_slice_read(int slice) {}
void CRT::set_slice_write(u32 context_id, int slice) {}

void CRT::create(LPCSTR Name, u32 w, u32 h, D3DFORMAT f, u32 SampleCount /*= 1*/, u32 slices_num /*=1*/, Flags32 /*flags = {}*/)
{
    if (pRT) return;

    R_ASSERT(Name && Name[0] && w && h);
    _order = CPU::QPC();

    dwWidth = w;
    dwHeight = h;
    fmt = f;
    sampleCount = SampleCount;

    // Apple-GPU max texture size (MTLDevice.maxTextureSize is 16384 across the
    // supported family); the shared layer already clamps sane values.
    constexpr u32 max_dim = 16384;
    if (w > max_dim || h > max_dim)
        return;

    if (SampleCount > 1)
    {
        // MSAA disabled on Metal (GL parity; r2 pipeline runs without it).
        Msg("- Metal CRT '%s': MSAA x%u requested, falling back to x1", Name, SampleCount);
        sampleCount = SampleCount = 1;
    }

    RImplementation.Resources->Evict();

    const uint32_t mtlFmt = MtlIsD3DDepthFormat(f)
        ? mtlPF_Depth32Float_Stencil8
        : MtlMapD3DRenderTarget(f);
    if (mtlFmt == mtlPF_INVALID)
    {
        Msg("! Metal CRT '%s': unmapped D3DFORMAT %d (%ux%u)", Name, (int)f, w, h);
        return;
    }

    // framebufferOnly=false: every r2 RT is sampled back as a texture.
    pRT = HW.MtlDev.NewTexture2D(w, h, 1, mtlFmt, /*fbOnly*/ false, /*readable*/ true);
    if (!pRT)
    {
        Msg("! Metal CRT '%s': texture create failed (%ux%u fmt %u)", Name, w, h, mtlFmt);
        return;
    }
    // p6 leakbeat: RT creation telemetry — hunt for per-frame recreation of
    // named r2 targets (the unbounded liveTexMB growth).
    static int s_crtN = 0;
    if (++s_crtN <= 200 || s_crtN % 50 == 0)
        Msg("- p6 crtdbg: #%d '%s' %ux%u fmt %u", s_crtN, Name, w, h, mtlFmt);
    // Metal doesn't differentiate color/depth texture handles at this level.
    pZRT = pRT;
    target = 0; // mtd2D
    MtlDbgRTName(pRT, Name); // p5 diag
    // p5 launch235: depth targets start at far (1.0), matching GL's effective
    // initial state. The sun shadow map is never cleared when the engine skips
    // the phase — a zeroed map reads as all-shadow and blacks the direct light.
    if (MtlIsD3DDepthFormat(f))
        HW.MtlDev.ClearDepthOne(pRT);

    pTexture = RImplementation.Resources->_CreateTexture(Name);
    pTexture->surface_set(pRT);
    pTexture->size_set(w, h);
}

void CRT::destroy()
{
    if (pTexture._get())
    {
        pTexture->surface_set(nullptr);
        pTexture = nullptr;
    }
    if (pRT)
        HW.MtlDev.ReleaseResource(pRT);
    pRT = nullptr;
    pZRT = nullptr;
}

void CRT::reset_begin()
{
    destroy();
}

void CRT::reset_end()
{
    create(cName.c_str(), dwWidth, dwHeight, fmt, sampleCount, { dwFlags });
}

void CRT::resolve_into(CRT& destination) const
{
    // Color blit via a blit encoder on the frame command buffer (scaled —
    // matches the GL glBlitFramebuffer stretch semantics).
    HW.MtlDev.BlitTextureScaled(MtlCurrentCommandBuffer(), pRT, destination.pRT,
        dwWidth, dwHeight, destination.dwWidth, destination.dwHeight);
}

void resptrcode_crt::create(LPCSTR Name, u32 w, u32 h, D3DFORMAT f, u32 SampleCount /*= 1*/, u32 slices_num /*=1*/, Flags32 flags /*= {}*/)
{
    _set(RImplementation.Resources->_CreateRT(Name, w, h, f, SampleCount, 1, flags));
}
} // namespace xray::render::RENDER_NAMESPACE
