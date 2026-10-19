// d3d9types.h — POSIX (macOS) shim for the fixed-D3D9 *type/constant* subset
// that the engine-core modules (xrEngine, xrPhysics, xrGame, xrParticles,
// xrServerEntities) reference without a D3D runtime. Renderer layers are not
// built against this shim: on macOS the renderer is OpenXRay's GL port (p4)
// and later native Metal (p5).
//
// Values match the canonical d3d9types.h ABI so shared sources behave
// identically on Windows.

#ifndef XR_POSIX_D3D9TYPES_H
#define XR_POSIX_D3D9TYPES_H

#include <stdint.h>

typedef uint32_t D3DCOLOR;
typedef uint32_t DWORD_D3D;
typedef uint32_t D3DFVF;

#define D3DCOLOR_ARGB(a, r, g, b)                                                                        \
    ((D3DCOLOR)((((a) & 0xffu) << 24) | (((r) & 0xffu) << 16) | (((g) & 0xffu) << 8) | ((b) & 0xffu)))
#define D3DCOLOR_RGBA(r, g, b, a) D3DCOLOR_ARGB(a, r, g, b)
#define D3DCOLOR_XRGB(r, g, b) D3DCOLOR_ARGB(0xff, r, g, b)

// ---------------------------------------------------------------------------
// FVF flags
// ---------------------------------------------------------------------------
#define D3DFVF_DXT (1 << 17)
#define D3DFVF_PSIZE (1 << 25)
#define D3DFVF_DIFFUSE (1 << 1)
#define D3DFVF_SPECULAR (1 << 2)
#define D3DFVF_NORMAL (1 << 4)
#define D3DFVF_VERTEX (D3DFVF_XYZ | D3DFVF_NORMAL | D3DFVF_TEX1)

#define D3DFVF_XYZ (2 << 12)
#define D3DFVF_XYZRHW (3 << 12)
#define D3DFVF_XYZB1 (4 << 12)
#define D3DFVF_XYZB2 (5 << 12)
#define D3DFVF_XYZB3 (6 << 12)
#define D3DFVF_XYZB4 (7 << 12)
#define D3DFVF_XYZB5 (8 << 12)
#define D3DFVF_XYZW (9 << 12)
#define D3DFVF_LASTB_MASK (3 << 12)
#define D3DFVF_LASTB_SHIFT (12)
#define D3DFVF_POSITION_MASK ((13 << 12) | (1 << 11))

#define D3DFVF_TEXCOUNT_MASK 0x0000F000
#define D3DFVF_TEXCOUNT_SHIFT 12
#define D3DFVF_TEXTUREFORMAT2 0
#define D3DFVF_TEXTUREFORMAT1 3
#define D3DFVF_TEXTUREFORMAT3 1
#define D3DFVF_TEXTUREFORMAT4 2
#define D3DFVF_TEXCOORDSIZE3(CoordIndex) (D3DFVF_TEXTUREFORMAT3 << (CoordIndex * 2 + 16))
#define D3DFVF_TEXCOORDSIZE2(CoordIndex) (D3DFVF_TEXTUREFORMAT2 << (CoordIndex * 2 + 16))
#define D3DFVF_TEXCOORDSIZE4(CoordIndex) (D3DFVF_TEXTUREFORMAT4 << (CoordIndex * 2 + 16))
#define D3DFVF_TEXCOORDSIZE1(CoordIndex) (D3DFVF_TEXTUREFORMAT1 << (CoordIndex * 2 + 16))
#define D3DFVF_TEX1 (1 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX2 (2 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX3 (3 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX4 (4 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX5 (5 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX6 (6 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX7 (7 << D3DFVF_TEXCOUNT_SHIFT)
#define D3DFVF_TEX8 (8 << D3DFVF_TEXCOUNT_SHIFT)

// ---------------------------------------------------------------------------
// Primitives / render states / sampler states
// ---------------------------------------------------------------------------
typedef enum _D3DPRIMITIVETYPE
{
    D3DPT_POINTLIST = 1,
    D3DPT_LINELIST = 2,
    D3DPT_LINESTRIP = 3,
    D3DPT_TRIANGLELIST = 4,
    D3DPT_TRIANGLESTRIP = 5,
    D3DPT_TRIANGLEFAN = 6,
    D3DPT_FORCE_DWORD = 0x7fffffff
} D3DPRIMITIVETYPE;

typedef enum _D3DSHADEMODE
{
    D3DSHADE_FLAT = 1,
    D3DSHADE_GOURAUD = 2,
    D3DSHADE_PHONG = 3,
    D3DSHADE_FORCE_DWORD = 0x7fffffff
} D3DSHADEMODE;

typedef enum _D3DFILLMODE
{
    D3DFILL_POINT = 1,
    D3DFILL_WIREFRAME = 2,
    D3DFILL_SOLID = 3,
    D3DFILL_FORCE_DWORD = 0x7fffffff
} D3DFILLMODE;

