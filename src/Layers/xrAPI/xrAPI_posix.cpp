// xrAPI_posix.cpp — shared renderer/engine globals (Windows equivalent:
// Layers/xrAPI/xrAPI.cpp, a small DLL both sides link against).
//
// On POSIX this builds as xrAPI.dylib so engine and renderer dylibs share a
// single instance of every global. The renderer (p4) fills in Render /
// RenderFactory / DU / UIRender at startup.
#include "xrAPI/xrAPI.h"

struct xr_token;

XRAPI_API IRender_interface* Render = nullptr;
XRAPI_API dxRenderFactory* RenderFactory = nullptr;
XRAPI_API CDUInterface* DU = nullptr;
XRAPI_API xr_token* vid_mode_token = nullptr;
XRAPI_API IUIRender* UIRender = nullptr;
XRAPI_API CGameMtlLibrary* PGMLib = nullptr;
