// xrCore.cpp : Defines the entry point for the DLL application.
//
#include "stdafx.h"
#pragma hdrstop

#ifdef XR_PLATFORM_WINDOWS
#include <mmsystem.h>
#include <objbase.h>
#else
#include <mach-o/dyld.h>
#include <unistd.h>
#include <limits.h>
#endif
#include "xrCore.h"

#ifdef XR_PLATFORM_WINDOWS
#pragma comment(lib,"winmm.lib")
#endif

#ifdef DEBUG
# ifdef XR_PLATFORM_WINDOWS
#  include <malloc.h>
# else
#  include <malloc/malloc.h>
# endif
#endif // DEBUG

#include<fstream>
#include <iostream>
#include <string>

XRCORE_API xrCore Core;
extern XRCORE_API u32 build_id;
extern XRCORE_API LPCSTR build_date;

#ifndef XR_PLATFORM_WINDOWS
// On Windows these live in xrEngine (x_ray.cpp) and are computed before
// Core._initialize. The base library carries its own copy on POSIX so xrCore
// is self-contained; the xrEngine port reuses these exported symbols.
XRCORE_API LPCSTR build_date = __DATE__;
XRCORE_API u32 build_id = 0;

namespace
{
struct BuildIdInit
{
	BuildIdInit()
	{
		static const char* month_id[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
		                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
		static const int days_in_month[12] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
		const int start_day = 31, start_month = 1, start_year = 1999;

		char month[16] = { 0 };
		int days = 0, years = 0, months = 0;
		sscanf(__DATE__, "%s %d %d", month, &days, &years);
		for (int i = 0; i < 12; ++i)
			if (0 == _stricmp(month_id[i], month))
			{
				months = i;
				break;
			}

		u32 id = u32((years - start_year) * 365 + days - start_day);
		for (int i = 0; i < months; ++i)
			id += days_in_month[i];
		for (int i = 0; i < start_month - 1; ++i)
			id -= days_in_month[i];
		build_id = id;
	}
};
BuildIdInit g_build_id_init;
}
#endif // !XR_PLATFORM_WINDOWS

namespace CPU
{
	extern void Detect();
};

static u32 init_counter = 0;

//extern char g_application_path[256];

//. extern xr_vector<shared_str>* LogFile;

void xrCore::_initialize(LPCSTR _ApplicationName, LogCallback cb, BOOL init_fs, LPCSTR fs_fname)
{
	xr_strcpy(ApplicationName, _ApplicationName);
	if (0 == init_counter)
	{
#ifdef XRCORE_STATIC
        _clear87();
        _control87(_PC_53, MCW_PC);
        _control87(_RC_CHOP, MCW_RC);
        _control87(_RC_NEAR, MCW_RC);
        _control87(_MCW_EM, MCW_EM);
#endif
		// Init COM so we can use CoCreateInstance
		// HRESULT co_res =
		Params = xr_strdup(GetCommandLine());
		xr_strlwr(Params);
#ifdef XR_PLATFORM_WINDOWS
		if (!strstr(Params, "-editor"))
			CoInitializeEx(NULL, COINIT_MULTITHREADED);
#endif

		string_path fn, dr, di;

		// application path
		GetModuleFileName(GetModuleHandle(MODULE_NAME), fn, sizeof(fn));
		_splitpath(fn, dr, di, 0, 0);
		strconcat(sizeof(ApplicationPath), ApplicationPath, dr, di);

#ifndef _EDITOR
		//        xr_strcpy(g_application_path, sizeof(g_application_path), ApplicationPath);
#endif

#ifdef _EDITOR
        // working path
        if (strstr(Params, "-wf"))
        {
            string_path c_name;
            sscanf(strstr(Core.Params, "-wf ") + 4, "%[^ ] ", c_name);
            SetCurrentDirectory(c_name);
        }
#endif

		GetCurrentDirectory(sizeof(WorkingPath), WorkingPath);

		// User/Comp Name
		DWORD sz_user = sizeof(UserName);
		GetUserName(UserName, &sz_user);

		DWORD sz_comp = sizeof(CompName);
		GetComputerName(CompName, &sz_comp);

		// Mathematics & PSI detection
		CPU::Detect();

		Memory._initialize(strstr(Params, "-mem_debug") ? TRUE : FALSE);

		DUMP_PHASE;

		InitLog();
		_initialize_cpu();

		// Debug._initialize ();

		rtc_initialize();

		time_t _time = time(NULL);
		tm* time = localtime(&_time);
		april1 = time ? (time->tm_mday == 1 && time->tm_mon == 3) : false;

		xr_FS = xr_new<CLocatorAPI>();

		xr_EFS = xr_new<EFS_Utils>();
		//. R_ASSERT (co_res==S_OK);

		//Load cmd line from file if it exists
		std::ifstream cmdlineTxt;
		char path_A[MAX_PATH];
		strcpy(path_A, Core.ApplicationPath);
#ifdef XR_PLATFORM_WINDOWS
		strcat(path_A, "\\..\\commandline.txt");
#else
		strcat(path_A, "/../commandline.txt");
#endif
		cmdlineTxt.open(path_A);
		
		if (!cmdlineTxt)
		{
			cmdlineTxt.close();
			strcpy(path_A, Core.WorkingPath);
#ifdef XR_PLATFORM_WINDOWS
			strcat(path_A, "\\commandline.txt");
#else
			strcat(path_A, "/commandline.txt");
#endif
			cmdlineTxt.open(path_A);
		}

		if (cmdlineTxt)
		{
			Msg("Found commandline file!");
			std::string line;
			char temp[2048];
			sprintf(temp, Params);
			strcat(temp, " ");
			while (std::getline(cmdlineTxt, line))
			{
				strcat(temp, line.c_str());
				strcat(temp, " ");
			}
			Params = xr_strdup(temp);
		}
		cmdlineTxt.close();
	}
	if (init_fs)
	{
		u32 flags = 0;
		if (0 != strstr(Params, "-build")) flags |= CLocatorAPI::flBuildCopy;
		if (0 != strstr(Params, "-ebuild")) flags |= CLocatorAPI::flBuildCopy | CLocatorAPI::flEBuildCopy;
#ifdef DEBUG
        if (strstr(Params, "-cache")) flags |= CLocatorAPI::flCacheFiles;
        else flags &= ~CLocatorAPI::flCacheFiles;
#endif // DEBUG
#ifdef _EDITOR // for EDITORS - no cache
        flags &= ~CLocatorAPI::flCacheFiles;
#endif // _EDITOR
		flags |= CLocatorAPI::flScanAppRoot;

#ifndef _EDITOR
#ifndef ELocatorAPIH
		if (0 != strstr(Params, "-file_activity")) flags |= CLocatorAPI::flDumpFileActivity;
#endif
#endif
		FS._initialize(flags, 0, fs_fname);
		Msg("'%s' build %d, %s\n", "xrCore", build_id, build_date);
		EFS._initialize();
#ifdef DEBUG
#ifndef _EDITOR
        Msg("Process heap 0x%08x", GetProcessHeap());
#endif
#endif // DEBUG
	}
	SetLogCB(cb);
	init_counter++;
}

#ifndef _EDITOR
#include "compression_ppmd_stream.h"
extern compression::ppmd::stream* trained_model;
#endif
void xrCore::_destroy()
{
	--init_counter;
	if (0 == init_counter)
	{
		FS._destroy();
		EFS._destroy();
		xr_delete(xr_FS);
		xr_delete(xr_EFS);

#ifndef _EDITOR
		if (trained_model)
		{
			void* buffer = trained_model->buffer();
			xr_free(buffer);
			xr_delete(trained_model);
		}
#endif
		xr_free(Params);
		Memory._destroy();
	}
}

#ifndef XRCORE_STATIC

// DLL entry points are a Windows concept; on macOS library init happens via
// explicit Core._initialize() from the SDL main.
#ifdef XR_PLATFORM_WINDOWS
//. why ???
#ifdef _EDITOR
BOOL WINAPI DllEntryPoint(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved)
#else
//BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved)
BOOL DllMainXrCore(HANDLE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved)
#endif
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		{
			_clear87();
			_control87(_PC_53, MCW_PC);
			_control87(_RC_CHOP, MCW_RC);
			_control87(_RC_NEAR, MCW_RC);
			_control87(_MCW_EM, MCW_EM);
		}
		//. LogFile.reserve (256);
		break;
	case DLL_THREAD_ATTACH:
		if (!strstr(GetCommandLine(), "-editor"))
			CoInitializeEx(NULL, COINIT_MULTITHREADED);
		timeBeginPeriod(1);
		break;
	case DLL_THREAD_DETACH:
		break;
	case DLL_PROCESS_DETACH:
#ifdef USE_MEMORY_MONITOR
        memory_monitor::flush_each_time(true);
#endif // USE_MEMORY_MONITOR
		break;
	}
	return TRUE;
}
#endif // XR_PLATFORM_WINDOWS
#endif // XRCORE_STATIC
