// stub_notransform_t_menu.vs — DX9 HLSL port (screen-pixel -> clip without
// the half-pixel offset; menu quads).
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

	O.P.x = I.P.x * screen_res.z * 2.0 - 1.0;
	// Pixel y=0 -> clip +1 (D3D/Metal NDC is y-up), as in stub_notransform_t.vs.
	// Without the flip, full-screen passes came out mirrored with reversed
	// winding, and quads into small RTs (bloom/luminance) landed outside them.
	O.P.y = 1.0 - I.P.y * screen_res.w * 2.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Color	= I.Color;

	return O;
}
FXVS;
