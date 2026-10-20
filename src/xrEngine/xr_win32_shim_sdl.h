// xr_win32_shim_sdl.h — POSIX (macOS) shim for the Win32 windowing/message
// surface used by xrEngine call sites, backed by SDL2. Keeps the Win32 call
// sites intact (design rule): HWNDs are SDL_Window* handles, the message
// queue is an SDL event translation, window queries hit SDL.
//
// Included from xrEngine/stdafx.h on POSIX only.

#pragma once

#ifdef XR_PLATFORM_POSIX

#include <cstring>
#include <deque>

#include <SDL.h>

// win_compat.h provides trivial no-op macros for these; the engine wants the
// SDL-backed versions below.
#ifdef ShowCursor
#undef ShowCursor
#endif
#ifdef ShowWindow
#undef ShowWindow
#endif
#ifdef GetActiveWindow
#undef GetActiveWindow
#endif

#ifndef LPRECT
typedef PRECT LPRECT;
#endif

// Engine's primary window accessor (defined in Device_Initialize.cpp).
HWND xr_sdl_primary_window();

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
#ifndef HBRUSH
typedef void* HBRUSH;
#endif
#ifndef HFONT
typedef void* HFONT;
#endif
#ifndef HBITMAP
typedef void* HBITMAP;
#endif
#ifndef HGDIOBJ
typedef void* HGDIOBJ;
#endif
#ifndef COLORREF
typedef unsigned long COLORREF;
#endif
#ifndef HICON
typedef void* HICON;
#endif
#ifndef HCURSOR
typedef void* HCURSOR;
#endif
#ifndef HMENU
typedef void* HMENU;
#endif
#ifndef HDC
typedef void* HDC;
#endif
#ifndef HGLOBAL
typedef void* HGLOBAL;
#endif
#ifndef ATOM
typedef unsigned short ATOM;
#endif
#ifndef CALLBACK
#define CALLBACK
#endif
#ifndef WINAPI
#define WINAPI
#endif
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

typedef struct tagMSG
{
    HWND hwnd;
    unsigned int message;
    WPARAM wParam;
    LPARAM lParam;
    unsigned int time;
    POINT pt;
} MSG, *LPMSG;
#define XR_HAVE_MSG_TYPEDEF 1

// ---------------------------------------------------------------------------
// Constants (canonical Win32 values; only the subset xrEngine references)
// ---------------------------------------------------------------------------
enum
{
    WM_NULL = 0x0000,
    WM_CREATE = 0x0001,
    WM_DESTROY = 0x0002,
    WM_MOVE = 0x0003,
    WM_SIZE = 0x0005,
    WM_ACTIVATE = 0x0006,
    WM_SETFOCUS = 0x0007,
    WM_KILLFOCUS = 0x0008,
    WM_CLOSE = 0x0010,
    WM_QUIT = 0x0012,
    WM_PAINT = 0x000F,
    WM_ERASEBKGND = 0x0014,
    WM_NCPAINT = 0x0085,
    WM_SETCURSOR = 0x0020,
    WM_KEYDOWN = 0x0100,
    WM_KEYUP = 0x0101,
    WM_CHAR = 0x0102,
    WM_SYSKEYDOWN = 0x0104,
    WM_SYSKEYUP = 0x0105,
    WM_SYSCHAR = 0x0103,
    WM_SYSCOMMAND = 0x0112,
    WM_COMMAND = 0x0111,
    WM_TIMER = 0x0113,
    WM_MOUSEMOVE = 0x0200,
    WM_LBUTTONDOWN = 0x0201,
    WM_LBUTTONUP = 0x0202,
    WM_RBUTTONDOWN = 0x0204,
    WM_RBUTTONUP = 0x0205,
    WM_MBUTTONDOWN = 0x0207,
    WM_MBUTTONUP = 0x0208,
    WM_MOUSEWHEEL = 0x020A,
    WM_CAPTURECHANGED = 0x0215,
    WM_ENTERSIZEMOVE = 0x0231,
    WM_EXITSIZEMOVE = 0x0232,
    WM_WINDOWPOSCHANGING = 0x0046,
    WM_WINDOWPOSCHANGED = 0x0047,
    WM_GETMINMAXINFO = 0x0024,
    WM_HOTKEY = 0x0312,
    WM_INPUT = 0x00FF,
    WM_INPUT_DEVICE_CHANGE = 0x00FE,
    WM_DISPLAYCHANGE = 0x007E,
    WM_KANJIMESSAGE_unused = 0x01FF
};

enum
{
    SC_SIZE = 0xF000,
    SC_MOVE = 0xF010,
    SC_MINIMIZE = 0xF020,
    SC_MAXIMIZE = 0xF030,
    SC_RESTORE = 0xF120,
    SC_MONITORPOWER = 0xF170
};

enum
{
    WA_INACTIVE = 0,
    WA_ACTIVE = 1,
    WA_CLICKABLE = 2
};

