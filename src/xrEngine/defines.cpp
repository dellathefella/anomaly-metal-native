#include "stdafx.h"

#ifdef DEBUG
ECORE_API BOOL bDebug = FALSE;

#endif

// Video
//. u32 psCurrentMode = 1024;
u32 psCurrentVidMode[2] = {0, 0};
u32 psCurrentBPP = 32;
// release version always has "mt_*" enabled
Flags32 psDeviceFlags = {
	rsFullscreen | rsDetails | mtPhysics | mtSound | mtNetwork | rsDrawStatic | rsDrawDynamic
};

// p4: on Windows this lives in the monolith renderer's console; the staged
// OpenXRay renderer console does not define it, so the engine owns it here.
// xrGame registers discord_status / g_always_active against it.
Flags32 psDeviceFlags2 = { 0 };

// textures
int psTextureLOD = 1;
