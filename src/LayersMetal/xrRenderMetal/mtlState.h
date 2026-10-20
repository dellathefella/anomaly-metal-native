#pragma once
// p5 Metal device layer — per-pass state recorder (mirror of xrRenderGL/glState.h).
// The Blender recorder simulates DX9 render/sampler states into these structs
// (mtlState.mm); the pass manager reads them at draw time and maps them onto
// MTLDepthStencilState / blend / cull / sampler states.
//
// DUAL-SAFE HEADER: device .mm TUs compile WITHOUT the engine stdafx (ObjC's
// BOOL is `signed char`, the engine's is `int` — one TU cannot include both).
// Therefore: stdint types only, no engine includes, no BOOL.

#include <cstdint>

#if defined(XR_PLATFORM_WINDOWS)
#include <d3d9types.h>
#else
#include "Common/d3d9compat.hpp"
#endif

namespace xray::render::RENDER_NAMESPACE
{
typedef struct
{
    uint32_t DepthEnable;
    uint32_t DepthWriteMask;
    D3DCMPFUNC DepthFunc;
    uint32_t StencilEnable;
    uint32_t StencilMask;
    uint32_t StencilWriteMask;
    D3DSTENCILOP StencilFailOp;
    D3DSTENCILOP StencilDepthFailOp;
    D3DSTENCILOP StencilPassOp;
    D3DCMPFUNC StencilFunc;
    uint32_t StencilRef;
} D3D_DEPTH_STENCIL_STATE;

typedef struct
{
    uint32_t BlendEnable;
    D3DBLEND SrcBlend;
    D3DBLEND DestBlend;
    D3DBLENDOP BlendOp;
    D3DBLEND SrcBlendAlpha;
    D3DBLEND DestBlendAlpha;
    D3DBLENDOP BlendOpAlpha;
    uint32_t ColorMask;
} D3D_BLEND_STATE;

class mtlState
{
private:
    D3DCULL rasterizerCullMode;
    D3D_DEPTH_STENCIL_STATE m_pDepthStencilState;
    D3D_BLEND_STATE m_pBlendState;
    float m_uiMipLODBias;

    // Recorded sampler states per stage (DX9 TSS sim), consumed by the pass
    // manager to pick MTLSamplerStates at draw time.
    struct sSamplerState
    {
        uint32_t AddressU, AddressV, AddressW;
        uint32_t Filter;
        uint32_t MaxAnisotropy;
        uint32_t MipMapLODBias;
        uint32_t BorderColor;
        bool valid;
    };
    // CTexture::mtMaxCombinedShaderTextures (16 ps + 4 vs + 16 gs) — inlined
    // here to keep this header engine-free (see dual-safety note above).
    static constexpr uint32_t kMaxStages = 36;
    sSamplerState m_samplerArray[kMaxStages];

public:
    mtlState();

    static mtlState* Create();

    void Apply();
    void Release();

    void UpdateRenderState(uint32_t name, uint32_t value);
    void UpdateSamplerState(uint32_t stage, uint32_t name, uint32_t value);

    // Pass-manager accessors (mtlRuntime.mm)
    const D3D_DEPTH_STENCIL_STATE& DepthStencil() const { return m_pDepthStencilState; }
    const D3D_BLEND_STATE& Blend() const { return m_pBlendState; }
    D3DCULL Cull() const { return rasterizerCullMode; }
    float MipLODBias() const { return m_uiMipLODBias; }
    const sSamplerState& SamplerState(uint32_t stage) const { return m_samplerArray[stage]; }
};
} // namespace xray::render::RENDER_NAMESPACE