// window styles (canonical values)
#define WS_OVERLAPPED 0x00000000L
#define WS_POPUP 0x80000000L
#define WS_CHILD 0x40000000L
#define WS_VISIBLE 0x10000000L
#define WS_CLIPSIBLINGS 0x04000000L
#define WS_CLIPCHILDREN 0x02000000L
#define WS_CAPTION 0x00C00000L /* WS_BORDER | WS_DLGFRAME  */
#define WS_BORDER 0x00800000L
#define WS_DLGFRAME 0x00400000L
#define WS_SYSMENU 0x00080000L
#define WS_THICKFRAME 0x00040000L
#define WS_MINIMIZEBOX 0x00020000L
#define WS_MAXIMIZEBOX 0x00010000L
#define WS_EX_TOPMOST 0x00000008L
#define WS_EX_CLIENTEDGE 0x00000200L
#define WS_ACTIVECAPTION 0x0001
#define WS_OVERLAPPEDWINDOW (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | \
                             WS_MINIMIZEBOX | WS_MAXIMIZEBOX)

#define CW_USEDEFAULT ((int)0x80000000)

enum
{
    SW_HIDE = 0,
    SW_SHOWNORMAL = 1,
    SW_SHOWMINIMIZED = 2,
    SW_SHOWMAXIMIZED = 3,
    SW_SHOW = 5,
    SW_RESTORE = 9
};

#define SWP_NOSIZE 0x0001
#define SWP_NOMOVE 0x0002
#define SWP_NOZORDER 0x0004
#define SWP_FRAMECHANGED 0x0020
#define SWP_SHOWWINDOW 0x0040

#define HWND_TOP ((HWND)(intptr_t)0)
#define HWND_BOTTOM ((HWND)(intptr_t)1)
#define HWND_TOPMOST ((HWND)(intptr_t)-1)
#define HWND_NOTOPMOST ((HWND)(intptr_t)-2)

#define GWL_WNDPROC (-4)
#define GWL_HINSTANCE (-6)
#define GWL_STYLE (-16)
#define GWL_EXSTYLE (-20)
#define GWLP_WNDPROC (-4)
#define GWLP_STYLE GWL_STYLE

enum
{
    SM_CXSCREEN = 0,
    SM_CYSCREEN = 1,
    SM_CXVSCROLL = 2,
    SM_CYVSCROLL = 3,
    SM_SWAPBUTTON = 23,
    SM_CXSIZEFRAME = 32,
    SM_CYSIZEFRAME = 33,
    SM_CXPADDEDBORDER = 92,
    SM_CXVIRTUALSCREEN = 78,
    SM_CYVIRTUALSCREEN = 79,
    SM_CMETRICS = 93
};

// virtual keys (subset — full map arrives with the SDL input port, p3 t2)
#define VK_LBUTTON 0x01
#define VK_RBUTTON 0x02
#define VK_CANCEL 0x03
#define VK_MBUTTON 0x04
#define VK_BACK 0x08
#define VK_TAB 0x09
#define VK_RETURN 0x0D
#define VK_SHIFT 0x10
#define VK_CONTROL 0x11
#define VK_MENU 0x12
#define VK_PAUSE 0x13
#define VK_CAPITAL 0x14
#define VK_ESCAPE 0x1B
#define VK_SPACE 0x20
#define VK_PRIOR 0x21
#define VK_NEXT 0x22
#define VK_END 0x23
#define VK_HOME 0x24
#define VK_LEFT 0x25
#define VK_UP 0x26
#define VK_RIGHT 0x27
#define VK_DOWN 0x28
#define VK_SNAPSHOT 0x2C
#define VK_INSERT 0x2D
#define VK_DELETE 0x2E
#define VK_LWIN 0x5B
#define VK_RWIN 0x5C
#define VK_NUMPAD0 0x60
#define VK_F1 0x70
#define VK_F12 0x7B
#define VK_NUMLOCK 0x90
#define VK_SCROLL 0x91
#define VK_LSHIFT 0xA0
#define VK_RSHIFT 0xA1
#define VK_LCONTROL 0xA2
#define VK_RCONTROL 0xA3
#define VK_LMENU 0xA4
#define VK_RMENU 0xA5

#define MK_LBUTTON 0x0001
#define MK_RBUTTON 0x0002
#define MK_SHIFT 0x0004
#define MK_CONTROL 0x0008
#define MK_MBUTTON 0x0010

#define PM_NOREMOVE 0x0000
#define PM_REMOVE 0x0001

#define IDC_ARROW ((const char*)(intptr_t)32512)
#define IDC_IBEAM ((const char*)(intptr_t)32513)

#define MAKEINTRESOURCEA(i) ((const char*)(uintptr_t)(i))
#define MAKEINTRESOURCEW(i) ((const wchar_t*)(uintptr_t)(i))
#define MAKEINTRESOURCE MAKEINTRESOURCEA

#define GET_X_LPARAM(lp) ((int)(short)LOWORD(lp))
#define GET_Y_LPARAM(lp) ((int)(short)HIWORD(lp))
#ifndef LOWORD
#define LOWORD(l) ((unsigned short)((unsigned int)(l) & 0xFFFF))
#endif
#ifndef HIWORD
#define HIWORD(l) ((unsigned short)(((unsigned int)(l) >> 16) & 0xFFFF))
#endif
#ifndef MAKELPARAM
#define MAKELPARAM(x, y) ((LPARAM)(unsigned int)(((unsigned short)(x)) | (((unsigned int)(unsigned short)(y)) << 16)))
#endif

