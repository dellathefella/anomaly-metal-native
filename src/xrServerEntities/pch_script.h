////////////////////////////////////////////////////////////////////////////
//	Module 		: pch_script.h
//	Created 	: 23.05.2007
//  Modified 	: 10.08.2007
//	Author		: Dmitriy Iassenev
//	Description : precompiled header for lua and luabind users
////////////////////////////////////////////////////////////////////////////

#ifndef PCH_SCRIPT_H
#define PCH_SCRIPT_H

#include "stdafx.h"


//AVO: lua re-org
#include "lua.hpp"
/*extern "C" {
	#include <lua/lua.h>
	#include <lua/lualib.h>
	#include <lua/lauxlib.h>
}*/
//-AVO

#pragma warning(push)
#pragma warning(disable:4995)
#include <luabind/luabind.hpp>
#pragma warning(pop)

#include <luabind/object.hpp>
#include <luabind/functor.hpp>
#include <luabind/operator.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/return_reference_to_policy.hpp>
#include <luabind/out_value_policy.hpp>
#include <luabind/iterator_policy.hpp>

// luabind's boost.pp iteration helpers leak the N macro (MSVC's PCH hid leaked
// macros from .cpp translation units; clang's -include PCH does not). xrGame/
// xrServerEntities code uses N as a local variable name.
#ifdef N
#undef N
#endif

#endif // PCH_SCRIPT_H
