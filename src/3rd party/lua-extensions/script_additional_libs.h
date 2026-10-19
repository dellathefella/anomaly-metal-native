#pragma once

#include "../../build_config_defines.h"

#include "lua.hpp"

#include <cstdlib>
#include <cctype>

#include <cstdint> // p4: DWORD must match the engine (Common/PlatformApple.inl) typedef exactly
typedef uint32_t DWORD;
typedef unsigned char BYTE;

void open_additional_libs(lua_State*);