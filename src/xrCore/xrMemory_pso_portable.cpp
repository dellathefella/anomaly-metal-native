// xrMemory_pso_portable.cpp — portable replacements for the x86 asm
// (MMX/x86) memcpy/memfill implementations used on Windows.
//
// The engine picks between xrMemCopy_x86 / xrMemCopy_MMX etc. at runtime;
// on ARM64 all variants resolve to the libc implementations.

#include "stdafx.h"

#ifndef XR_PLATFORM_WINDOWS

void __stdcall xrMemCopy_x86(void* dest, const void* src, u32 n)
{
	memcpy(dest, src, n);
}

void __stdcall xrMemCopy_MMX(void* dest, const void* src, u32 n)
{
	memcpy(dest, src, n);
}

void __stdcall xrMemFill_x86(void* dest, int value, u32 n)
{
	memset(dest, value, n);
}

void __stdcall xrMemFill32_MMX(void* dest, u32 value, u32 count)
{
	// count is in DWORDs (matches the x86 implementations)
	u32* d = (u32*)dest;
	for (u32 i = 0; i < count; ++i)
		d[i] = value;
}

void __stdcall xrMemFill32_x86(void* dest, u32 value, u32 count)
{
	xrMemFill32_MMX(dest, value, count);
}

#endif // !XR_PLATFORM_WINDOWS
