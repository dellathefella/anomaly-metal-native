// mtlState.mm — DX9 render/sampler state recorder (mirror of glState.cpp).
// The Blender simulator (tss_def.cpp) replays recorded DX9 states into these
// structs at pass-record time; the pass manager (mtlRuntime.mm) folds them
// into its live encoder state and MTLSamplerState lookups at draw time.
//
// Device-side TU: no engine stdafx (ObjC BOOL rule) — mtlState.h is the
// dual-safe contract; the mip-bias cvar crosses as a plain extern float.
#include <Metal/Metal.h>

#include <cstring>
#include <new>

#include "mtlState.h"
#include "mtlRuntime.h"

// xrRender_console.cpp (same dylib) defines the cvar INSIDE the renderer
// namespace (staged-file namespace wrapper) — the extern must match, a global
// one would emit an eager flat-namespace data binding that dlopen can't fix.
namespace xray::render::RENDER_NAMESPACE { extern float ps_r__tf_Mipbias; }
namespace mtlxr = xray::render::RENDER_NAMESPACE;

// d3d9compat.hpp enum values (duplicated here to keep this TU include-light;
// guarded by static_asserts below against the header in the .cpp-side TU).
#define MTL_D3DTADDRESS_WRAP 1
#define MTL_D3DTADDRESS_CLAMP 2
#define MTL_D3DTADDRESS_BORDER 3
#define MTL_D3DTADDRESS_MIRROR 4
#define MTL_D3DTADDRESS_CLAMPV 5
#define MTL_D3DTEXF_NONE 0
#define MTL_D3DTEXF_POINT 1
#define MTL_D3DTEXF_LINEAR 2
#define MTL_D3DTEXF_ANISOTROPIC 3

// tss.h XRDX11SAMPLERSTATETYPE (engine header not includable here):
// ANISOTROPICFILTER=256, COMPARISONFILTER=257, COMPARISONFUNC=258, MINLOD=259
#define MTL_XRDX11SAMP_COMPARISONFILTER 257u
#define MTL_XRDX11SAMP_COMPARISONFUNC 258u
#define MTL_XRDX11SAMP_MINLOD 259u

