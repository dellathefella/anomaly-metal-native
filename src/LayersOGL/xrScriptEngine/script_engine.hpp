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

#include <map>
#include <string>

// p4: Lock/ScopeLock come from the monolith's xrCore (identical to dev's
// xrCore/Threading extraction; implemented in xrCore.dylib).
#include "xrCore/ScopeLock.hpp"

class CScriptEngine
{
	lua_State* L;
	std::map<std::string, luabind::object> m_namespaces;

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
		m_namespaces.clear();
		if (L)
			lua_close(L);
		L = nullptr;
	}

	void load_file_into_namespace(pcstr file, pcstr ns)
	{
		if (!L)
			return;
		luabind::object env = name_space(ns);
		if (luaL_loadfile(L, file) != 0)
		{
			Msg("! ScriptEngine: cannot load '%s': %s", file, lua_tostring(L, -1));
			lua_pop(L, 1);
			return;
		}
		env.pushvalue(L);
		lua_setfenv(L, -2);
		if (lua_pcall(L, 0, 0, 0) != 0)
		{
			Msg("! ScriptEngine: error running '%s': %s", file, lua_tostring(L, -1));
			lua_pop(L, 1);
		}
	}

	bool object(pcstr ns, pcstr identifier, int expected_type)
	{
		if (!L)
			return false;
		luabind::object env = name_space(ns);
		env.pushvalue(L);
		lua_getfield(L, -1, identifier);
		const bool ok = lua_type(L, -1) == expected_type;
		lua_pop(L, 2);
		return ok;
	}

	luabind::object name_space(pcstr ns)
	{
		R_ASSERT(L);
		const auto found = m_namespaces.find(ns);
		if (found != m_namespaces.end())
			return found->second;

		luabind::object env = luabind::newtable(L);
		luabind::object globals = luabind::get_globals(L);
		// __index fallback to globals (raw API: this luabind fork predates
		// setmetatable helpers).
		env.pushvalue(L);
		lua_newtable(L); // metatable
		globals.pushvalue(L);
		lua_setfield(L, -2, "__index");
		lua_setmetatable(L, -2);
		lua_pop(L, 1); // env copy; the object keeps its own registry reference

		m_namespaces.emplace(ns, env);
		return env;
	}
};
