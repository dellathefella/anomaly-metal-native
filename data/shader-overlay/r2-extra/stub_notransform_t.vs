// stub_notransform_t.vs — DX9 HLSL port (screen-pixel -> clip, Y top-down
// like D3D9; the GL overlay flips Y, Metal follows the D3D convention).
// Font/HUD vertices.
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)

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
