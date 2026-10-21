// stub_notransform_postpr.vs — DX9 HLSL port (post-processing quads;
// screen-pixel -> clip, dual/noise UVs + color/gray multipliers).
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)

struct	v_postpr
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;			// base1 (duality)
	float2	Tex1		: TEXCOORD1;			// base2 (duality)
	float2	Tex2		: TEXCOORD2;			// base  (noise)
	float4	Color		: COLOR0;				// multiplier, color.w = noise_amount
	float4	Gray		: COLOR1;				// (.3,.3,.3.,amount)
};

struct	v2p_postpr
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;
	float2	Tex1		: TEXCOORD1;
	float2	Tex2		: TEXCOORD2;
	float4	Color		: COLOR0;
	float4	Gray		: COLOR1;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_postpr main ( v_postpr I )
{
	v2p_postpr O;

	I.P.xy += 0.5;
	O.P.x = I.P.x * screen_res.z * 2.0 - 1.0;
	O.P.y = I.P.y * screen_res.w * 2.0 - 1.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Tex1	= I.Tex1;
	O.Tex2	= I.Tex2;

	O.Color	= I.Color;
	O.Gray	= I.Gray;

	return O;
}
FXVS;