// ---------------------------------------------------------------------------
// Window state + helpers
// ---------------------------------------------------------------------------
// The engine's primary window (Device.m_hWnd); shim functions operate on it.
inline SDL_Window* xr_sdl_window_of(HWND hwnd)
{
    // All engine HWNDs are SDL_Window*; the shim tracks one primary window.
    return (SDL_Window*)hwnd;
}

struct xr_win32_window_state
{
    long style = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
    long exstyle = 0;
};
inline xr_win32_window_state& xr_win32_state()
{
    static xr_win32_window_state s_state;
    return s_state;
}

// ---------------------------------------------------------------------------
// Message queue (SDL event translation)
// ---------------------------------------------------------------------------
inline std::deque<MSG>& xr_msg_queue()
{
    static std::deque<MSG> q;
    return q;
}
inline bool& xr_quit_posted()
{
    static bool q = false;
    return q;
}

static // Raw input events for the CInput SDL backend (xr_input_sdl.cpp). The message
// pump is the sole SDL_PollEvent consumer, so it mirrors input events here.
struct XrRawInputEvent
{
    enum Type : unsigned char
    {
        KeyDown = 0,
        KeyUp,
        MouseMotion,
        MouseButtonDown,
        MouseButtonUp,
        MouseWheel,
        ControllerButtonDown, // a = SDL button, b = instance id
        ControllerButtonUp,   // a = SDL button, b = instance id
        ControllerAxis,       // a = SDL axis, b = value (-32767..32767)
        ControllerDeviceAdded,   // a = joystick index
        ControllerDeviceRemoved, // a = instance id
    };
    Type type;
    int a; // key: SDL scancode; button: SDL button; wheel: y; motion: dx
    int b; // motion: dy; controller button/axis: instance id / axis value
    int c; // controller axis: instance id
};
inline std::deque<XrRawInputEvent>& xr_raw_input_queue()
{
    static std::deque<XrRawInputEvent> q;
    return q;
}
inline void xr_raw_input_push(XrRawInputEvent::Type t, int a, int b = 0, int c = 0)
{
    if (xr_raw_input_queue().size() < 8192)
    {
        XrRawInputEvent ev;
        ev.type = t;
        ev.a = a;
        ev.b = b;
        ev.c = c;
        xr_raw_input_queue().push_back(ev);
    }
}

// p4: absolute cursor mirror (points). Set on every SDL mouse-motion event
// (SDL_SendWarpEvent includes absolute coords) and immediately by
// SetCursorPos. GetCursorPos prefers this over SDL_GetMouseState.
inline bool& xr_cursor_abs_valid()
{
    static bool v = false;
    return v;
}
inline int& xr_cursor_abs_pts(int idx)
{
    static int v[2] = { 0, 0 };
    return v[idx];
}
inline bool xr_cursor_abs(int& x, int& y)
{
    if (!xr_cursor_abs_valid())
        return false;
    x = xr_cursor_abs_pts(0);
    y = xr_cursor_abs_pts(1);
    return true;
}
inline void xr_cursor_abs_set(int x, int y)
{
    xr_cursor_abs_pts(0) = x;
    xr_cursor_abs_pts(1) = y;
    xr_cursor_abs_valid() = true;
}

