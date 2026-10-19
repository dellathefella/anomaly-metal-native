// d3d9.h — POSIX (macOS) shim. Engine-core sources include <d3d9.h> only for
// types/constants (d3d9types.h) plus a handful of D3DX math/FVF helpers,
// implemented below. No D3D runtime exists on macOS; the renderer is GL/Metal.

#ifndef XR_POSIX_D3D9_H
#define XR_POSIX_D3D9_H

#include "d3d9types.h"

#ifdef __cplusplus

// ---------------------------------------------------------------------------
// Minimal D3DX helper reimplementations (byte-identical semantics to d3dx9)
// ---------------------------------------------------------------------------
typedef float D3DXMATRIX[16]; // layout-compatible with xr Fmatrix

inline unsigned int D3DXGetFVFVertexSize(unsigned int FVF)
{
    unsigned int v = 0;

    switch (FVF & D3DFVF_POSITION_MASK)
    {
    case D3DFVF_XYZ: v += 12; break;
    case D3DFVF_XYZRHW: v += 16; break;
    case D3DFVF_XYZB1: v += 16; break;
    case D3DFVF_XYZB2: v += 20; break;
    case D3DFVF_XYZB3: v += 24; break;
    case D3DFVF_XYZB4: v += 28; break;
    case D3DFVF_XYZB5: v += 32; break;
    case D3DFVF_XYZW: v += 16; break;
    }
    if (FVF & D3DFVF_PSIZE) v += 4;
    if (FVF & D3DFVF_NORMAL) v += 12;
    if (FVF & D3DFVF_DIFFUSE) v += 4;
    if (FVF & D3DFVF_SPECULAR) v += 4;

    unsigned int texcount = (FVF & D3DFVF_TEXCOUNT_MASK) >> D3DFVF_TEXCOUNT_SHIFT;
    for (unsigned int i = 0; i < texcount; ++i)
    {
        unsigned int fmt = (FVF >> (i * 2 + 16)) & 3;
        switch (fmt)
        {
        case D3DFVF_TEXTUREFORMAT2: v += 8; break; // 2 floats
        case D3DFVF_TEXTUREFORMAT1: v += 4; break; // 1 float
        case D3DFVF_TEXTUREFORMAT3: v += 12; break; // 3 floats
        case D3DFVF_TEXTUREFORMAT4: v += 16; break; // 4 floats
        }
    }
    return v;
}

