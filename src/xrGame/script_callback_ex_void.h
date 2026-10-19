////////////////////////////////////////////////////////////////////////////
//	Module 		: script_callback_ex_void.h
//	Created 	: 06.02.2004
//  Modified 	: 11.01.2005
//	Author		: Sergey Zhemeitsev and Dmitriy Iassenev
//	Description : Script callbacks with return value but specialized with void
//
//	POSIX port: variadic-template rewrite, see script_callback_ex_nonvoid.h.
////////////////////////////////////////////////////////////////////////////

#pragma once

template <>
class CScriptCallbackEx<void> : public CScriptCallbackEx_<void>
{
public:
#define macros_return_operator(x) (x);
	template <class... _Params>
	IC void operator()(_Params... _params) const
	{
		SCRIPT_CALLBACK_EX_BODY
	}
	template <class... _Params>
	IC void operator()(_Params... _params)
	{
		SCRIPT_CALLBACK_EX_BODY
	}
#undef macros_return_operator
};
