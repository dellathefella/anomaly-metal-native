#pragma once
// p5 Metal device layer — handle vocabulary (mirror of xrRenderGL/CommonTypes.h).
// Metal ObjC objects cross the C++ boundary as void* (bridged id<...>); the
// .mm TUs in xrRenderMetal cast them back. Ownership: textures/buffers live in
// the MetalDevice arena (see mtl_device.h) until ReleaseResource.

#if defined(XR_PLATFORM_WINDOWS)
#include <d3d9types.h>
#else
#include "Common/d3d9compat.hpp"
#endif

namespace xray::render::RENDER_NAMESPACE
{
class mtlState;

typedef enum D3D_CLEAR_FLAG {
    D3D_CLEAR_DEPTH = 0x1L,
    D3D_CLEAR_STENCIL = 0x2L
} D3D_CLEAR_FLAG;

// Sampler comparison functions (adopt_compiler/_comp_less + blender recorder
// surface). Values are the DX9 D3DCMPFUNC wire codes because the Metal
// sampler recorder maps them through MtlMapCompare (mtl_dx9_map.h).
typedef enum D3D_COMPARISON_FUNC {
    D3D_COMPARISON_NEVER = 1,
    D3D_COMPARISON_LESS = 2,
    D3D_COMPARISON_EQUAL = 3,
    D3D_COMPARISON_LESS_EQUAL = 4,
    D3D_COMPARISON_GREATER = 5,
    D3D_COMPARISON_NOT_EQUAL = 6,
    D3D_COMPARISON_GREATER_EQUAL = 7,
    D3D_COMPARISON_ALWAYS = 8
} D3D_COMPARISON_FUNC;

// DX9-style viewport (all float) — Metal viewport is float-based natively.
struct D3D_VIEWPORT
{
    float TopLeftX, TopLeftY;
    float Width, Height;
    float MinDepth, MaxDepth;

    template <typename TopLeftCoords, typename Dimensions>
    D3D_VIEWPORT(TopLeftCoords x, TopLeftCoords y, Dimensions w, Dimensions h, float minZ, float maxZ)
        : TopLeftX(static_cast<float>(x)), TopLeftY(static_cast<float>(y)),
          Width(static_cast<float>(w)), Height(static_cast<float>(h)),
          MinDepth(minZ), MaxDepth(maxZ)
    {}
};

using D3D_QUERY = enum XR_MTL_QUERY
{
    D3D_QUERY_EVENT,
    D3D_QUERY_OCCLUSION
};

using ID3DState = mtlState;

#define DX11_ONLY(expr)			do {} while (0)

using unused_t = int[0];

// p5 Metal: id<MTLBuffer> handles (bridged). 0/nullptr = unbound.
using IndexBufferHandle = void*;
using VertexBufferHandle = void*;
using ConstantBufferHandle = void*;
using HostBufferHandle = void*;

using VertexElement = D3DVERTEXELEMENT9;
using InputElementDesc = unused_t;
} // namespace xray::render::RENDER_NAMESPACE
