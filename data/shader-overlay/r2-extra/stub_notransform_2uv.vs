// stub_notransform_2uv.vs — DX9 HLSL port (pass-through, two UV sets).
#include "common.h"

struct	v_TL2uv
{
	float4 	P		: POSITION;
	float2	Tex0	: TEXCOORD0;
	float2	Tex1	: TEXCOORD1;
	float4	Color	: COLOR;
};

struct	v2p_TL2uv
{
	float4 	P		: POSITION;
	float2	Tex0	: TEXCOORD0;
	float2	Tex1	: TEXCOORD1;
	float4	Color	: COLOR;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
v2p_TL2uv main ( v_TL2uv I )
{
	v2p_TL2uv O;

	O.P 	= I.P;
	O.Tex0	= I.Tex0;
	O.Tex1	= I.Tex1;
	//	Some shaders that use this stub don't need Color at all
	O.Color	= I.Color;

	return O;
}
FXVS;
