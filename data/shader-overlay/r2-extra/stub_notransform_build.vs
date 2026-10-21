// stub_notransform_build.vs — DX9 HLSL port (SSManager mip-build passes;
// screen-pixel -> clip, four float2 UVs).
#include "common.h"

float4	screen_res;							// Screen resolution (x-Width,y-Height, zw - 1/resolution)

struct	v_build
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;
	float2	Tex1		: TEXCOORD1;
	float2	Tex2		: TEXCOORD2;
	float2	Tex3		: TEXCOORD3;
};

struct	v2p_build
{
	float4 	P			: POSITION;
	float2	Tex0		: TEXCOORD0;
	float2	Tex1		: TEXCOORD1;
	float2	Tex2		: TEXCOORD2;
	float2	Tex3		: TEXCOORD3;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_build main ( v_build I )
{
	v2p_build O;

	I.P.xy += 0.5;
	O.P.x = I.P.x * screen_res.z * 2.0 - 1.0;
	O.P.y = I.P.y * screen_res.w * 2.0 - 1.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Tex1	= I.Tex1;
	O.Tex2	= I.Tex2;
	O.Tex3	= I.Tex3;

	return O;
}
FXVS;
