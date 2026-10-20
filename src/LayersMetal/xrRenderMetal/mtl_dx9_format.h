#pragma once
// p5 Metal device layer — D3DFORMAT → MTLPixelFormat raw-value mapping for
// render targets (textures map from gli::format in mtlTexture.cpp instead).
// Plain-C++ header: raw values on both sides (D3DFMT_* values from
// src/Common/d3d9compat.hpp; MTLPixelFormat values from the SDK's
// MTLPixelFormat.h) so engine-side .cpp TUs and include-light device TUs
// share one table without pulling WinAdapter-style headers. 0 = Invalid.

#include <cstdint>

namespace xray::render::RENDER_NAMESPACE
{
// MTLPixelFormat constants used by the renderer (SDK-extracted values).
enum mtl_pixfmt : uint32_t
{
    mtlPF_INVALID = 0,
    mtlPF_A8Unorm = 1,
    mtlPF_R8Unorm = 10,
    mtlPF_R8Snorm = 12,
    mtlPF_R16Unorm = 20,
    mtlPF_R16Snorm = 22,
    mtlPF_R16Float = 25,
    mtlPF_RG8Unorm = 30,
    mtlPF_RG8Snorm = 32,
    mtlPF_B5G6R5Unorm = 40,
    mtlPF_R32Float = 55,
    mtlPF_RG16Unorm = 60,
    mtlPF_RG16Snorm = 62,
    mtlPF_RG16Float = 65,
    mtlPF_RGBA8Unorm = 70,
    mtlPF_RGBA8Unorm_sRGB = 71,
    mtlPF_BGRA8Unorm = 80,
    mtlPF_BGRA8Unorm_sRGB = 81,
    mtlPF_RGB10A2Unorm = 90,
    mtlPF_RGBA16Unorm = 110,
    mtlPF_RGBA16Snorm = 112,
    mtlPF_RGBA16Float = 115,
    mtlPF_RGBA32Float = 125,
    mtlPF_BC1_RGBA = 130,
    mtlPF_BC1_RGBA_sRGB = 131,
    mtlPF_BC2_RGBA = 132,
    mtlPF_BC2_RGBA_sRGB = 133,
    mtlPF_BC3_RGBA = 134,
    mtlPF_BC3_RGBA_sRGB = 135,
    mtlPF_BC4_RUnorm = 140,
    mtlPF_BC4_RSnorm = 141,
    mtlPF_BC5_RGUnorm = 142,
    mtlPF_BC5_RGSnorm = 143,
    mtlPF_BC6H_RGBFloat = 150,
    mtlPF_BC6H_RGBUfloat = 151,
    mtlPF_BC7_RGBAUnorm = 152,
    mtlPF_BC7_RGBAUnorm_sRGB = 153,
    mtlPF_Depth32Float = 252,
    mtlPF_Depth32Float_Stencil8 = 260,
};

// D3DFORMAT → render-target MTLPixelFormat. Depth formats land on the
// Depth32Float family (Metal's universal depth formats); `stencil` requests
// the depth+stencil variant. A2R10G10B10 gbuffer targets map to
// RGB10A2Unorm — the PS-write/sample round trip is format-symmetric, so the
// gbuffer value semantics survive the memory-order difference vs DX9.
inline uint32_t MtlMapD3DRenderTarget(int d3dFmt, bool stencil = false)
{
    switch (d3dFmt)
    {
    case 20: return mtlPF_RGBA8Unorm; // D3DFMT_R8G8B8 (rare)
    case 21: return mtlPF_BGRA8Unorm; // D3DFMT_A8R8G8B8
    case 22: return mtlPF_BGRA8Unorm; // D3DFMT_X8R8G8B8
    case 23: return mtlPF_B5G6R5Unorm; // D3DFMT_R5G6B5
    case 28: return mtlPF_A8Unorm; // D3DFMT_A8
    case 50: return mtlPF_R8Unorm; // D3DFMT_L8 (sampled via .x)
    case 31: return mtlPF_RGB10A2Unorm; // D3DFMT_A2B10G10R10
    case 35: return mtlPF_RGB10A2Unorm; // D3DFMT_A2R10G10B10
    case 81: return mtlPF_R16Unorm; // D3DFMT_L16
    case 111: return mtlPF_R16Float; // D3DFMT_R16F
    case 112: return mtlPF_RG16Float; // D3DFMT_G16R16F
    case 113: return mtlPF_RGBA16Float; // D3DFMT_A16B16G16R16F
    case 114: return mtlPF_R32Float; // D3DFMT_R32F
    case 115: return mtlPF_RGBA32Float; // D3DFMT_G32R32F (approx)
    // depth (D3DFMT_D32=71, D15S1=73, D24S8=75, D24X8=77, D24X4S4=79,
    // D16=80, D32F_LOCKABLE=82, D24FS8=83)
    case 71: case 73: case 75: case 77: case 79: case 80: case 82: case 83:
        return stencil ? mtlPF_Depth32Float_Stencil8 : mtlPF_Depth32Float;
    default:
        return stencil ? mtlPF_Depth32Float_Stencil8 : mtlPF_INVALID;
    }
}

// Depth formats by DX9 code (z-buffer creation path).
inline bool MtlIsD3DDepthFormat(int d3dFmt)
{
    switch (d3dFmt)
    {
    case 71: case 73: case 75: case 77: case 79: case 80: case 82: case 83: return true;
    default: return false;
    }
}
} // namespace xray::render::RENDER_NAMESPACE