inline MSG xr_translate_sdl(const SDL_Event& e, bool& ok)
{
    MSG m{};
    ok = false;
    SDL_Window* win = SDL_GetWindowFromID(e.window.windowID);
    m.hwnd = (HWND)win;
    m.time = SDL_GetTicks();

    switch (e.type)
    {
    case SDL_QUIT:
        m.message = WM_QUIT;
        ok = true;
        break;
    case SDL_WINDOWEVENT:
        m.message = WM_NULL;
        switch (e.window.event)
        {
        case SDL_WINDOWEVENT_CLOSE: m.message = WM_CLOSE; break;
        case SDL_WINDOWEVENT_SHOWN:
        case SDL_WINDOWEVENT_EXPOSED: m.message = WM_PAINT; break;
        case SDL_WINDOWEVENT_FOCUS_GAINED:
            m.message = WM_ACTIVATE;
            m.wParam = WA_CLICKABLE;
            ok = true;
            m.message = WM_SETFOCUS;
            break;
        case SDL_WINDOWEVENT_FOCUS_LOST:
            m.message = WM_ACTIVATE;
            m.wParam = WA_INACTIVE;
            ok = true;
            m.message = WM_KILLFOCUS;
            break;
        case SDL_WINDOWEVENT_MINIMIZED:
            m.message = WM_ACTIVATE;
            m.wParam = WA_INACTIVE;
            ok = true;
            m.message = WM_SIZE;
            m.lParam = 1; // SIZE_MINIMIZED
            break;
        case SDL_WINDOWEVENT_RESTORED: m.message = WM_SIZE; m.lParam = 0; break;
        case SDL_WINDOWEVENT_SIZE_CHANGED:
        case SDL_WINDOWEVENT_RESIZED:
            m.message = WM_SIZE;
            m.lParam = MAKELPARAM(e.window.data1, e.window.data2);
            break;
        case SDL_WINDOWEVENT_MOVED:
            m.message = WM_MOVE;
            break;
        case SDL_WINDOWEVENT_ENTER: m.message = WM_MOUSEMOVE; break;
        default: break;
        }
        ok = ok || m.message != WM_NULL;
        break;
    case SDL_KEYDOWN:
    case SDL_KEYUP:
        xr_raw_input_push(e.type == SDL_KEYDOWN ? XrRawInputEvent::KeyDown
                                                : XrRawInputEvent::KeyUp,
                          e.key.keysym.scancode);
        m.message = e.type == SDL_KEYDOWN ? (uint32_t)WM_KEYDOWN : (uint32_t)WM_KEYUP;
        m.wParam = e.key.keysym.sym; // SDL keysym; input port maps to VK
        m.lParam = (e.key.state == SDL_PRESSED) ? 1 : 0;
        ok = true;
        break;
    case SDL_MOUSEMOTION:
        xr_cursor_abs_set(e.motion.x, e.motion.y); // p4: absolute mirror
        xr_raw_input_push(XrRawInputEvent::MouseMotion, e.motion.xrel, e.motion.yrel);
        m.message = WM_MOUSEMOVE;
        m.lParam = MAKELPARAM(e.motion.x, e.motion.y);
        ok = true;
        break;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
    {
        xr_raw_input_push(e.type == SDL_MOUSEBUTTONDOWN ? XrRawInputEvent::MouseButtonDown
                                                        : XrRawInputEvent::MouseButtonUp,
                          e.button.button);
        bool down = e.button.state == SDL_PRESSED;
        m.wParam = 0;
        switch (e.button.button)
        {
        case SDL_BUTTON_LEFT: m.message = down ? WM_LBUTTONDOWN : WM_LBUTTONUP; m.wParam = MK_LBUTTON; break;
        case SDL_BUTTON_RIGHT: m.message = down ? WM_RBUTTONDOWN : WM_RBUTTONUP; m.wParam = MK_RBUTTON; break;
        case SDL_BUTTON_MIDDLE: m.message = down ? WM_MBUTTONDOWN : WM_MBUTTONUP; m.wParam = MK_MBUTTON; break;
        default: break;
        }
        m.lParam = MAKELPARAM(e.button.x, e.button.y);
        ok = m.message != 0;
        break;
    }
    case SDL_MOUSEWHEEL:
        xr_raw_input_push(XrRawInputEvent::MouseWheel, e.wheel.y);
        m.message = WM_MOUSEWHEEL;
        m.wParam = (WPARAM)(short)(e.wheel.y * 120);
        ok = true;
        break;
    case SDL_CONTROLLERBUTTONDOWN:
        xr_raw_input_push(XrRawInputEvent::ControllerButtonDown, e.cbutton.button, e.cbutton.which);
        break;
    case SDL_CONTROLLERBUTTONUP:
        xr_raw_input_push(XrRawInputEvent::ControllerButtonUp, e.cbutton.button, e.cbutton.which);
        break;
    case SDL_CONTROLLERAXISMOTION:
        xr_raw_input_push(XrRawInputEvent::ControllerAxis, e.caxis.axis, e.caxis.value,
                          e.caxis.which);
        break;
    case SDL_CONTROLLERDEVICEADDED:
        xr_raw_input_push(XrRawInputEvent::ControllerDeviceAdded, e.cdevice.which);
        break;
    case SDL_CONTROLLERDEVICEREMOVED:
        xr_raw_input_push(XrRawInputEvent::ControllerDeviceRemoved, e.cdevice.which);
        break;
    case SDL_JOYDEVICEADDED:
    case SDL_JOYDEVICEREMOVED:
        m.message = WM_INPUT_DEVICE_CHANGE; // gamepad hotplug (p3 t4)
        m.wParam = e.jdevice.which;
        ok = true;
        break;
    default:
        break;
    }
    return m;
}

inline BOOL PeekMessageA(LPMSG m, HWND, unsigned int wFilterMin, unsigned int wFilterMax, unsigned int wRemoveMsg)
{
    SDL_PumpEvents();

    // drain translated queue first
    if (xr_msg_queue().empty())
    {
        SDL_Event e;
        while (SDL_PollEvent(&e))
        {
            bool ok = false;
            MSG msg = xr_translate_sdl(e, ok);
            if (ok)
                xr_msg_queue().push_back(msg);
        }
        if (xr_msg_queue().empty() && xr_quit_posted())
        {
            MSG q{};
            q.message = WM_QUIT;
            xr_msg_queue().push_back(q);
            xr_quit_posted() = false;
        }
    }

    while (!xr_msg_queue().empty())
    {
        MSG msg = xr_msg_queue().front();
        bool inRange = (wFilterMin == 0 && wFilterMax == 0) ||
                       (msg.message >= wFilterMin && msg.message <= wFilterMax);
        if (!inRange)
        {
            xr_msg_queue().pop_front();
            continue; // Win32 would keep it; engine always filters 0..0
        }
        xr_msg_queue().pop_front();
        if (wRemoveMsg == PM_REMOVE && m)
            *m = msg;
        return TRUE;
    }
    return FALSE;
}
#define PeekMessage PeekMessageA

inline BOOL TranslateMessage(const MSG*) { return TRUE; }

