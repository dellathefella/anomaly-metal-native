// xr_lua_smoke — verifies the vendored LuaJIT (ARM64 dynasm) builds a working
// VM: interpreter + JIT-compiled hot loop + string library.
#include <stdio.h>

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "luajit.h"
}

static bool g_failed = false;

static int run(lua_State* L, const char* code, long expect)
{
	if (luaL_dostring(L, code) != 0)
	{
		printf("xr_lua_smoke: FAIL [%s]: %s\n", code, lua_tostring(L, -1));
		lua_pop(L, 1);
		g_failed = true;
		return -1;
	}
	const long got = (long)lua_tointeger(L, -1);
	lua_pop(L, 1);
	if (got != expect)
	{
		printf("xr_lua_smoke: FAIL [%s]: got %ld want %ld\n", code, got, expect);
		g_failed = true;
	}
	return 0;
}

int main()
{
	lua_State* L = luaL_newstate();
	if (!L)
	{
		printf("xr_lua_smoke: FAIL luaL_newstate\n");
		return 1;
	}
	luaL_openlibs(L);

	printf("xr_lua_smoke: %s\n", LUAJIT_VERSION);

	// Interpreter
	run(L, "return 6 * 7", 42);

	// Hot loop: traces + JIT compiles this
	run(L,
	    "local s = 0 for i = 1, 200000 do s = s + i * 2 end return s",
	    200000L * 200001L);

	// FFI library sanity
	if (luaL_dostring(L, "local ffi = require('ffi') ffi.cdef[[ int puts(const char*); ]] "
	                     "return 40 + 2") != 0)
	{
		printf("xr_lua_smoke: FAIL ffi: %s\n", lua_tostring(L, -1));
		g_failed = true;
	}
	else
	{
		const long v = (long)lua_tointeger(L, -1);
		lua_pop(L, 1);
		if (v != 42)
		{
			printf("xr_lua_smoke: FAIL ffi value %ld\n", v);
			g_failed = true;
		}
		else
			printf("xr_lua_smoke: ffi ok\n");
	}

	lua_close(L);
	printf("xr_lua_smoke: %s\n", g_failed ? "FAILURES PRESENT" : "ALL CHECKS PASSED");
	return g_failed ? 1 : 0;
}