inline void D3DXDeclaratorFromFVF(unsigned int FVF, D3DVERTEXELEMENT9* pDeclarator)
{
    unsigned int offset = 0;
    D3DVERTEXELEMENT9* e = pDeclarator;

#define XR_DECL(type, usage, index, size)                                                                 \
    do                                                                                                    \
    {                                                                                                     \
        e->Stream = 0;                                                                                    \
        e->Offset = (uint16_t)offset;                                                                     \
        e->Type = (uint8_t)(type);                                                                        \
        e->Method = D3DDECLMETHOD_DEFAULT;                                                                \
        e->Usage = (uint8_t)(usage);                                                                      \
        e->UsageIndex = (uint8_t)(index);                                                                 \
        offset += (size);                                                                                 \
        ++e;                                                                                              \
    } while (0)

    switch (FVF & D3DFVF_POSITION_MASK)
    {
    case D3DFVF_XYZ: XR_DECL(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_POSITION, 0, 12); break;
    case D3DFVF_XYZRHW: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITIONT, 0, 16); break;
    case D3DFVF_XYZB1: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 0, 16); break;
    case D3DFVF_XYZB2: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 0, 16);
        XR_DECL(D3DDECLTYPE_FLOAT1, D3DDECLUSAGE_POSITION, 1, 4); break;
    case D3DFVF_XYZB3: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 0, 16);
        XR_DECL(D3DDECLTYPE_FLOAT2, D3DDECLUSAGE_POSITION, 1, 8); break;
    case D3DFVF_XYZB4: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 0, 16);
        XR_DECL(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_POSITION, 1, 12); break;
    case D3DFVF_XYZB5: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 0, 16);
        XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITION, 1, 16); break;
    case D3DFVF_XYZW: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_POSITIONT, 0, 16); break;
    }
    if (FVF & D3DFVF_PSIZE) XR_DECL(D3DDECLTYPE_FLOAT1, D3DDECLUSAGE_PSIZE, 0, 4);
    if (FVF & D3DFVF_NORMAL) XR_DECL(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_NORMAL, 0, 12);
    if (FVF & D3DFVF_DIFFUSE) XR_DECL(D3DDECLTYPE_D3DCOLOR, D3DDECLUSAGE_COLOR, 0, 4);
    if (FVF & D3DFVF_SPECULAR) XR_DECL(D3DDECLTYPE_D3DCOLOR, D3DDECLUSAGE_COLOR, 1, 4);

    unsigned int texcount = (FVF & D3DFVF_TEXCOUNT_MASK) >> D3DFVF_TEXCOUNT_SHIFT;
    for (unsigned int i = 0; i < texcount; ++i)
    {
        unsigned int fmt = (FVF >> (i * 2 + 16)) & 3;
        switch (fmt)
        {
        case D3DFVF_TEXTUREFORMAT2: XR_DECL(D3DDECLTYPE_FLOAT2, D3DDECLUSAGE_TEXCOORD, i, 8); break;
        case D3DFVF_TEXTUREFORMAT1: XR_DECL(D3DDECLTYPE_FLOAT1, D3DDECLUSAGE_TEXCOORD, i, 4); break;
        case D3DFVF_TEXTUREFORMAT3: XR_DECL(D3DDECLTYPE_FLOAT3, D3DDECLUSAGE_TEXCOORD, i, 12); break;
        case D3DFVF_TEXTUREFORMAT4: XR_DECL(D3DDECLTYPE_FLOAT4, D3DDECLUSAGE_TEXCOORD, i, 16); break;
        }
    }
#undef XR_DECL

    // terminator
    e->Stream = 0xff;
    e->Offset = 0;
    e->Type = D3DDECLTYPE_UNUSED;
    e->Method = 0;
    e->Usage = 0;
    e->UsageIndex = 0;
}

inline unsigned int D3DXGetDeclLength(const D3DVERTEXELEMENT9* decl)
{
    unsigned int n = 0;
    while (decl[n].Type != D3DDECLTYPE_UNUSED)
        ++n;
    return n;
}

inline unsigned int D3DXGetDeclVertexSize(const D3DVERTEXELEMENT9* decl, unsigned int Stream)
{
    static const unsigned int typesz[] = {4, 8, 12, 16, 4, 4, 4, 8, 4, 4, 8, 4, 8, 4, 4, 4, 8};
    unsigned int v = 0;
    for (const D3DVERTEXELEMENT9* e = decl; e->Type != D3DDECLTYPE_UNUSED; ++e)
        if (e->Stream == Stream)
            v += typesz[e->Type];
    return v;
}

// (padded 4x4 inverse, row-major float[16] — same memory layout as xr Fmatrix)
inline D3DXMATRIX* D3DXMatrixInverse(D3DXMATRIX* pOut, float* pDeterminant, const D3DXMATRIX* pM)
{
    // cofactor inverse of a 4x4; generic (not affine-specific) for safety
    float inv[16], det;
    const float* m = (const float*)pM;
    float* out = (float*)pOut;

    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] +
             m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] -
             m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] +
             m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] -
              m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] -
             m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] +
             m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] -
             m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] +
              m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] +
             m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] -
             m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] +
              m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] -
              m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] -
             m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] +
             m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] -
              m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] +
              m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (pDeterminant)
        *pDeterminant = det;
    if (det == 0)
        return pOut; // D3DX returns zero matrix on singular input
    det = 1.0f / det;
    for (int i = 0; i < 16; ++i)
        out[i] = inv[i] * det;
    return pOut;
}

#endif // __cplusplus

#endif // XR_POSIX_D3D9_H