LRESULT CALLBACK WndProc(HWND hWnd, unsigned int uMsg, WPARAM wParam, LPARAM lParam);
inline LRESULT DefWindowProcA(HWND h, unsigned int msg, WPARAM w, LPARAM l)
{
    (void)h; (void)msg; (void)w; (void)l;
    return 0;
}
#define DefWindowProc DefWindowProcA

inline void DispatchMessageA(const MSG* m)
{
    WndProc(m->hwnd, m->message, m->wParam, m->lParam);
}
#define DispatchMessage DispatchMessageA

inline void PostQuitMessage(int) { xr_quit_posted() = true; }

// ---------------------------------------------------------------------------
// Window queries / ops
// ---------------------------------------------------------------------------
inline void SetRect(LPRECT r, int l, int t, int rr, int b)
{
    r->left = l; r->top = t; r->right = rr; r->bottom = b;
}

inline void GetClientRect(HWND hwnd, LPRECT r)
{
    int w = 640, h = 480;
    if (SDL_Window* win = xr_sdl_window_of(hwnd))
        SDL_GetWindowSize(win, &w, &h);
    SetRect(r, 0, 0, w, h);
}

inline BOOL GetWindowRect(HWND hwnd, LPRECT r)
{
    int x = 0, y = 0, w = 640, h = 480;
    if (SDL_Window* win = xr_sdl_window_of(hwnd))
    {
        SDL_GetWindowPosition(win, &x, &y);
        SDL_GetWindowSize(win, &w, &h);
    }
    SetRect(r, x, y, x + w, y + h);
    return TRUE;
}

inline int MapWindowPoints(HWND frm, HWND to, LPPOINT pts, unsigned int cnt)
{
    // client -> screen offset via window origin
    if (!frm)
        return 0;
    int x = 0, y = 0;
    if (SDL_Window* win = xr_sdl_window_of(frm))
        SDL_GetWindowPosition(win, &x, &y);
    for (unsigned int i = 0; i < cnt; ++i)
    {
        pts[i].x += x;
        pts[i].y += y;
    }
    return 0;
}

inline BOOL ScreenToClient(HWND hwnd, LPPOINT p)
{
    if (!hwnd)
        return TRUE;
    int x = 0, y = 0;
    if (SDL_Window* win = xr_sdl_window_of(hwnd))
        SDL_GetWindowPosition(win, &x, &y);
    p->x -= x;
    p->y -= y;
    return TRUE;
}

inline BOOL ClientToScreen(HWND hwnd, LPPOINT p) // inverse of ScreenToClient above
{
    if (!hwnd)
        return TRUE;
    int x = 0, y = 0;
    if (SDL_Window* win = xr_sdl_window_of(hwnd))
        SDL_GetWindowPosition(win, &x, &y);
    p->x += x;
    p->y += y;
    return TRUE;
}

inline BOOL AdjustWindowRect(LPRECT r, unsigned long /*style*/, BOOL /*menu*/)
{
    // SDL sizes are client sizes; add a nominal title-bar allowance so the
    // legacy 640x480 request looks sane on windowed mode.
    int extra = 28;
    r->bottom += extra;
    r->left -= 8; r->right += 8; r->top -= 8; r->bottom += 8;
    return TRUE;
}

