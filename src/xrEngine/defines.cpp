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

#ifdef XR_PLATFORM_POSIX
// p4: xrEngine carries DATA references to these globals (xr_ioc_cmd.h inline
// setter, x_ray.cpp, FDemoRecord.cpp, xr_ioc_cmd.cpp). dyld binds data refs
// eagerly at image load, but on POSIX xrGame is dlopened after engine init —
// so the definitions live here on POSIX; xrGame's copies are guarded off.
u32 g_crosshair_color = 0x80ffffff; // C_DEFAULT = D3DCOLOR_RGBA(0xff,0xff,0xff,0x80), HUDTarget.cpp
float g_fTimeFactor = 10.0f;        // game_base.cpp
float g_dispersion_base = 1.0f;     // ai/stalker/ai_stalker_fire.cpp
float g_dispersion_factor = 1.0f;   // ai/stalker/ai_stalker_fire.cpp
u32 g_dead_body_collision = 1;      // console_commands.cpp
bool g_actor_allow_ladder = true;   // level_script.cpp
// MOUSE_1..MOUSE_8 == 0xED+100..0xED+107 (xr_level_controller.h / Xr_input.cpp)
int mouse_button_2_key[] = { 0xED + 100, 0xED + 101, 0xED + 102, 0xED + 103, 0xED + 104, 0xED + 105, 0xED + 106, 0xED + 107 };
#endif

// textures
int psTextureLOD = 1;
