#pragma once
// p5 Metal device layer — CBackend runtime (mirror of glR_Backend_Runtime.h).
// GL calls were immediate; here the setters record into CBackend's existing
// cached-state members and notify the pass manager (mtlRuntime.h), which
// replays everything onto an MTLRenderCommandEncoder at draw/clear time.
//
// This header is the .cpp-side adapter: it sees engine types (CBackend,
// Fcolor, Irect, R_constant_table) and converts to the plain device contract.

#include "mtlState.h"
#include "mtlRuntime.h"
#include "mtlShader.h"
#include <execinfo.h> // p9 albedobt

namespace xray::render::RENDER_NAMESPACE
{
IC void CBackend::set_xform(u32 ID, const Fmatrix& M)
{
    stat.xforms++;
    // p5 Metal: transforms live in the pass cbuffer image; the R_xforms
    // constant handlers (set_c_w/vp/wvp...) push them via set_c().
}

IC void* CBackend::get_FB()
{
    return pFB;
}

IC void CBackend::set_FB(void* FB)
{
    // Metal has no framebuffer objects; base-target identity is pRT/pZB.
    pFB = FB;
}

IC void CBackend::set_RT(void* RT, u32 ID)
{
    if (RT != pRT[ID])
    {
        PGO(Msg("MTL:setRT[%d]", ID));
        // p5 launch185/189: trace every secondary color-attachment bind — the
        // g-buffer MRT sequence (albedo must appear as slot 1 or 2).
        // launch189: in-game trace of EVERY bind (all slots) of albedo/position:
        // names the pass that rebinds and overwrites the g-buffer after
        // geometry (the wipe culprit).
        {
            extern unsigned long long MtlDbgDrawCount();
            const char* bn = RT ? MtlDbgRTGetName(RT) : "-";
            bool hot = bn && (strstr(bn, "albedo") || strstr(bn, "position"));
            static int s_srtN = 0;
            // p5 launch190: the albedo-alone slot-0 bind right after geometry
            // is the wipe culprit — backtrace names the function that makes it.
            if (hot && ID == 0 && strstr(bn, "albedo") && MtlDbgDrawCount() > 60000)
            {
                static int s_btN = 0;
                if (s_btN++ < 8)
                {
                    void* frames[14];
                    int nbt = backtrace(frames, 14);
                    char** syms = backtrace_symbols(frames, nbt);
                    std::string s;
                    for (int i = 1; i < nbt && i < 10; i++)
                    {
                        s += syms[i] ? syms[i] : "?";
                        s += "\n          ";
                    }
                    Msg("- p9 albedobt draws=%llu:\n          %s", MtlDbgDrawCount(),
                        s.c_str());
                    if (syms)
                        free(syms);
                }
            }
            if (hot && MtlDbgDrawCount() > 60000 && s_srtN++ < 60)
                Msg("- p9 setrt: ctx=%d slot=%u rt=%p name=%s draws=%llu", (int)context_id, ID,
                    RT, bn, MtlDbgDrawCount());
            else if (ID > 0 && ID < 4)
            {
                static int s_srtN2 = 0;
                if (s_srtN2++ < 8)
                    Msg("- p5 setrt: ctx=%d slot=%u rt=%p name=%s", (int)context_id, ID, RT, bn);
            }
        }
        stat.target_rt++;
        pRT[ID] = RT;
        MtlTargetsChanged(pRT, pZB);
    }
}

IC void CBackend::set_ZB(void* ZB)
{
    if (ZB != pZB)
    {
        PGO(Msg("MTL:setZB"));
        stat.target_zb++;
        pZB = ZB;
        MtlTargetsChanged(pRT, pZB);
    }
}

IC void CBackend::ClearRT(void* rt, const Fcolor& color)
{
    MtlClearColor(rt, color.r, color.g, color.b, color.a);
}

IC void CBackend::ClearZB(void* zb, float depth)
{
    MtlClearDepth(zb, depth, -1);
}

IC void CBackend::ClearZB(void* zb, float depth, u8 stencil)
{
    MtlClearDepth(zb, depth, stencil);
}

IC bool CBackend::ClearRTRect(void* rt, const Fcolor& color, size_t numRects, const Irect* rects)
{
    // Flatten Irect array to l,t,r,b int32 quads for the plain contract.
    xr_vector<int32_t> flat;
    flat.reserve(numRects * 4);
    for (size_t i = 0; i < numRects; ++i)
    {
        flat.push_back(rects[i].left);
        flat.push_back(rects[i].top);
        flat.push_back(rects[i].right);
        flat.push_back(rects[i].bottom);
    }
    return MtlClearColorRect(rt, color.r, color.g, color.b, color.a, u32(numRects), flat.data());
}

IC bool CBackend::ClearZBRect(void* zb, float depth, size_t numRects, const Irect* rects)
{
    xr_vector<int32_t> flat;
    flat.reserve(numRects * 4);
    for (size_t i = 0; i < numRects; ++i)
    {
        flat.push_back(rects[i].left);
        flat.push_back(rects[i].top);
        flat.push_back(rects[i].right);
        flat.push_back(rects[i].bottom);
    }
    return MtlClearDepthRect(zb, depth, u32(numRects), flat.data());
}

ICF void CBackend::set_Format(SDeclaration* _decl)
{
    if (decl != _decl)
    {
        PGO(Msg("MTL:v_format:%x", _decl));
#ifdef DEBUG
		stat.decl++;
#endif
        decl = _decl;
        MtlSetVertexLayout(_decl ? _decl->dcl_code.data() : nullptr,
            _decl ? u32(_decl->dcl_code.size()) : 0);

        // Clear cached index buffer
        ib = nullptr;
    }
}

ICF void CBackend::set_PS(void* _ps, LPCSTR _n)
{
    if (ps != _ps)
    {
        PGO(Msg("MTL:Pshader:%s", _n ? _n : "?"));
        stat.ps++;
        ps = _ps;
#ifdef DEBUG
		ps_name = _n;
#endif
    }
}

ICF void CBackend::set_GS(void* _gs, LPCSTR _n)
{
    // Metal has no geometry shaders (the DX9 r2 corpus uses none).
    UNUSED(_gs);
    UNUSED(_n);
}

ICF void CBackend::set_VS(void* _vs, LPCSTR _n)
{
    if (vs != _vs)
    {
        PGO(Msg("MTL:Vshader:%s", _n ? _n : "?"));
        stat.vs++;
        vs = _vs;
#ifdef DEBUG
		vs_name = _n;
#endif
        if (decl)
            MtlSetVertexLayout(decl->dcl_code.data(), u32(decl->dcl_code.size())); // layout is VS-specific
    }
}

ICF void CBackend::set_PP(void* _pp, pcstr _n)
{
    if (pp != _pp)
    {
        PGO(Msg("MTL:PPshader:%s", _n ? _n : "?"));
        stat.pp++;
        pp = _pp;
#ifdef DEBUG
        pp_name = _n;
#endif
    }
}

ICF void CBackend::set_Vertices(void* _vb, u32 _vb_stride)
{
    if (vb != _vb || vb_stride != _vb_stride)
    {
        PGO(Msg("MTL:VB:%x,%d", _vb, _vb_stride));
#ifdef DEBUG
		stat.vb++;
#endif
        vb = _vb;
        vb_stride = _vb_stride;
    }
}

ICF void CBackend::set_Indices(void* _ib)
{
    if (ib != _ib)
    {
        PGO(Msg("MTL:IB:%x", _ib));
#ifdef DEBUG
		stat.ib++;
#endif
        ib = _ib;
    }
}

IC u32 TranslateTopology(D3DPRIMITIVETYPE T)
{
    // 0=point,1=linelist,2=linestrip,3=trilist,4=tristrip,5=trifan
    // (pass-manager encoding; MTLPrimitiveType mapping lives in mtlRuntime.mm)
    switch (T)
    {
    case D3DPT_POINTLIST: return 0;
    case D3DPT_LINELIST: return 1;
    case D3DPT_LINESTRIP: return 2;
    case D3DPT_TRIANGLELIST: return 3;
    case D3DPT_TRIANGLESTRIP: return 4;
    case D3DPT_TRIANGLEFAN: return 5;
    default: NODEFAULT; return 0;
    }
}

IC u32 GetIndexCount(D3DPRIMITIVETYPE T, u32 iPrimitiveCount)
{
    switch (T)
    {
    case D3DPT_POINTLIST:
        return iPrimitiveCount;
    case D3DPT_LINELIST:
        return iPrimitiveCount * 2;
    case D3DPT_LINESTRIP:
        return iPrimitiveCount + 1;
    case D3DPT_TRIANGLELIST:
        return iPrimitiveCount * 3;
    case D3DPT_TRIANGLESTRIP:
        return iPrimitiveCount + 2;
    case D3DPT_TRIANGLEFAN:
        return iPrimitiveCount + 2; // fan vertex count = faces + 2
    default: NODEFAULT;
#ifdef DEBUG
		return 0;
#endif // #ifdef DEBUG
    }
}

// Assemble the plain draw-state from CBackend's cached state.
ICF MtlDrawState CBackend::mtl_collect_draw_state()
{
    MtlDrawState ds;
    ds.vb = vb;
    ds.vbStride = vb_stride;
    ds.ib = ib;
    if (decl)
    {
        ds.declElements = decl->dcl_code.data();
        ds.declCount = u32(decl->dcl_code.size());
    }
    ds.vs = vs;
    ds.ps = ps;
    ds.pp = pp;
    ds.state = state;
    return ds;
}

ICF void CBackend::Render(D3DPRIMITIVETYPE T, u32 baseV, u32 startV, u32 countV, u32 startI, u32 PC)
{
    u32 Topology = TranslateTopology(T);
    u32 iIndexCount = GetIndexCount(T, PC);

    stat.render.calls++;
    stat.render.verts += countV;
    stat.render.polys += PC;
    constants.flush();
    MtlDrawIndexed(Topology, iIndexCount, startI, baseV, mtl_collect_draw_state());
    PGO(Msg("MTL:DIP:%dv/%df", countV, PC));
}

ICF void CBackend::Render(D3DPRIMITIVETYPE T, u32 startV, u32 PC)
{
    u32 Topology = TranslateTopology(T);
    u32 iIndexCount = GetIndexCount(T, PC);

    stat.render.calls++;
    stat.render.verts += iIndexCount;
    stat.render.polys += PC;
    constants.flush();
    MtlDrawArrays(Topology, startV, iIndexCount, mtl_collect_draw_state());
    PGO(Msg("MTL:DIP:%dv/%df", iIndexCount, PC));
}

IC void CBackend::set_Geometry(SGeometry* _geom)
{
    set_Format(&*_geom->dcl);

    set_Vertices(_geom->vb, _geom->vb_stride);
    set_Indices(_geom->ib);
}

IC void CBackend::set_Scissor(const Irect* R)
{
    // Metal scissor is top-left origin — no Y inversion (unlike GL).
    if (R)
        MtlSetScissor(true, R->left, R->top, R->right, R->bottom);
    else
        MtlSetScissor(false, 0, 0, 0, 0);
}

IC void CBackend::SetViewport(const D3D_VIEWPORT& viewport) const
{
    MtlSetViewport(viewport.TopLeftX, viewport.TopLeftY, viewport.Width, viewport.Height,
        viewport.MinDepth, viewport.MaxDepth);
}

IC void CBackend::set_Stencil(u32 _enable, u32 _func, u32 _ref, u32 _mask, u32 _writemask, u32 _fail, u32 _pass,
                              u32 _zfail)
{
    if (stencil_enable != _enable || stencil_func != _func || stencil_ref != _ref || stencil_mask != _mask ||
        stencil_writemask != _writemask || stencil_fail != _fail || stencil_pass != _pass || stencil_zfail != _zfail)
    {
        stencil_enable = _enable;
        stencil_func = _func;
        stencil_ref = _ref;
        stencil_mask = _mask;
        stencil_writemask = _writemask;
        stencil_fail = _fail;
        stencil_pass = _pass;
        stencil_zfail = _zfail;
        MtlSetStencil(_enable, _func, _ref, _mask, _writemask, _fail, _pass, _zfail);
    }
}

IC void CBackend::set_Z(u32 _enable)
{
    if (z_enable != _enable)
    {
        z_enable = _enable;
        MtlSetDepth(_enable, z_func, u32(-1));
    }
}

IC void CBackend::set_ZFunc(u32 _func)
{
    if (z_func != _func)
    {
        z_func = _func;
        MtlSetDepth(z_enable, _func, u32(-1));
    }
}

IC void CBackend::set_AlphaRef(u32 _value)
{
    // DX9 alpha-test via ALPHAREF/ALPHAFUNC: Metal has no fixed alpha test —
    // shaders clip (the DX9→SM6 shim maps D3D ALPHA ops to clip()). Recorded
    // for the recorder path; pass manager keeps the value for state identity.
    MtlSetAlphaRef(_value);
}

IC void CBackend::set_ColorWriteEnable(u32 _mask)
{
    if (colorwrite_mask != _mask)
    {
        colorwrite_mask = _mask;
        MtlSetBlend(u32(-1), u32(-1), u32(-1), u32(-1), u32(-1), u32(-1), u32(-1), _mask);
    }
}

ICF void CBackend::set_CullMode(u32 _mode)
{
    if (cull_mode != _mode)
    {
        cull_mode = _mode;
        MtlSetCull(_mode);
    }
}

ICF void CBackend::set_FillMode(u32 _mode)
{
    if (fill_mode != _mode)
    {
        fill_mode = _mode;
        MtlSetFillMode(_mode); // wireframe = debug path (p5 t3)
    }
}

ICF void CBackend::SetTextureFactor(u32 /*factor*/) const
{
    // Not supported
}

ICF void CBackend::SetAmbient(u32 /*factor*/) const
{
    // Not supported
}

ICF void CBackend::set_VS(ref_vs& _vs)
{
    set_VS(_vs->sh, _vs->cName.c_str());
}

IC void CBackend::set_Constants(R_constant_table* C)
{
    // caching
    if (ctable == C) return;
    ctable = C;
    xforms.unmap();
    hemi.unmap();
    tree.unmap();

    PGO(Msg("MTL:c-table"));

    // Staging block size = max(offset+size) across the table's stage loads.
    u32 vsSize = 0, psSize = 0;
    if (C)
    {
        for (const ref_constant& Cs : C->table)
        {
            const R_constant& c = *Cs;
            if (c.vs.offset != u32(-1) && c.vs.offset + c.vs.size > vsSize)
                vsSize = c.vs.offset + c.vs.size;
            if (c.pp.offset != u32(-1) && c.pp.offset + c.pp.size > vsSize)
                vsSize = c.pp.offset + c.pp.size;
            if (c.ps.offset != u32(-1) && c.ps.offset + c.ps.size > psSize)
                psSize = c.ps.offset + c.ps.size;
            if (c.pp.offset != u32(-1) && c.pp.offset + c.pp.size > psSize)
                psSize = c.pp.offset + c.pp.size;
        }
    }
    MtlConstBegin(vsSize, psSize);

    if (nullptr == C) return;

    // process constant-loaders
    for (auto& Cs : C->table)
        if (Cs->handler) Cs->handler->setup(*this, &*Cs);

    // GL-parity sticky-state replay: the staged logic sets xform matrices once
    // per frame and hemi colors once per level, relying on the backend to
    // re-apply cached values after a shader switch (glr_constants_cache).
    // MtlConstBegin zeroed the staging block above and setup() only rebinds
    // constant pointers, so without this the VS sees zero matrices and every
    // scene draw rasterizes nothing (marsh black-screen root cause, launch88).
    xforms.reemit();
    hemi.reemit();
}

void CBackend::set_pass_targets(const ref_rt& _1, const ref_rt& _2, const ref_rt& _3, const ref_rt& zb)
{
    if (_1)
    {
        curr_rt_width  = _1->dwWidth;
        curr_rt_height = _1->dwHeight;
    }
    else
    {
        VERIFY(zb);
        curr_rt_width  = zb->dwWidth;
        curr_rt_height = zb->dwHeight;
    }

    set_RT(_1 ? _1->pRT : nullptr, 0);
    set_RT(_2 ? _2->pRT : nullptr, 1);
    set_RT(_3 ? _3->pRT : nullptr, 2);
    set_ZB(zb ? zb->pZRT : nullptr);

    const D3D_VIEWPORT viewport = { 0, 0, curr_rt_width, curr_rt_height, 0.f, 1.f };
    SetViewport(viewport);
}
} // namespace xray::render::RENDER_NAMESPACE
