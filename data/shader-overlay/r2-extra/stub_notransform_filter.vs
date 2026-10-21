// stub_notransform_filter.vs — DX9 HLSL port (SSManager blur passes;
// screen-pixel -> clip, eight float4 UVs).
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)

struct	v_filter
{
	float4 	P			: POSITION;
	float4	Tex0		: TEXCOORD0;
	float4	Tex1		: TEXCOORD1;
	float4	Tex2		: TEXCOORD2;
	float4	Tex3		: TEXCOORD3;
	float4	Tex4		: TEXCOORD4;
	float4	Tex5		: TEXCOORD5;
	float4	Tex6		: TEXCOORD6;
	float4	Tex7		: TEXCOORD7;
};

struct	v2p_filter
{
	float4 	P			: POSITION;
	float4	Tex0		: TEXCOORD0;
	float4	Tex1		: TEXCOORD1;
	float4	Tex2		: TEXCOORD2;
	float4	Tex3		: TEXCOORD3;
	float4	Tex4		: TEXCOORD4;
	float4	Tex5		: TEXCOORD5;
	float4	Tex6		: TEXCOORD6;
	float4	Tex7		: TEXCOORD7;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_filter main ( v_filter I )
{
	v2p_filter O;

	I.P.xy += 0.5;
	O.P.x = I.P.x * screen_res.z * 2.0 - 1.0;
	O.P.y = I.P.y * screen_res.w * 2.0 - 1.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Tex1	= I.Tex1;
	O.Tex2	= I.Tex2;
	O.Tex3	= I.Tex3;
	O.Tex4	= I.Tex4;
	O.Tex5	= I.Tex5;
	O.Tex6	= I.Tex6;
	O.Tex7	= I.Tex7;

	return O;
}
FXVS;