typedef enum _D3DCULL
{
    D3DCULL_NONE = 1,
    D3DCULL_CW = 2,
    D3DCULL_CCW = 3,
    D3DCULL_FORCE_DWORD = 0x7fffffff
} D3DCULL;

typedef enum _D3DCMPFUNC
{
    D3DCMP_NEVER = 1,
    D3DCMP_LESS = 2,
    D3DCMP_EQUAL = 3,
    D3DCMP_LESSEQUAL = 4,
    D3DCMP_GREATER = 5,
    D3DCMP_NOTEQUAL = 6,
    D3DCMP_GREATEREQUAL = 7,
    D3DCMP_ALWAYS = 8,
    D3DCMP_FORCE_DWORD = 0x7fffffff
} D3DCMPFUNC;

typedef enum _D3DFOGMODE
{
    D3DFOG_NONE = 0,
    D3DFOG_EXP = 1,
    D3DFOG_EXP2 = 2,
    D3DFOG_LINEAR = 3,
    D3DFOG_FORCE_DWORD = 0x7fffffff
} D3DFOGMODE;

typedef enum _D3DTEXTUREFILTERTYPE
{
    D3DTEXF_NONE = 0,
    D3DTEXF_POINT = 1,
    D3DTEXF_LINEAR = 2,
    D3DTEXF_ANISOTROPIC = 3,
    D3DTEXF_PYRAMIDALQUAD = 6,
    D3DTEXF_GAUSSIANQUAD = 7,
    D3DTEXF_FORCE_DWORD = 0x7fffffff
} D3DTEXTUREFILTERTYPE;

typedef enum _D3DBLEND
{
    D3DBLEND_ZERO = 1,
    D3DBLEND_ONE = 2,
    D3DBLEND_SRCCOLOR = 3,
    D3DBLEND_INVSRCCOLOR = 4,
    D3DBLEND_SRCALPHA = 5,
    D3DBLEND_INVSRCALPHA = 6,
    D3DBLEND_DESTALPHA = 7,
    D3DBLEND_INVDESTALPHA = 8,
    D3DBLEND_DESTCOLOR = 9,
    D3DBLEND_INVDESTCOLOR = 10,
    D3DBLEND_SRCALPHASAT = 11,
    D3DBLEND_BOTHSRCALPHA = 12,
    D3DBLEND_BOTHINVSRCALPHA = 13,
    D3DBLEND_FORCE_DWORD = 0x7fffffff
} D3DBLEND;

typedef enum _D3DRENDERSTATETYPE
{
    D3DRS_ZENABLE = 7,
    D3DRS_FILLMODE = 8,
    D3DRS_SHADEMODE = 9,
    D3DRS_ZWRITEENABLE = 14,
    D3DRS_ALPHATESTENABLE = 15,
    D3DRS_LASTPIXEL = 16,
    D3DRS_SRCBLEND = 19,
    D3DRS_DESTBLEND = 20,
    D3DRS_CULLMODE = 22,
    D3DRS_ZFUNC = 23,
    D3DRS_ALPHAREF = 24,
    D3DRS_ALPHAFUNC = 25,
    D3DRS_DITHERENABLE = 26,
    D3DRS_ALPHABLENDENABLE = 27,
    D3DRS_FOGENABLE = 28,
    D3DRS_SPECULENABLE = 29,
    D3DRS_COLORVERTEX = 43,
    D3DRS_FOGCOLOR = 34,
    D3DRS_FOGVERTEXMODE = 37,
    D3DRS_FOGTABLEMODE = 38,
    D3DRS_FOGSTART = 39,
    D3DRS_FOGEND = 40,
    D3DRS_RANGEFOGENABLE = 48,
    D3DRS_AMBIENT = 137,
    D3DRS_FOGVERTEX_COLOR = 138,
    D3DRS_MULTISAMPLEANTIALIAS = 175,
    D3DRS_MULTISAMPLEMASK = 176,
    D3DRS_AMBIENTMATERIALSOURCE = 162,
    D3DRS_DIFFUSEMATERIALSOURCE = 163,
    D3DRS_SPECULARMATERIALSOURCE = 164,
    D3DRS_EMISSIVEMATERIALSOURCE = 166,
    D3DRS_NORMALIZENORMALS = 53,
    D3DRS_SRGBWRITEENABLE = 140,
    D3DRS_FORCE_DWORD = 0x7fffffff
} D3DRENDERSTATETYPE;

#define D3DRS_LOCALVIEWER 44

typedef enum _D3DSAMPLERSTATETYPE
{
    D3DSAMP_ADDRESSU = 1,
    D3DSAMP_ADDRESSV = 2,
    D3DSAMP_ADDRESSW = 3,
    D3DSAMP_BORDERCOLOR = 4,
    D3DSAMP_MAGFILTER = 5,
    D3DSAMP_MINFILTER = 6,
    D3DSAMP_MIPFILTER = 7,
    D3DSAMP_MIPMAPLODBIAS = 8,
    D3DSAMP_MAXMIPLEVEL = 9,
    D3DSAMP_MAXANISOTROPY = 10,
    D3DSAMP_SRGBTEXTURE = 11,
    D3DSAMP_ELEMENTINDEX = 12,
    D3DSAMP_DMAPOFFSET = 13,
    D3DSAMP_FORCE_DWORD = 0x7fffffff
} D3DSAMPLERSTATETYPE;

