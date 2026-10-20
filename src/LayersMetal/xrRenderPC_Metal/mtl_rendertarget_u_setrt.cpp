// mtl_rendertarget_u_setrt.cpp — render-target binding on Metal (p5 t2).
// Mirror of gl_rendertarget_u_set_rt.cpp minus the FBO machinery: recording
// pRT[]/pZB through CBackend (mtlR_Backend_Runtime.h) flags the pass manager
// (MtlTargetsChanged) so the next draw starts a fresh MTLRenderPassDescriptor
// with the new attachments.
#include "stdafx.h"
#include "mtl_rendertarget.h"

namespace xray::render::RENDER_NAMESPACE
{
void CRenderTarget::u_setrt(CBackend& cmd_list, const ref_rt& _1, const ref_rt& _2, const ref_rt& _3, const ref_rt& _zb)
{
    dwWidth[cmd_list.context_id] = 0;
    dwHeight[cmd_list.context_id] = 0;

    cmd_list.set_FB(HW.pFB);

    if (_1)
    {
        dwWidth[cmd_list.context_id]  = _1->dwWidth;
        dwHeight[cmd_list.context_id] = _1->dwHeight;
        cmd_list.set_RT(_1->pRT, 0);
    }
    else
    {
        cmd_list.set_RT(nullptr, 0);
    }

    if (_2)
    {
        if (dwWidth[cmd_list.context_id] && dwHeight[cmd_list.context_id])
        {
            VERIFY(_2->dwWidth  == dwWidth[cmd_list.context_id]);
            VERIFY(_2->dwHeight == dwHeight[cmd_list.context_id]);
        }
        else
        {
            dwWidth[cmd_list.context_id]  = _2->dwWidth;
            dwHeight[cmd_list.context_id] = _2->dwHeight;
        }
        cmd_list.set_RT(_2->pRT, 1);
    }
    else
    {
        cmd_list.set_RT(nullptr, 1);
    }

    if (_3)
    {
        if (dwWidth[cmd_list.context_id] && dwHeight[cmd_list.context_id])
        {
            VERIFY(_3->dwWidth  == dwWidth[cmd_list.context_id]);
            VERIFY(_3->dwHeight == dwHeight[cmd_list.context_id]);
        }
        else
        {
            dwWidth[cmd_list.context_id]  = _3->dwWidth;
            dwHeight[cmd_list.context_id] = _3->dwHeight;
        }
        cmd_list.set_RT(_3->pRT, 2);
    }
    else
    {
        cmd_list.set_RT(nullptr, 2);
    }

    if (_zb)
    {
        if (dwWidth[cmd_list.context_id] && dwHeight[cmd_list.context_id])
        {
            VERIFY(_zb->dwWidth  == dwWidth[cmd_list.context_id]);
            VERIFY(_zb->dwHeight == dwHeight[cmd_list.context_id]);
        }
        else
        {
            dwWidth[cmd_list.context_id]  = _zb->dwWidth;
            dwHeight[cmd_list.context_id] = _zb->dwHeight;
        }
        cmd_list.set_ZB(_zb->pZRT);
    }
    else
    {
        cmd_list.set_ZB(nullptr);
    }

    VERIFY(dwWidth[cmd_list.context_id]  != 0);
    VERIFY(dwHeight[cmd_list.context_id] != 0);
}

void CRenderTarget::u_setrt(CBackend& cmd_list, const ref_rt& _1, const ref_rt& _2, const ref_rt& _zb)
{
    dwWidth[cmd_list.context_id]  = 0;
    dwHeight[cmd_list.context_id] = 0;

    cmd_list.set_FB(HW.pFB);

    if (_1)
    {
        dwWidth[cmd_list.context_id]  = _1->dwWidth;
        dwHeight[cmd_list.context_id] = _1->dwHeight;
        cmd_list.set_RT(_1->pRT, 0);
    }
    else
    {
        cmd_list.set_RT(nullptr, 0);
    }

    if (_2)
    {
        if (dwWidth[cmd_list.context_id] && dwHeight[cmd_list.context_id])
        {
            VERIFY(_2->dwWidth  == dwWidth[cmd_list.context_id]);
            VERIFY(_2->dwHeight == dwHeight[cmd_list.context_id]);
        }
        else
        {
            dwWidth[cmd_list.context_id]  = _2->dwWidth;
            dwHeight[cmd_list.context_id] = _2->dwHeight;
        }
        cmd_list.set_RT(_2->pRT, 1);
    }
    else
    {
        cmd_list.set_RT(nullptr, 1);
    }

    if (_zb)
    {
        if (dwWidth[cmd_list.context_id] && dwHeight[cmd_list.context_id])
        {
            VERIFY(_zb->dwWidth  == dwWidth[cmd_list.context_id]);
            VERIFY(_zb->dwHeight == dwHeight[cmd_list.context_id]);
        }
        else
        {
            dwWidth[cmd_list.context_id]  = _zb->dwWidth;
            dwHeight[cmd_list.context_id] = _zb->dwHeight;
        }
        cmd_list.set_ZB(_zb->pZRT);
    }
    else
    {
        cmd_list.set_ZB(nullptr);
    }

    VERIFY(dwWidth[cmd_list.context_id]  != 0);
    VERIFY(dwHeight[cmd_list.context_id] != 0);
}

void CRenderTarget::u_setrt(CBackend& cmd_list, u32 W, u32 H, void* _1, void* _2, void* _3, void* zb)
{
    VERIFY(W != 0);
    VERIFY(H != 0);

    dwWidth[cmd_list.context_id]  = W;
    dwHeight[cmd_list.context_id] = H;

    cmd_list.set_FB(HW.pFB);

    cmd_list.set_RT(_1, 0);
    cmd_list.set_RT(_2, 1);
    cmd_list.set_RT(_3, 2);
    cmd_list.set_ZB(zb);
}
} // namespace xray::render::RENDER_NAMESPACE
