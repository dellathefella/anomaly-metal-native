#pragma once

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif // _WIN32_WINNT

#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#endif // _WIN32

#include <stdio.h>

#ifdef _WIN32
#pragma warning(disable:4995)
#include <intrin.h>
#pragma warning(default:4995)
#endif

#define ENGINE_API
#define ECORE_API

#ifdef _EDITOR
#	include "skeletonX.h"
#	include "skeletoncustom.h"
#else // _EDITOR
#include "../xrCore/xrCore.h"
#include "../Layers/xrRender/SkeletonXVertRender.h"
#include "../xrEngine/bone.h"
#define RENDER 1
#include "../xrEngine/Render.h"
#include "../xrEngine/Device.h"
#include "../Layers/xrRender/light.h"
#endif // _EDITOR

#ifndef _WIN32
// SSE intrinsics via sse2neon (xrCore_platform.h already set XR_ARCHITECTURE_*)
#if defined(XR_ARCHITECTURE_ARM) || defined(XR_ARCHITECTURE_ARM64)
#include "sse2neon/sse2neon.h"
#endif
#endif

#include "xrCPU_Pipe.h"
#include "ttapi.h"
