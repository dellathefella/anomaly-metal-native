////////////////////////////////////////////////////////////////////////////
//	Module 		: script_callback_ex_non_void.h
//	Created 	: 06.02.2004
//  Modified 	: 11.01.2005
//	Author		: Sergey Zhemeitsev and Dmitriy Iassenev
//	Description : Script callbacks with return value
//
//	POSIX port: the Windows build generated typed operator() overloads for
//	N=0..8 via token-pasting macros (script_callback_ex_generators.h) that
//	synthesize /* */ comments — MSVC-only preprocessor behavior. Variadic
//	templates cover every arity with identical by-value semantics.
////////////////////////////////////////////////////////////////////////////

#pragma once

template <typename _return_type>
class CScriptCallbackEx : public CScriptCallbackEx_<_return_type>
{
public:
	// alias the dependent base's member type so the body below can name it
	typedef typename CScriptCallbackEx_<_return_type>::return_type return_type;

#define macros_return_operator(x) return return_type(x);
	template <class... _Params>
	IC return_type operator()(_Params... _params) const
	{
		SCRIPT_CALLBACK_EX_BODY
	}
	template <class... _Params>
	IC return_type operator()(_Params... _params)
	{
		SCRIPT_CALLBACK_EX_BODY
	}
#undef macros_return_operator
};
