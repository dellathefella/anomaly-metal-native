#pragma once
// p4 GL-renderer port shim.
//
// The staged OpenXRay renderer hosts a small Lua VM for the ".s" shader
// scripts (blender definitions) inside CResourceManager. OpenXRay gets that
// VM from its xrScriptEngine module; the monolith has no renderer-side script
// engine, so this facade implements exactly the narrow surface the staged
// sources use: init(exporter, loadGlobal), GlobalNamespace,
// load_file_into_namespace(), object(ns,id,type), name_space(ns), unload().
// Semantics follow dev's script_space: each namespace is an environment table
// whose __index falls back to globals, and chunks execute with that env so
// top-level definitions land in the namespace table.

#include <lua.hpp>
#include <luabind/luabind.hpp>

#include "xrCore/xr_locks.h"

// p4: threading spellings the staged renderer expects from dev's xrCore.
using Lock = xrCriticalSection;

class ScopeLock
{
	Lock* syncObject;

public:
	explicit ScopeLock(Lock* SyncObject) : syncObject(SyncObject)
	{
		syncObject->Enter();
	}
	~ScopeLock()
	{
		syncObject->Leave();
	}
};

class CScriptEngine
{
	lua_State* L;

public:
	static constexpr pcstr GlobalNamespace = "xrDefault";

	CScriptEngine() : L(nullptr) {}
	~CScriptEngine()
	{
		unload();
	}
	CScriptEngine(CScriptEngine const&) = delete;
	CScriptEngine& operator=(CScriptEngine const&) = delete;

	template <class Exporter>
	void init(Exporter exporter, bool /*loadGlobalNamespace*/)
	{
		unload();
		L = luaL_newstate();
		luaL_openlibs(L);
		luabind::open(L);
		exporter(L);
	}

	void unload()
	{
		if (L)
			lua_close(L);
		L = nullptr;
	}

	void load_file_into_namespace(pcstr file, pcstr ns)
	{
		if (!L)
			return;
		push_namespace(ns); // -1: namespace env table
		if (luaL_loadfile(L, file) != 0)
		{
			Msg("! ScriptEngine: cannot load '%s': %s", file, lua_tostring(L, -1));
			lua_pop(L, 2);
			return;
		}
		lua_pushvalue(L, -2);
		lua_setfenv(L, -2);
		if (lua_pcall(L, 0, 0, 0) != 0)
		{
			Msg("! ScriptEngine: error running '%s': %s", file, lua_tostring(L, -1));
			lua_pop(L, 1);
		}
		lua_pop(L, 1); // namespace table
	}

	bool object(pcstr ns, pcstr identifier, int expected_type)
	{
		if (!L)
			return false;
		push_namespace(ns);
		lua_getfield(L, -1, identifier);
		const bool ok = lua_type(L, -1) == expected_type;
		lua_pop(L, 2);
		return ok;
	}

	luabind::object name_space(pcstr ns)
	{
		R_ASSERT(L);
		push_namespace(ns);
		luabind::object result(luabind::from_stack, L, -1);
		lua_pop(L, 1);
		return result;
	}

private:
	// Leaves the per-namespace environment table (with {__index = _G}) on the stack.
	void push_namespace(pcstr ns)
	{
		lua_getfield(L, LUA_GLOBALSINDEX, "xr_script_namespaces");
		if (lua_isnil(L, -1))
		{
			lua_pop(L, 1);
			lua_newtable(L);
			lua_pushvalue(L, -1);
			lua_setfield(L, LUA_GLOBALSINDEX, "xr_script_namespaces");
		}
		lua_getfield(L, -1, ns);
		if (lua_isnil(L, -1))
		{
			lua_pop(L, 1); // nil
			lua_newtable(L); // env
			lua_newtable(L); // metatable
			lua_pushvalue(L, LUA_GLOBALSINDEX);
			lua_setfield(L, -2, "__index");
			lua_setmetatable(L, -2);
			lua_pushvalue(L, -1);
			lua_setfield(L, -3, ns); // namespaces[ns] = env
		}
		lua_remove(L, -2); // keep only the env table
	}
};
