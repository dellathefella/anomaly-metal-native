// xr_3da entry point for POSIX (macOS) — replaces Win32 WinMain.
//
// Converts argv into the single command-line string the WinMain-style engine
// expects (xrCore stores it via xr_set_command_line; Core.Params picks it up
// in Core._initialize) and calls WinMain_impl directly — skipping the Win32
// DllMain fan-out and SEH stack-overflow wrapper from x_ray.cpp.

#include "stdafx.h"

extern int APIENTRY WinMain_impl(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                                 char* lpCmdLine, int nCmdShow);

int main(int argc, char** argv)
{
	xr_set_command_line(argc - 1, argv + 1);
	return WinMain_impl(NULL, NULL, (char*)xr_GetCommandLine(), SW_SHOWNORMAL);
}
