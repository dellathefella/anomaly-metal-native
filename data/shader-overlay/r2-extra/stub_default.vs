// stub_default.vs — DX9 HLSL fallback vertex shader for the Metal r2 tree.
// The searge-coc r2 corpus ships stub_default.ps only; the engine's
// unknown-l_shader fallback (stub_default) requests the .vs partner too
// (same role as the GL overlay's gl/stub_default.vs). Pass-through:
// transform by m_WVP, forward TEXCOORD0 + COLOR to stub_default.ps.
#include "common.h"

struct	v_TL
{
	float4 	P		: POSITION;
	float2	Tex0	: TEXCOORD0;
	float4	Color	: COLOR;
};

struct	p_TL
{
	float4 	P		: POSITION;
	float2 	Tex0	: TEXCOORD0;
	float4	Color	: COLOR;
};

//////////////////////////////////////////////////////////////////////////////////////////
// Vertex
p_TL main ( v_TL I )
{
	p_TL O;
	O.P     = mul(m_WVP, I.P);
	O.Tex0  = I.Tex0;
	O.Color = I.Color;
	return O;
}
FXVS;
