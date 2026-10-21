// stub_notransform_t_ma.vs — DX9 HLSL port (fixed 1024x768 mapping, alpha
// splat colour; "material accumulate" sprite path).
#include "common.h"

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

	O.P.x = I.P.x / 1024.0 * 2.0 - 1.0;
	O.P.y = I.P.y / 768.0 * 2.0 - 1.0;
	O.P.zw = I.P.zw;

	O.Tex0	= I.Tex0;
	O.Color	= I.Color.aaaa;	//	swizzle vertex colour

	return O;
}
FXVS;
