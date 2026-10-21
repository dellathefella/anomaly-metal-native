// stub_notransform_aa_aa.vs — DX9 HLSL port (screen-pixel -> clip,
// five float2 + two float4 UVs).
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)

struct	v_aa_AA
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;
	float2	Tex1		: TEXCOORD1;
	float2	Tex2		: TEXCOORD2;
	float2	Tex3		: TEXCOORD3;
	float2	Tex4		: TEXCOORD4;
	float4	Tex5		: TEXCOORD5;
	float4	Tex6		: TEXCOORD6;
};

struct	v2p_aa_AA
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;
	float2	Tex1		: TEXCOORD1;
	float2	Tex2		: TEXCOORD2;
	float2	Tex3		: TEXCOORD3;
	float2	Tex4		: TEXCOORD4;
	float4	Tex5		: TEXCOORD5;
	float4	Tex6		: TEXCOORD6;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_aa_AA main ( v_aa_AA I )
{
	v2p_aa_AA O;

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

	return O;
}
FXVS;
