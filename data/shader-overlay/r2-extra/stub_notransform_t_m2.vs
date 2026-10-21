// stub_notransform_t_m2.vs — DX9 HLSL port (screen-pixel -> clip,
// bgr*2 mask colour swizzle).
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
	O.P.y = I.P.y * screen_res.w * 2.0 - 1.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Color	= float4(I.Color.bgr * 2.0, 1.0);	//	swizzle vertex colour

	return O;
}
FXVS;
