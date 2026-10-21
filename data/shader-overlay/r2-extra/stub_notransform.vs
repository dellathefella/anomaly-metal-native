// stub_notransform.vs — DX9 HLSL port of the GL overlay's stub (r2 tree
// port addition). Pre-transformed (clip-space) UI vertices pass through.
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

	O.P 	= I.P;		// pre-transformed vertex, no xform
	O.Tex0	= I.Tex0;
	//	Some shaders that use this stub don't need Color at all
	O.Color	= I.Color;

	return O;
}
FXVS;