// material color sources
#define D3DMCS_MATERIAL 0
#define D3DMCS_COLOR1 1
#define D3DMCS_COLOR2 2

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------
typedef struct _D3DMATERIAL9
{
    float Diffuse[4];
    float Ambient[4];
    float Specular[4];
    float Emissive[4];
    float Power;
} D3DMATERIAL9;

typedef enum _D3DLIGHTTYPE
{
    D3DLIGHT_POINT = 1,
    D3DLIGHT_SPOT = 2,
    D3DLIGHT_DIRECTIONAL = 3,
    D3DLIGHT_FORCE_DWORD = 0x7fffffff
} D3DLIGHTTYPE;

typedef struct _D3DLIGHT9
{
    D3DLIGHTTYPE Type;
    float Diffuse[4];
    float Specular[4];
    float Ambient[4];
    float Position[3];
    float Direction[3];
    float Range;
    float Falloff;
    float Attenuation0;
    float Attenuation1;
    float Attenuation2;
    float Theta;
    float Phi;
} D3DLIGHT9;

typedef enum _D3DDECLTYPE
{
    D3DDECLTYPE_FLOAT1 = 0,
    D3DDECLTYPE_FLOAT2 = 1,
    D3DDECLTYPE_FLOAT3 = 2,
    D3DDECLTYPE_FLOAT4 = 3,
    D3DDECLTYPE_D3DCOLOR = 4,
    D3DDECLTYPE_UBYTE4 = 5,
    D3DDECLTYPE_SHORT2 = 6,
    D3DDECLTYPE_SHORT4 = 7,
    D3DDECLTYPE_UBYTE4N = 8,
    D3DDECLTYPE_SHORT2N = 9,
    D3DDECLTYPE_SHORT4N = 10,
    D3DDECLTYPE_USHORT2N = 11,
    D3DDECLTYPE_USHORT4N = 12,
    D3DDECLTYPE_UDEC3 = 13,
    D3DDECLTYPE_DEC3N = 14,
    D3DDECLTYPE_FLOAT16_2 = 15,
    D3DDECLTYPE_FLOAT16_4 = 16,
    D3DDECLTYPE_UNUSED = 17,
    D3DDECLTYPE_FORCE_DWORD = 0x7fffffff
} D3DDECLTYPE;

typedef enum _D3DDECLMETHOD
{
    D3DDECLMETHOD_DEFAULT = 0,
    D3DDECLMETHOD_PROCESS = 1,
    D3DDECLMETHOD_COPY = 2,
    D3DDECLMETHOD_SRGBDECODE = 3,
    D3DDECLMETHOD_SRGBENCODE = 4,
    D3DDECLMETHOD_UQUAL = 5,
    D3DDECLMETHOD_VQUAL = 6,
    D3DDECLMETHOD_UNKNOWNQUAL = 7,
    D3DDECLMETHOD_FORCE_DWORD = 0x7fffffff
} D3DDECLMETHOD;

typedef enum _D3DDECLUSAGE
{
    D3DDECLUSAGE_POSITION = 0,
    D3DDECLUSAGE_BLENDWEIGHT = 1,
    D3DDECLUSAGE_BLENDINDICES = 2,
    D3DDECLUSAGE_NORMAL = 3,
    D3DDECLUSAGE_PSIZE = 4,
    D3DDECLUSAGE_TEXCOORD = 5,
    D3DDECLUSAGE_TANGENT = 6,
    D3DDECLUSAGE_BINORMAL = 7,
    D3DDECLUSAGE_TESSFACTOR = 8,
    D3DDECLUSAGE_POSITIONT = 9,
    D3DDECLUSAGE_COLOR = 10,
    D3DDECLUSAGE_FOG = 11,
    D3DDECLUSAGE_DEPTH = 12,
    D3DDECLUSAGE_SAMPLE = 13,
    D3DDECLUSAGE_FORCE_DWORD = 0x7fffffff
} D3DDECLUSAGE;

#define MAXD3DDECLTYPE 17
#define MAXD3DDECLMETHOD 5
#define MAXD3DDECLUSAGE 14
#define MAXD3DDECLUSAGEINDEX 10
#define MAXD3DDECLLENGTH 64
#define MAXD3DDECLSTRIDE 1024

typedef struct _D3DVERTEXELEMENT9
{
    uint16_t Stream;
    uint16_t Offset;
    uint8_t Type;
    uint8_t Method;
    uint8_t Usage;
    uint8_t UsageIndex;
} D3DVERTEXELEMENT9;

#endif // XR_POSIX_D3D9TYPES_H