namespace xray::render::RENDER_NAMESPACE
{
mtlState::mtlState()
{
    for (auto& s : m_samplerArray)
        s = sSamplerState{};

    rasterizerCullMode = D3DCULL_CCW;

    m_pDepthStencilState.DepthEnable = 1;
    m_pDepthStencilState.DepthFunc = D3DCMP_LESSEQUAL;
    m_pDepthStencilState.DepthWriteMask = 1;
    m_pDepthStencilState.StencilEnable = 1;
    m_pDepthStencilState.StencilFailOp = D3DSTENCILOP_KEEP;
    m_pDepthStencilState.StencilDepthFailOp = D3DSTENCILOP_KEEP;
    m_pDepthStencilState.StencilPassOp = D3DSTENCILOP_KEEP;
    m_pDepthStencilState.StencilFunc = D3DCMP_ALWAYS;
    m_pDepthStencilState.StencilMask = 0xFFFFFFFF;
    m_pDepthStencilState.StencilWriteMask = 0xFFFFFFFF;
    m_pDepthStencilState.StencilRef = 0;

    m_pBlendState.BlendEnable = 1;
    m_pBlendState.SrcBlend = D3DBLEND_ONE;
    m_pBlendState.DestBlend = D3DBLEND_ZERO;
    m_pBlendState.SrcBlendAlpha = D3DBLEND_ONE;
    m_pBlendState.DestBlendAlpha = D3DBLEND_ZERO;
    m_pBlendState.BlendOp = D3DBLENDOP_ADD;
    m_pBlendState.BlendOpAlpha = D3DBLENDOP_ADD;
    m_pBlendState.ColorMask = 0xF;

    m_uiMipLODBias = 3.402823466e+38F; // FLT_MAX
}

mtlState* mtlState::Create()
{
    return new mtlState();
}

void mtlState::Apply()
{
    // Fold the recorded state into the pass manager (depth/stencil/blend/
    // cull + per-stage sampler descriptors).
    MtlApplyRecordedState(this);

    // Global texture-filter bias cvar (GL applied it onto each sampler).
    if (m_uiMipLODBias != mtlxr::ps_r__tf_Mipbias)
    {
        MtlSetGlobalMipBias(mtlxr::ps_r__tf_Mipbias);
        m_uiMipLODBias = mtlxr::ps_r__tf_Mipbias;
    }
}

void mtlState::Release()
{
    delete this;
}

void mtlState::UpdateRenderState(uint32_t name, uint32_t value)
{
    switch (name)
    {
    case D3DRS_CULLMODE:
        rasterizerCullMode = (D3DCULL)value;
        break;

    case D3DRS_ZENABLE:
        m_pDepthStencilState.DepthEnable = value ? 1u : 0u;
        break;

    case D3DRS_ZWRITEENABLE:
        m_pDepthStencilState.DepthWriteMask = value ? 1u : 0u;
        break;

    case D3DRS_ZFUNC:
        m_pDepthStencilState.DepthFunc = (D3DCMPFUNC)value;
        break;

    case D3DRS_STENCILENABLE:
        m_pDepthStencilState.StencilEnable = value ? 1u : 0u;
        break;

    case D3DRS_STENCILMASK:
        m_pDepthStencilState.StencilMask = value;
        break;

    case D3DRS_STENCILWRITEMASK:
        m_pDepthStencilState.StencilWriteMask = value;
        break;

    case D3DRS_STENCILFAIL:
        m_pDepthStencilState.StencilFailOp = (D3DSTENCILOP)value;
        break;

    case D3DRS_STENCILZFAIL:
        m_pDepthStencilState.StencilDepthFailOp = (D3DSTENCILOP)value;
        break;

    case D3DRS_STENCILPASS:
        m_pDepthStencilState.StencilPassOp = (D3DSTENCILOP)value;
        break;

    case D3DRS_STENCILFUNC:
        m_pDepthStencilState.StencilFunc = (D3DCMPFUNC)value;
        break;

    case D3DRS_STENCILREF:
        m_pDepthStencilState.StencilRef = value;
        break;

    case D3DRS_SRCBLEND:
        m_pBlendState.SrcBlend = (D3DBLEND)value;
        break;

    case D3DRS_DESTBLEND:
        m_pBlendState.DestBlend = (D3DBLEND)value;
        break;

    case D3DRS_BLENDOP:
        m_pBlendState.BlendOp = (D3DBLENDOP)value;
        break;

    case D3DRS_SRCBLENDALPHA:
        m_pBlendState.SrcBlendAlpha = (D3DBLEND)value;
        break;

    case D3DRS_DESTBLENDALPHA:
        m_pBlendState.DestBlendAlpha = (D3DBLEND)value;
        break;

    case D3DRS_BLENDOPALPHA:
        m_pBlendState.BlendOpAlpha = (D3DBLENDOP)value;
        break;

    case D3DRS_ALPHABLENDENABLE:
        m_pBlendState.BlendEnable = value ? 1u : 0u;
        break;

    case D3DRS_COLORWRITEENABLE:
    case D3DRS_COLORWRITEENABLE1:
    case D3DRS_COLORWRITEENABLE2:
    case D3DRS_COLORWRITEENABLE3:
        m_pBlendState.ColorMask = value;
        break;

    case D3DRS_LIGHTING:
    case D3DRS_FOGENABLE:
    case D3DRS_ALPHATESTENABLE:
    case D3DRS_ALPHAREF:
        // Deprecated (alpha test is shader-side clip in the DX9→SM6 shim)
        break;

    default:
        // XRDX11RS_ALPHATOCOVERAGE etc.: ignore unknowns (GL VERIFIES; keep
        // the game running through simulator gaps).
        break;
    }
}

void mtlState::UpdateSamplerState(uint32_t stage, uint32_t name, uint32_t value)
{
    if (stage >= kMaxStages)
        return;

    sSamplerState& S = m_samplerArray[stage];
    S.valid = true;

    switch (name)
    {
    case D3DSAMP_ADDRESSU:
        S.AddressU = value;
        break;
    case D3DSAMP_ADDRESSV:
        S.AddressV = value;
        break;
    case D3DSAMP_ADDRESSW:
        S.AddressW = value;
        break;
    case D3DSAMP_BORDERCOLOR:
        S.BorderColor = value;
        break;
    case D3DSAMP_MAGFILTER:
        S.Filter = (S.Filter & ~0x300u) | ((value & 0x3) << 8); // mag in bits 8..9
        break;
    case D3DSAMP_MINFILTER:
        S.Filter = (S.Filter & ~0x3u) | (value & 0x3); // min in bits 0..1
        break;
    case D3DSAMP_MIPFILTER:
        S.Filter = (S.Filter & ~0x30000u) | ((value & 0x3) << 16); // mip in bits 16..17
        break;
    case D3DSAMP_MIPMAPLODBIAS:
        // DX9 packs float as fixed-point DWORD; the GL path implicitly
        // int-converts. Mirror GL: treat the value as a float magnitude.
        S.MipMapLODBias = value;
        break;
    case D3DSAMP_MAXMIPLEVEL:
        S.MaxMipLevel = value;
        break;
    case D3DSAMP_MAXANISOTROPY:
        S.MaxAnisotropy = value;
        break;
    case MTL_XRDX11SAMP_COMPARISONFILTER: // 257
        S.CompareEnable = value ? 1u : 0u;
        break;
    case MTL_XRDX11SAMP_COMPARISONFUNC: // 258
        S.CompareFunc = value; // D3D_COMPARISON_* == D3DCMPFUNC values
        break;
    case MTL_XRDX11SAMP_MINLOD: // 259
        S.MinLOD = value;
        break;
    default:
        break;
    }
}
} // namespace xray::render::RENDER_NAMESPACE
