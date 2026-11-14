// stub_notransform_t.vs — DX9 HLSL port (screen-pixel -> clip, Y top-down
// like D3D9; the GL overlay flips Y, Metal follows the D3D convention).
// Font/HUD vertices.
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)
// Set per draw by the Metal backend from the bound vertex declaration:
// x = 1 when the position is untransformed (D3DFVF_XYZ / POSITION), 0 when it
// is pre-transformed screen pixels (D3DFVF_XYZRHW / POSITIONT). DX9's fixed-
// function pipeline made exactly this distinction; treating world-space
// vertices (rain, flares, lightning, tracers, moon) as pixels hid them all.
float4	xr_ffp_mode;

struct	v_TL
{
	float4 	P		: POSITION;
	float2	Tex0	: TEXCOORD0;
	float4	Color	: COLOR;
};

struct	v2p_TL
{
	float4 	P		: POSITION;
	float2	Tex0	: TEXCOORD0;
	float4	Color	: COLOR;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_TL main ( v_TL I )
{
	v2p_TL O;

	if (xr_ffp_mode.x > 0.5)
	{
		O.P     = mul(m_WVP, float4(I.P.xyz, 1.0));
		O.Tex0  = I.Tex0;
		O.Color = I.Color;
		return O;
	}

	I.P.xy += 0.5;
	O.P.x = I.P.x * screen_res.z * 2.0 - 1.0;
	// DX9 FFP 2D ortho (OrthoOffCenterLH(0,w,h,0)): pixel y=0 maps to clip
	// +1. Metal's NDC is y-up like D3D, so the same flip is required — both
	// for correct orientation and to restore CW winding for back-face cull.
	O.P.y = 1.0 - I.P.y * screen_res.w * 2.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Color	= I.Color;

	return O;
}
FXVS;