inline long GetWindowLongA(HWND hwnd, int idx)
{
    if (idx == GWL_STYLE)
        return xr_win32_state().style;
    if (idx == GWL_EXSTYLE)
        return xr_win32_state().exstyle;
    return 0;
}
#define GetWindowLong GetWindowLongA
inline long SetWindowLongA(HWND hwnd, int idx, long v)
{
    long old = GetWindowLongA(hwnd, idx);
    if (idx == GWL_STYLE)
    {
        xr_win32_state().style = v;
        bool want_fullscreen = (v & WS_POPUP) != 0;
        if (SDL_Window* win = xr_sdl_window_of(hwnd))
            SDL_SetWindowFullscreen(win, want_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
    }
    else if (idx == GWL_EXSTYLE)
        xr_win32_state().exstyle = v;
    return old;
}
#define SetWindowLong SetWindowLongA
#define SetWindowLongPtrA SetWindowLongA
#define SetWindowLongPtr SetWindowLongPtrA
#define GetWindowLongPtr GetWindowLongA

inline BOOL SetWindowPos(HWND hwnd, HWND insertAfter, int x, int y, int cx, int cy, unsigned int flags)
{
    SDL_Window* win = xr_sdl_window_of(hwnd);
    if (!win)
        return FALSE;
    if (insertAfter == HWND_TOPMOST)
        SDL_SetWindowAlwaysOnTop(win, SDL_TRUE);
    else if (insertAfter == HWND_NOTOPMOST)
        SDL_SetWindowAlwaysOnTop(win, SDL_FALSE);
    if (!(flags & SWP_NOMOVE))
        SDL_SetWindowPosition(win, x, y);
    if (!(flags & SWP_NOSIZE) && cx > 0 && cy > 0)
        SDL_SetWindowSize(win, cx, cy);
    if (flags & SWP_SHOWWINDOW)
        SDL_ShowWindow(win);
    return TRUE;
}

inline BOOL ShowWindow(HWND hwnd, int cmd)
{
    SDL_Window* win = xr_sdl_window_of(hwnd);
    if (!win)
        return FALSE;
    switch (cmd)
    {
    case SW_HIDE: SDL_HideWindow(win); break;
    case SW_SHOWNORMAL:
    case SW_SHOW: SDL_ShowWindow(win); break;
    case SW_SHOWMINIMIZED: SDL_MinimizeWindow(win); break;
    case SW_SHOWMAXIMIZED: SDL_MaximizeWindow(win); break;
    case SW_RESTORE: SDL_RestoreWindow(win); break;
    }
    return TRUE;
}

inline HWND SetActiveWindow(HWND hwnd)
{
    SDL_Window* win = xr_sdl_window_of(hwnd);
    if (win)
        SDL_RaiseWindow(win);
    return hwnd;
}
inline HWND GetActiveWindow() { return nullptr; }
inline HWND GetForegroundWindow() { return nullptr; }
inline HWND GetDesktopWindow() { return nullptr; }
inline BOOL SetForegroundWindow(HWND hwnd) { SetActiveWindow(hwnd); return TRUE; }

inline int ShowCursor(BOOL show) { return SDL_ShowCursor(show ? SDL_ENABLE : SDL_DISABLE); }

inline BOOL ClipCursor(const RECT* r)
{
    // Engine semantics: confine the cursor while playing. SDL window grab is
    // the equivalent; the input port (p3 t2) uses the same mechanism.
    SDL_Window* win = xr_sdl_window_of(xr_sdl_primary_window());
    if (win)
        SDL_SetWindowGrab(win, r ? SDL_TRUE : SDL_FALSE);
    return TRUE;
}

inline int GetSystemMetrics(int idx)
{
    SDL_DisplayMode dm{};
    SDL_GetDesktopDisplayMode(0, &dm);
    switch (idx)
    {
    case SM_CXSCREEN: return dm.w;
    case SM_CYSCREEN: return dm.h;
    case SM_CXVIRTUALSCREEN: return dm.w;
    case SM_CYVIRTUALSCREEN: return dm.h;
    default: return 0;
    }
}

inline BOOL GetCursorPos(LPPOINT p)
{
    int x = 0, y = 0;
    // p4: absolute-position tracking. SDL2/macOS does not refresh
    // SDL_GetMouseState after SDL_WarpMouseInWindow (harness clicks, any
    // SetCursorPos consumer), so mirror the absolute coords carried by
    // motion events (warp events included) and prefer them once seen.
    if (!xr_cursor_abs(x, y))
        SDL_GetMouseState(&x, &y);
    // p4: SDL reports mouse position in window POINTS, but the engine sizes
    // dwWidth/dwHeight from the drawable (BACKING PIXELS on Retina — 2x).
    // Without scaling the UI cursor only reaches the top-left quarter of the
    // window. Convert points -> pixels by the drawable/window ratio.
    SDL_Window* win = xr_sdl_window_of(xr_sdl_primary_window());
    if (win)
    {
        int ww = 0, wh = 0, dw = 0, dh = 0;
        SDL_GetWindowSize(win, &ww, &wh);
        SDL_GL_GetDrawableSize(win, &dw, &dh);
        if (ww > 0 && dw > 0)
            x = (int)((int64_t)x * dw / ww);
        if (wh > 0 && dh > 0)
            y = (int)((int64_t)y * dh / wh);
    }
    p->x = x;
    p->y = y;
    return TRUE;
}
inline BOOL SetCursorPos(int x, int y)
{
    SDL_Window* win = xr_sdl_window_of(xr_sdl_primary_window());
    if (win)
    {
        // inverse of GetCursorPos: engine coords are pixels, warp wants points
        int ww = 0, wh = 0, dw = 0, dh = 0;
        SDL_GetWindowSize(win, &ww, &wh);
        SDL_GL_GetDrawableSize(win, &dw, &dh);
        if (dw > 0 && ww > 0)
            x = (int)((int64_t)x * ww / dw);
        if (dh > 0 && wh > 0)
            y = (int)((int64_t)y * wh / dh);
        xr_cursor_abs_set(x, y); // p4: mirror now; SDL state lags warp badly
        SDL_WarpMouseInWindow(win, x, y);
    }
    return TRUE;
}
inline HCURSOR SetCursor(HCURSOR) { return nullptr; }

inline HDC GetDC(HWND) { return (HDC)1; }
inline HDC GetWindowDC(HWND) { return (HDC)1; }
inline int ReleaseDC(HWND, HDC) { return 1; }
inline BOOL InvalidateRect(HWND, const RECT*, BOOL) { return TRUE; }
inline BOOL UpdateWindow(HWND) { return TRUE; }

inline short GetKeyState(int vk)
{
    Uint32 m = SDL_GetMouseState(nullptr, nullptr);
    switch (vk)
    {
    case VK_LBUTTON: return (m & SDL_BUTTON_LMASK) ? 0x8000 : 0;
    case VK_RBUTTON: return (m & SDL_BUTTON_RMASK) ? 0x8000 : 0;
    case VK_MBUTTON: return (m & SDL_BUTTON_MMASK) ? 0x8000 : 0;
    case VK_SHIFT:
        return (SDL_GetModState() & KMOD_SHIFT) ? 0x8000 : 0;
    case VK_CONTROL:
        return (SDL_GetModState() & KMOD_CTRL) ? 0x8000 : 0;
    case VK_MENU:
        return (SDL_GetModState() & KMOD_ALT) ? 0x8000 : 0;
    case VK_CAPITAL:
        return (SDL_GetModState() & KMOD_CAPS) ? 0x0001 : 0;
    case VK_NUMLOCK:
        return (SDL_GetModState() & KMOD_NUM) ? 0x0001 : 0;
    }
    return 0;
}

inline BOOL SetCapture(HWND) { return TRUE; }
inline BOOL ReleaseCapture() { return TRUE; }
inline HWND GetCapture() { return nullptr; }

struct WNDCLASSA
{
    unsigned int style;
    LRESULT (*lpfnWndProc)(HWND, unsigned int, WPARAM, LPARAM);
    int cbClsExtra;
    int cbWndExtra;
    void* hInstance;
    HICON hIcon;
    HCURSOR hCursor;
    HBRUSH hbrBackground;
    const char* lpszMenuName;
    const char* lpszClassName;
};
#define WNDCLASS WNDCLASSA
inline ATOM RegisterClassA(const WNDCLASSA*) { return 1; }
#define RegisterClass RegisterClassA

inline HICON LoadIconA(void*, const char*) { return nullptr; }
#define LoadIcon LoadIconA
inline HCURSOR LoadCursorA(void*, const char* name) { (void)name; return nullptr; }
#define LoadCursor LoadCursorA
inline void* GetStockObject(int) { return nullptr; }

// Win32 "not responding" watchdog — no macOS equivalent.
inline void DisableProcessWindowsGhosting() {}

// ---------------------------------------------------------------------------
// Monitors / display modes (refresh-rate probe + window status)
// ---------------------------------------------------------------------------
typedef void* HMONITOR;
#define MONITOR_DEFAULTTOPRIMARY 0x00000001
#define MONITOR_DEFAULTTONEAREST 0x00000002
#define ENUM_CURRENT_SETTINGS ((unsigned int)-1)

typedef struct tagMONITORINFO
{
    unsigned long cbSize;
    RECT rcMonitor;
    RECT rcWork;
    unsigned long dwFlags;
} MONITORINFO, *LPMONITORINFO;

typedef struct tagWINDOWINFO
{
    unsigned long cbSize;
    RECT rcWindow;
    RECT rcClient;
    unsigned long dwStyle;
    unsigned long dwExStyle;
    unsigned int dwWindowStatus;
    unsigned int cxWindowBorders;
    unsigned int cyWindowBorders;
    unsigned short atomWindowType;
    unsigned short wReserved1;
} WINDOWINFO, *LPWINDOWINFO;

typedef struct tagDEVMODEA
{
    char dmDeviceName[32];
    unsigned short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    unsigned long dmFields;
    long dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    long dmColor, dmDepth;
    long dmPelsWidth, dmPelsHeight;
    unsigned long dmBitsPerPel, dmDisplayFlags, dmDisplayFrequency;
    unsigned long dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
    unsigned long dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
} DEVMODEA;
#define DEVMODE DEVMODEA

inline HMONITOR MonitorFromWindow(HWND, unsigned long) { return (HMONITOR)(void*)(intptr_t)1; }

inline BOOL GetMonitorInfoA(HMONITOR, LPMONITORINFO mi)
{
    SDL_DisplayMode dm{};
    SDL_GetDesktopDisplayMode(0, &dm);
    SetRect(&mi->rcMonitor, 0, 0, dm.w, dm.h);
    SetRect(&mi->rcWork, 0, 0, dm.w, dm.h); // menu bar ignored
    mi->dwFlags = 1; // PRIMARY
    return TRUE;
}

inline BOOL GetWindowInfo(HWND hwnd, LPWINDOWINFO wi)
{
    memset(wi, 0, sizeof(WINDOWINFO));
    GetWindowRect(hwnd, &wi->rcWindow);
    GetClientRect(hwnd, &wi->rcClient);
    wi->dwStyle = xr_win32_state().style;
    SDL_Window* win = xr_sdl_window_of(hwnd);
    wi->dwWindowStatus =
        (win && (SDL_GetWindowFlags(win) & SDL_WINDOW_INPUT_FOCUS)) ? WS_ACTIVECAPTION : 0;
    return TRUE;
}

inline int EnumDisplaySettingsA(const char*, unsigned, DEVMODEA* out)
{
    SDL_DisplayMode dm{};
    if (SDL_GetDesktopDisplayMode(0, &dm) != 0)
        return 0;
    memset(out, 0, sizeof(DEVMODEA));
    out->dmSize = sizeof(DEVMODEA);
    out->dmPelsWidth = dm.w;
    out->dmPelsHeight = dm.h;
    out->dmDisplayFrequency = dm.refresh_rate ? (unsigned long)dm.refresh_rate : 60;
    return 1;
}
#define EnumDisplaySettings EnumDisplaySettingsA

// ---------------------------------------------------------------------------
// Keyboard layout (line_edit_control caps-lock probe)
// ---------------------------------------------------------------------------
typedef void* HKL;
#define HKL_NEXT 1
#define HKL_PREV 2
inline HKL ActivateKeyboardLayout(HKL, unsigned int) { return nullptr; }
inline HKL GetKeyboardLayout(unsigned int) { return nullptr; }

// ---------------------------------------------------------------------------
// Dialogs (startup logo window — no-op on macOS)
// ---------------------------------------------------------------------------
typedef INT_PTR (*DLGPROC)(HWND, unsigned int, WPARAM, LPARAM);
inline HWND CreateDialogParamA(void*, const void*, HWND, DLGPROC, long) { return nullptr; }
#define CreateDialogA(h, d, p, proc) CreateDialogParamA(h, d, p, proc, 0)
#define CreateDialogW CreateDialogA
#define CreateDialog CreateDialogA
inline HWND GetDlgItem(HWND, int) { return nullptr; }
inline BOOL EndDialog(HWND, long) { return TRUE; }
inline BOOL DestroyWindow(HWND h)
{
    if (SDL_Window* w = xr_sdl_window_of(h))
        SDL_DestroyWindow(w);
    return TRUE;
}
inline HWND CreateWindowExA(unsigned long, const char*, const char*, unsigned long,
                            int x, int y, int w, int h, HWND, void*, void*, void*)
{
    (void)x; (void)y; (void)w; (void)h;
    return nullptr; // engine must not depend on auxiliary Win32 windows on macOS
}
#define CreateWindowEx CreateWindowExA
inline HWND CreateWindowA(const char* c, const char* t, unsigned long s,
                          int x, int y, int w, int h, HWND p, void* m, void* i, void* l)
{
    return CreateWindowExA(0, c, t, s, x, y, w, h, p, m, i, l);
}
#define CreateWindow CreateWindowA

// ---------------------------------------------------------------------------
// Paint (log-window painting only — never dispatched on macOS)
// ---------------------------------------------------------------------------
typedef struct tagPAINTSTRUCT
{
    HDC hdc;
    BOOL erase;
    RECT rcPaint;
} PAINTSTRUCT, *LPPAINTSTRUCT;
inline HDC BeginPaint(HWND, PAINTSTRUCT* ps)
{
    ps->hdc = nullptr;
    ps->erase = FALSE;
    SetRect(&ps->rcPaint, 0, 0, 0, 0);
    return nullptr;
}
inline BOOL EndPaint(HWND, const PAINTSTRUCT*) { return TRUE; }

// ---------------------------------------------------------------------------
// GDI (Text_Console log window only — no-op on macOS)
// ---------------------------------------------------------------------------
struct LOGFONTA
{
    long lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight;
    unsigned char lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision,
        lfClipPrecision, lfQuality, lfPitchAndFamily;
    char lfFaceName[32];
};
#define LOGFONT LOGFONTA

struct TEXTMETRICA
{
    long tmHeight, tmAscent, tmDescent, tmInternalLeading, tmExternalLeading;
    long tmAveCharWidth, tmMaxCharWidth, tmWeight, tmOverhang;
    long tmDigitizedAspectX, tmDigitizedAspectY;
    unsigned char tmFirstChar, tmDefaultChar, tmBreakChar, tmItalic, tmUnderlined,
        tmStruckOut, tmPitchAndFamily, tmCharSet;
};
#define TEXTMETRIC TEXTMETRICA

#define BLACK_BRUSH 4
#define GRAY_BRUSH 3
#define NULL_BRUSH 5
#define DEFAULT_CHARSET 1
#define OUT_STRING_PRECIS 1
#define OUT_TT_PRECIS 3
#define CLIP_STROKE_PRECIS 2
#define DRAFT_QUALITY 1
#define CLEARTYPE_NATURAL_QUALITY 6
#define FF_SWISS 32
#define FW_NORMAL 400
#define VARIABLE_PITCH 2
#define TRANSPARENT 1
#define OPAQUE 2

inline void* CreateFontIndirectA(const LOGFONT*) { return (void*)(intptr_t)1; }
#define CreateFontIndirect CreateFontIndirectA
inline HDC CreateCompatibleDC(HDC d) { return d; }
inline HBITMAP CreateCompatibleBitmap(HDC, int, int) { return (HBITMAP)(void*)(intptr_t)1; }
inline HGDIOBJ SelectObject(HDC, HGDIOBJ) { return nullptr; }
inline BOOL DeleteObject(HGDIOBJ) { return TRUE; }
inline BOOL DeleteDC(HDC) { return TRUE; }
inline BOOL GetTextMetricsA(HDC, TEXTMETRIC* tm)
{
    *tm = TEXTMETRIC{};
    tm->tmHeight = 12;
    tm->tmAveCharWidth = 7;
    return TRUE;
}
#define GetTextMetrics GetTextMetricsA
inline BOOL TextOutA(HDC, int, int, const char*, int) { return TRUE; }
#define TextOut TextOutA
inline COLORREF SetTextColor(HDC, COLORREF) { return 0; }
inline COLORREF SetBkColor(HDC, COLORREF) { return 0; }
inline int SetBkMode(HDC, int m) { return m; }
inline HBRUSH GetStockBrush(int which) { return (HBRUSH)(void*)(intptr_t)which; }

#define SRCCOPY 0x00CC0020L
inline BOOL FillRect(HDC, const RECT*, HBRUSH) { return TRUE; }
inline BOOL BitBlt(HDC, int, int, int, int, HDC, int, int, unsigned long) { return TRUE; }

#endif // XR_PLATFORM_POSIX
