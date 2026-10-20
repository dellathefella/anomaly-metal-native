#pragma once
// p5 Metal device layer — DX9 fixed-function enum → Metal raw-value mapping.
// Plain-C++ header (usable from both .mm device TUs and the substrate). The
// returned values are the raw MTLEnum values documented per function; callers
// cast to the ObjC enum types inside .mm files.
//
// Enum value sources: D3D side = src/Common/d3d9compat.hpp (DX9 layouts);
// Metal side = the MTL enums in the CLT SDK headers. Keeping the mapping here
// means the substrate (mtl_state.mm) and the pass manager (mtlRuntime.mm)
// share one table without either pulling the other's includes.

#include <cstdint>

namespace xray::render::RENDER_NAMESPACE
{
// D3DBLEND → MTLBlendFactor
inline uint32_t MtlMapBlend(int d3dBlend)
{
    switch (d3dBlend)
    {
    case 1: return 0; // ZERO -> Zero
    case 2: return 1; // ONE -> One
    case 3: return 2; // SRCCOLOR -> SourceColor
    case 4: return 3; // INVSRCCOLOR -> OneMinusSourceColor
    case 5: return 4; // SRCALPHA -> SourceAlpha
    case 6: return 5; // INVSRCALPHA -> OneMinusSourceAlpha
    case 7: return 8; // DESTALPHA -> DestinationAlpha
    case 8: return 9; // INVDESTALPHA -> OneMinusDestinationAlpha
    case 9: return 6; // DESTCOLOR -> DestinationColor
    case 10: return 7; // INVDESTCOLOR -> OneMinusDestinationColor
    case 11: return 10; // SRCALPHASAT -> SourceAlphaSaturated
    case 13: return 11; // BLENDFACTOR -> BlendColor (encoder setBlendColor)
    case 14: return 12; // INVBLENDFACTOR -> OneMinusBlendColor
    case 15: return 13; // SOURCEALPHASAT -> BlendAlpha? (fxc alias; rare) -> BlendAlpha
    default: return 0; // ZERO (fail-safe)
    }
}

// D3DBLENDOP → MTLBlendOperation
inline uint32_t MtlMapBlendOp(int d3dOp)
{
    switch (d3dOp)
    {
    case 1: return 0; // ADD -> Add
    case 2: return 1; // SUBTRACT -> Subtract
    case 3: return 2; // REVSUBTRACT -> ReverseSubtract
    case 4: return 3; // MIN -> Min
    case 5: return 4; // MAX -> Max
    default: return 0;
    }
}

// D3DCMPFUNC → MTLCompareFunction
inline uint32_t MtlMapCompare(int d3dFunc)
{
    switch (d3dFunc)
    {
    case 1: return 0; // NEVER -> Never
    case 2: return 1; // LESS -> Less
    case 3: return 2; // EQUAL -> Equal
    case 4: return 3; // LESSEQUAL -> LessEqual
    case 5: return 4; // GREATER -> Greater
    case 6: return 5; // NOTEQUAL -> NotEqual
    case 7: return 6; // GREATEREQUAL -> GreaterEqual
    case 8: return 7; // ALWAYS -> Always
    default: return 3; // LessEqual
    }
}

// D3DSTENCILOP → MTLStencilOperation
inline uint32_t MtlMapStencilOp(int d3dOp)
{
    switch (d3dOp)
    {
    case 1: return 0; // KEEP -> Keep
    case 2: return 1; // ZERO -> Zero
    case 3: return 2; // REPLACE -> Replace
    case 4: return 3; // INCRSAT -> IncrementClamp
    case 5: return 4; // DECRSAT -> DecrementClamp
    case 6: return 5; // INVERT -> Invert
    case 7: return 6; // INCR -> IncrementWrap
    case 8: return 7; // DECR -> DecrementWrap
    default: return 0;
    }
}

// D3DCULL → MTLCullMode given frontFacingWinding == Clockwise (D3D convention).
// D3DCULL_NONE=1, CW=2 (cull CW-wound faces = front), CCW=3 (cull CCW = back).
inline uint32_t MtlMapCull(int d3dCull)
{
    switch (d3dCull)
    {
    case 1: return 0; // NONE -> None
    case 2: return 1; // CW -> Front
    case 3: return 2; // CCW -> Back
    default: return 0;
    }
}

// D3DFILLMODE SOLID=1/WIREFRAME=2 → MTLTriangleFillMode 0/1
inline uint32_t MtlMapFillMode(int d3dFill)
{
    return d3dFill == 2 ? 1 : 0;
}
} // namespace xray::render::RENDER_NAMESPACE
