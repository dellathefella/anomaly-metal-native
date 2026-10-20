#include "stdafx.h"
#include "resource.h"
#include "dedicated_server_only.h"

#ifdef INGAME_EDITOR
# include "../include/editor/ide.hpp"
# include "engine_impl.hpp"
#endif // #ifdef INGAME_EDITOR

extern LRESULT CALLBACK WndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

#ifdef XR_PLATFORM_POSIX
// Primary engine window (SDL_Window* stored as HWND elsewhere).
static HWND g_xr_primary_window = nullptr;
HWND xr_sdl_primary_window() { return g_xr_primary_window; }
#endif

#ifdef INGAME_EDITOR
void CRenderDevice::initialize_editor()
{
    m_editor_module = LoadLibrary("editor.dll");
    if (!m_editor_module)
    {
        Msg("! cannot load library \"editor.dll\"");
        return;
    }

    m_editor_initialize = (initialize_function_ptr)GetProcAddress(m_editor_module, "initialize");
    VERIFY(m_editor_initialize);

    m_editor_finalize = (finalize_function_ptr)GetProcAddress(m_editor_module, "finalize");
    VERIFY(m_editor_finalize);

    m_engine = xr_new<engine_impl>();
    m_editor_initialize(m_editor, m_engine);
    VERIFY(m_editor);

    m_hWnd = m_editor->view_handle();
    VERIFY(m_hWnd != INVALID_HANDLE_VALUE);
}
#endif // #ifdef INGAME_EDITOR

PROTECT_API void CRenderDevice::Initialize()
{
	Log("Initializing Engine...");
	TimerGlobal.Start();
	TimerMM.Start();

#ifdef INGAME_EDITOR
    if (strstr(Core.Params, "-editor"))
        initialize_editor();
#endif // #ifdef INGAME_EDITOR

	// Unless a substitute hWnd has been specified, create a window to render into
	if (m_hWnd == NULL)
	{
#ifdef XR_PLATFORM_POSIX
		// SDL window — the GL/Metal renderer attaches its surface to it.
		SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
		if (SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) != 0)
			Msg("! SDL_InitSubSystem failed: %s", SDL_GetError());
		// p4: GL context hints — the staged OpenXRay renderer needs a 4.1 core
		// context; SDL's default is legacy 2.1. Also needed before the window
		// so the pixel format/flags match.
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
		if (!strstr(Core.Params, "-no_gl_context"))
		{
			SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
			SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);
		}
		SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
		SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
		SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
		// p4: pick the initial window size like Windows does — vid_mode from
		// configs if present, else the desktop mode (so the first-run menu is
		// at native aspect instead of the engine's 640x480 placeholder).
		int init_w = 0, init_h = 0;
		if (pSettings->section_exist("video") && pSettings->exist("video", "vid_mode"))
		{
			u32 vw = 0, vh = 0;
			if (2 == sscanf(pSettings->r_string("video", "vid_mode"), "%ux%u", &vw, &vh) &&
				vw >= 640 && vh >= 480)
			{
				init_w = (int)vw;
				init_h = (int)vh;
			}
		}
		if (init_w <= 0)
		{
			SDL_DisplayMode dm{};
			if (SDL_GetDesktopDisplayMode(0, &dm) == 0 && dm.w >= 640)
			{
				init_w = dm.w;
				init_h = dm.h;
			}
			else
			{
				init_w = 1280;
				init_h = 720;
			}
		}
		psCurrentVidMode[0] = init_w;
		psCurrentVidMode[1] = init_h;
		SDL_Window* win = SDL_CreateWindow(
			"S.T.A.L.K.E.R.: Anomaly",
			SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
			init_w, init_h,
			SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_OPENGL);
		if (!win)
		{
			Msg("! SDL_CreateWindow failed: %s", SDL_GetError());
			R_ASSERT(win);
		}
		m_hWnd = (HWND)win;
		g_xr_primary_window = m_hWnd;
		m_dwWindowStyle = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
#else
		const char* wndclass = "_XRAY_1.5";

		// Register the windows class
		HINSTANCE hInstance = (HINSTANCE)GetModuleHandle(0);
		WNDCLASS wndClass = {
			0, WndProc, 0, 0, hInstance,
			LoadIcon(hInstance, MAKEINTRESOURCE(IDI_ICON1)),
			LoadCursor(NULL, IDC_ARROW),
			(HBRUSH)GetStockObject(BLACK_BRUSH),
			NULL, wndclass
		};
		RegisterClass(&wndClass);

		// Set the window's initial style
		m_dwWindowStyle = WS_BORDER | WS_DLGFRAME;

		// Set the window's initial width
		RECT rc;
		SetRect(&rc, 0, 0, 640, 480);
		AdjustWindowRect(&rc, m_dwWindowStyle, FALSE);

		// Create the render window
		m_hWnd = CreateWindowEx(WS_EX_TOPMOST,
		                        wndclass, "S.T.A.L.K.E.R.: Anomaly", m_dwWindowStyle,
		                        /*rc.left, rc.top, */CW_USEDEFAULT, CW_USEDEFAULT,
		                        (rc.right - rc.left), (rc.bottom - rc.top), 0L,
		                        0, hInstance, 0L);
#endif
	}

	// Save window properties
	m_dwWindowStyle = GetWindowLong(m_hWnd, GWL_STYLE);
	GetWindowRect(m_hWnd, &m_rcWindowBounds);
	GetClientRect(m_hWnd, &m_rcWindowClient);

	/*
	if (strstr(lpCmdLine,"-gpu_sw")!=NULL) HW.Caps.bForceGPU_SW = TRUE;
	else HW.Caps.bForceGPU_SW = FALSE;
	if (strstr(lpCmdLine,"-gpu_nopure")!=NULL) HW.Caps.bForceGPU_NonPure = TRUE;
	else HW.Caps.bForceGPU_NonPure = FALSE;
	if (strstr(lpCmdLine,"-gpu_ref")!=NULL) HW.Caps.bForceGPU_REF = TRUE;
	else HW.Caps.bForceGPU_REF = FALSE;
	*/
}
