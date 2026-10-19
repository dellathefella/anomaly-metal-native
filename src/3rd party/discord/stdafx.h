// Minimal PCH for the bundled discord-game-sdk C++ wrapper. Anomaly's MSVC
// build compiles these sources with a shared precompiled header; standalone
// (CMake) builds need this stub.
#pragma once

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
