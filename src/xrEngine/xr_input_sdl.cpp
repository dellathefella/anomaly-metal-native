// xr_input_sdl.cpp — SDL2 input backend for CInput (replaces DirectInput).
//
// Semantics mirror Xr_input.cpp (the DirectInput backend): buffered key/mouse
// events are dispatched to the topmost IInputReceiver, held keys/buttons are
// re-dispatched every frame, and the mouse-stop heuristic uses the same
// mouse_dt window. The message pump (xr_win32_shim_sdl.h) is the sole
// SDL_PollEvent consumer and mirrors raw input events into
// xr_raw_input_queue(); this file drains it.
//
// Controller/gamepad input is handled separately (SDL gamecontroller, t4).

#include "stdafx.h"
#pragma hdrstop

#include "xr_input.h"
#include "IInputReceiver.h"
#include "x_ray.h"
#include "device.h"

#include <SDL.h>
#include <deque>

#ifndef WHEEL_DELTA
#define WHEEL_DELTA 120
#endif

// xr_input_controller.cpp — gamepad rumble (SDL haptic)
void xr_controller_rumble(u16 low, u16 high, float seconds);

CInput* pInput = NULL;
IInputReceiver dummyController;

ENGINE_API float psMouseSens = 1.f;
ENGINE_API float psMouseSensScale = 1.f;
ENGINE_API Flags32 psMouseInvert = { FALSE };

float stop_vibration_time = flt_max;

static bool g_exclusive = false;
static BOOL b_altF4 = FALSE;

extern u32 g_screenmode;

// ---------------------------------------------------------------------------
// SDL scancode -> DIK mapping (SDL scancodes are HID usage IDs, DIK is PC
// set-1; extended keys use the 0x1xx DIK spellings from dinput.h).
// ---------------------------------------------------------------------------
static int sdl_scancode_to_dik(int sc)
{
	switch (sc)
	{
	case SDL_SCANCODE_ESCAPE: return DIK_ESCAPE;
	case SDL_SCANCODE_1: return DIK_1;
	case SDL_SCANCODE_2: return DIK_2;
	case SDL_SCANCODE_3: return DIK_3;
	case SDL_SCANCODE_4: return DIK_4;
	case SDL_SCANCODE_5: return DIK_5;
	case SDL_SCANCODE_6: return DIK_6;
	case SDL_SCANCODE_7: return DIK_7;
	case SDL_SCANCODE_8: return DIK_8;
	case SDL_SCANCODE_9: return DIK_9;
	case SDL_SCANCODE_0: return DIK_0;
	case SDL_SCANCODE_MINUS: return DIK_MINUS;
	case SDL_SCANCODE_EQUALS: return DIK_EQUALS;
	case SDL_SCANCODE_BACKSPACE: return DIK_BACK;
	case SDL_SCANCODE_TAB: return DIK_TAB;
	case SDL_SCANCODE_Q: return DIK_Q;
	case SDL_SCANCODE_W: return DIK_W;
	case SDL_SCANCODE_E: return DIK_E;
	case SDL_SCANCODE_R: return DIK_R;
	case SDL_SCANCODE_T: return DIK_T;
	case SDL_SCANCODE_Y: return DIK_Y;
	case SDL_SCANCODE_U: return DIK_U;
	case SDL_SCANCODE_I: return DIK_I;
	case SDL_SCANCODE_O: return DIK_O;
	case SDL_SCANCODE_P: return DIK_P;
	case SDL_SCANCODE_LEFTBRACKET: return DIK_LBRACKET;
	case SDL_SCANCODE_RIGHTBRACKET: return DIK_RBRACKET;
	case SDL_SCANCODE_RETURN: return DIK_RETURN;
	case SDL_SCANCODE_LCTRL: return DIK_LCONTROL;
	case SDL_SCANCODE_A: return DIK_A;
	case SDL_SCANCODE_S: return DIK_S;
	case SDL_SCANCODE_D: return DIK_D;
	case SDL_SCANCODE_F: return DIK_F;
	case SDL_SCANCODE_G: return DIK_G;
	case SDL_SCANCODE_H: return DIK_H;
	case SDL_SCANCODE_J: return DIK_J;
	case SDL_SCANCODE_K: return DIK_K;
	case SDL_SCANCODE_L: return DIK_L;
	case SDL_SCANCODE_SEMICOLON: return DIK_SEMICOLON;
	case SDL_SCANCODE_APOSTROPHE: return DIK_APOSTROPHE;
	case SDL_SCANCODE_GRAVE: return DIK_GRAVE;
	case SDL_SCANCODE_LSHIFT: return DIK_LSHIFT;
	case SDL_SCANCODE_BACKSLASH: return DIK_BACKSLASH;
	case SDL_SCANCODE_Z: return DIK_Z;
	case SDL_SCANCODE_X: return DIK_X;
	case SDL_SCANCODE_C: return DIK_C;
	case SDL_SCANCODE_V: return DIK_V;
	case SDL_SCANCODE_B: return DIK_B;
	case SDL_SCANCODE_N: return DIK_N;
	case SDL_SCANCODE_M: return DIK_M;
	case SDL_SCANCODE_COMMA: return DIK_COMMA;
	case SDL_SCANCODE_PERIOD: return DIK_PERIOD;
	case SDL_SCANCODE_SLASH: return DIK_SLASH;
	case SDL_SCANCODE_RSHIFT: return DIK_RSHIFT;
	case SDL_SCANCODE_KP_MULTIPLY: return DIK_MULTIPLY;
	case SDL_SCANCODE_LALT: return DIK_LMENU;
	case SDL_SCANCODE_SPACE: return DIK_SPACE;
	case SDL_SCANCODE_CAPSLOCK: return DIK_CAPITAL;
	case SDL_SCANCODE_F1: return DIK_F1;
	case SDL_SCANCODE_F2: return DIK_F2;
	case SDL_SCANCODE_F3: return DIK_F3;
	case SDL_SCANCODE_F4: return DIK_F4;
	case SDL_SCANCODE_F5: return DIK_F5;
	case SDL_SCANCODE_F6: return DIK_F6;
	case SDL_SCANCODE_F7: return DIK_F7;
	case SDL_SCANCODE_F8: return DIK_F8;
	case SDL_SCANCODE_F9: return DIK_F9;
	case SDL_SCANCODE_F10: return DIK_F10;
	case SDL_SCANCODE_NUMLOCKCLEAR: return DIK_NUMLOCK;
	case SDL_SCANCODE_SCROLLLOCK: return DIK_SCROLL;
	case SDL_SCANCODE_HOME: return DIK_HOME;
	case SDL_SCANCODE_UP: return DIK_UP;
	case SDL_SCANCODE_PAGEUP: return DIK_PRIOR;
	case SDL_SCANCODE_LEFT: return DIK_LEFT;
	case SDL_SCANCODE_RIGHT: return DIK_RIGHT;
	case SDL_SCANCODE_END: return DIK_END;
	case SDL_SCANCODE_DOWN: return DIK_DOWN;
	case SDL_SCANCODE_PAGEDOWN: return DIK_NEXT;
	case SDL_SCANCODE_INSERT: return DIK_INSERT;
	case SDL_SCANCODE_DELETE: return DIK_DELETE;
	case SDL_SCANCODE_PRINTSCREEN: return DIK_SNAPSHOT;
	case SDL_SCANCODE_PAUSE: return DIK_PAUSE;
	case SDL_SCANCODE_F11: return DIK_F11;
	case SDL_SCANCODE_F12: return DIK_F12;
	case SDL_SCANCODE_F13: return DIK_F13;
	case SDL_SCANCODE_F14: return DIK_F14;
	case SDL_SCANCODE_F15: return DIK_F15;
	case SDL_SCANCODE_KP_DIVIDE: return DIK_DIVIDE;
	case SDL_SCANCODE_KP_MINUS: return DIK_SUBTRACT;
	case SDL_SCANCODE_KP_PLUS: return DIK_ADD;
	case SDL_SCANCODE_KP_ENTER: return DIK_NUMPADENTER;
	case SDL_SCANCODE_KP_1: return DIK_NUMPAD1;
	case SDL_SCANCODE_KP_2: return DIK_NUMPAD2;
	case SDL_SCANCODE_KP_3: return DIK_NUMPAD3;
	case SDL_SCANCODE_KP_4: return DIK_NUMPAD4;
	case SDL_SCANCODE_KP_5: return DIK_NUMPAD5;
	case SDL_SCANCODE_KP_6: return DIK_NUMPAD6;
	case SDL_SCANCODE_KP_7: return DIK_NUMPAD7;
	case SDL_SCANCODE_KP_8: return DIK_NUMPAD8;
	case SDL_SCANCODE_KP_9: return DIK_NUMPAD9;
	case SDL_SCANCODE_KP_0: return DIK_NUMPAD0;
	case SDL_SCANCODE_KP_PERIOD: return DIK_DECIMAL;
	case SDL_SCANCODE_NONUSBACKSLASH: return DIK_BACKSLASH;
	case SDL_SCANCODE_APPLICATION: return DIK_APPS;
	case SDL_SCANCODE_LGUI: return DIK_LWIN;
	case SDL_SCANCODE_RCTRL: return DIK_RCONTROL;
	case SDL_SCANCODE_RGUI: return DIK_RWIN;
	default: return 0; // unmapped (media keys etc.)
	}
}

// SDL mouse button -> engine mouse index. Engine 3/4 are wheel up/down
// (DirectInput synthesized those as button presses; we synthesize them from
// SDL_MOUSEWHEEL below).
static int sdl_button_to_engine(int sdl_btn)
{
	switch (sdl_btn)
	{
	case SDL_BUTTON_LEFT: return 0;
	case SDL_BUTTON_RIGHT: return 1;
	case SDL_BUTTON_MIDDLE: return 2;
	case SDL_BUTTON_X1: return 5;
	case SDL_BUTTON_X2: return 6;
	default: return -1;
	}
}

// ---------------------------------------------------------------------------
// Raw event routing. KeyUpdate/MouseUpdate may be called in any order (and
// from iCapture/iRelease), so the shared pump splits by category.
// ---------------------------------------------------------------------------
static std::deque<XrRawInputEvent> g_pending_keys;
static std::deque<XrRawInputEvent> g_pending_mouse;
static std::deque<XrRawInputEvent> g_pending_controller;

// consumed by xr_input_controller.cpp
std::deque<XrRawInputEvent>& xr_pending_controller_events() { return g_pending_controller; }

static void pump_sdl_events()
{
	std::deque<XrRawInputEvent>& q = xr_raw_input_queue();
	while (!q.empty())
	{
		XrRawInputEvent ev = q.front();
		q.pop_front();
		switch (ev.type)
		{
		case XrRawInputEvent::KeyDown:
		case XrRawInputEvent::KeyUp: g_pending_keys.push_back(ev); break;
		case XrRawInputEvent::MouseMotion:
		case XrRawInputEvent::MouseButtonDown:
		case XrRawInputEvent::MouseButtonUp:
		case XrRawInputEvent::MouseWheel: g_pending_mouse.push_back(ev); break;
		case XrRawInputEvent::ControllerButtonDown:
		case XrRawInputEvent::ControllerButtonUp:
		case XrRawInputEvent::ControllerAxis:
		case XrRawInputEvent::ControllerDeviceAdded:
		case XrRawInputEvent::ControllerDeviceRemoved: g_pending_controller.push_back(ev); break;
		}
	}
	if (g_pending_keys.size() > 4096)
		g_pending_keys.clear();
	if (g_pending_mouse.size() > 4096)
		g_pending_mouse.clear();
	if (g_pending_controller.size() > 4096)
		g_pending_controller.clear();
}

// ---------------------------------------------------------------------------

CInput::CInput(BOOL bExclusive, int deviceForInit)
{
	g_exclusive = !!bExclusive;

	Log("Starting INPUT device (SDL backend)...");

	// No DirectInput on POSIX; the SDL backend owns no device objects.
	pDI = NULL;
	pMouse = NULL;
	pKeyboard = NULL;

	mouse_property.mouse_dt = 25;

	ZeroMemory(mouseState, sizeof(mouseState));
	ZeroMemory(KBState, sizeof(KBState));
	ZeroMemory(timeStamp, sizeof(timeStamp));
	ZeroMemory(timeSave, sizeof(timeStamp));
	ZeroMemory(offs, sizeof(offs));

	// Dummy receiver so cbStack is never empty (default kQUIT/kCONSOLE handling)
	iCapture(&dummyController);

	if (!SDL_WasInit(SDL_INIT_EVENTS))
		SDL_InitSubSystem(SDL_INIT_EVENTS);

#ifdef ENGINE_BUILD
	Device.seqAppActivate.Add(this);
	Device.seqAppDeactivate.Add(this, REG_PRIORITY_HIGH);
	Device.seqFrame.Add(this, REG_PRIORITY_HIGH);
#endif
}

CInput::~CInput(void)
{
#ifdef ENGINE_BUILD
	Device.seqFrame.Remove(this);
	Device.seqAppDeactivate.Remove(this);
	Device.seqAppActivate.Remove(this);
#endif
	g_pending_keys.clear();
	g_pending_mouse.clear();
	xr_raw_input_queue().clear();
}

//-----------------------------------------------------------------------------

void CInput::KeyUpdate()
{
	if (b_altF4)
		return;

	pump_sdl_events();

	bool b_dik_pause_was_pressed = false;
	bool b_alt_tab = false;

	while (!g_pending_keys.empty())
	{
		XrRawInputEvent ev = g_pending_keys.front();
		g_pending_keys.pop_front();

		int dik = sdl_scancode_to_dik(ev.a);
		if (!dik)
			continue;
		const bool pressed = ev.type == XrRawInputEvent::KeyDown;

		if (dik == DIK_PAUSE)
		{
			if (pressed)
				b_dik_pause_was_pressed = true;
			if (b_dik_pause_was_pressed && !pressed)
				continue; // skip one-frame pause key on-off switch
		}

		// DirectInput reports extended keys with 0x1xx DIKs; KBState is
		// 256 entries wide (the DI backend overflowed it — guard instead).
		if (dik < COUNT_KB_BUTTONS)
			KBState[dik] = pressed ? TRUE : FALSE;

		if (pressed)
			cbStack.back()->IR_OnKeyboardPress(dik);
		else
		{
			cbStack.back()->IR_OnKeyboardRelease(dik);
			if (dik == DIK_TAB && (iGetAsyncKeyState(DIK_RMENU) || iGetAsyncKeyState(DIK_LMENU)))
				b_alt_tab = true;
		}
	}

	// Alt+F4 — hard quit, same deferred events as the DI backend
	if (!b_altF4 && KBState[DIK_F4] && (KBState[DIK_RMENU] || KBState[DIK_LMENU]))
	{
		b_altF4 = TRUE;
		Engine.Event.Defer("KERNEL:disconnect");
		Engine.Event.Defer("KERNEL:quit");
	}

	if (b_altF4)
		return;

	if (Device.dwPrecacheFrame == 0)
	{
		for (u32 i = 0; i < COUNT_KB_BUTTONS; i++)
			if (KBState[i])
				cbStack.back()->IR_OnKeyboardHold(i);
	}

	if (b_alt_tab)
	{
		const BOOL fullscreen = (g_screenmode == 2);
		if (fullscreen)
		{
			if (SDL_Window* win = xr_sdl_window_of(Device.m_hWnd))
				SDL_MinimizeWindow(win);
		}
	}
}

//-----------------------------------------------------------------------------

void CInput::MouseUpdate()
{
	pump_sdl_events();

	if (Device.dwPrecacheFrame)
	{
		// DI backend consumed-and-dropped buffered data during precache
		g_pending_mouse.clear();
		return;
	}

	BOOL mouse_prev[COUNT_MOUSE_BUTTONS];
	for (u32 b = 0; b < COUNT_MOUSE_BUTTONS; b++)
		mouse_prev[b] = mouseState[b];

	const bool bSwitched = !!GetSystemMetrics(SM_SWAPBUTTON);

	offs[0] = offs[1] = offs[2] = 0;
	bool had_events = false;

	while (!g_pending_mouse.empty())
	{
		XrRawInputEvent ev = g_pending_mouse.front();
		g_pending_mouse.pop_front();
		had_events = true;

		switch (ev.type)
		{
		case XrRawInputEvent::MouseMotion:
			offs[0] += ev.a;
			offs[1] += ev.b;
			timeStamp[0] = timeStamp[1] = dwCurTime;
			break;
		case XrRawInputEvent::MouseWheel:
			offs[2] += ev.a * WHEEL_DELTA;
			timeStamp[2] = dwCurTime;
			// DirectInput surfaced wheel ticks as button 3/4 press+release
			// pairs; synthesize the same so wheel-bound actions fire.
			if (ev.a > 0)
			{
				mouseState[3] = TRUE;
				cbStack.back()->IR_OnMousePress(3);
				mouseState[3] = FALSE;
				cbStack.back()->IR_OnMouseRelease(3);
			}
			else if (ev.a < 0)
			{
				mouseState[4] = TRUE;
				cbStack.back()->IR_OnMousePress(4);
				mouseState[4] = FALSE;
				cbStack.back()->IR_OnMouseRelease(4);
			}
			break;
		case XrRawInputEvent::MouseButtonDown:
		case XrRawInputEvent::MouseButtonUp:
		{
			int btn = sdl_button_to_engine(ev.a);
			if (btn < 0 || btn >= COUNT_MOUSE_BUTTONS)
				break;
			const bool down = ev.type == XrRawInputEvent::MouseButtonDown;
			mouseState[btn] = down ? TRUE : FALSE;
			int dispatch = btn;
			if (bSwitched && (btn == 0 || btn == 1))
				dispatch = btn == 0 ? 1 : 0;
			if (down)
				cbStack.back()->IR_OnMousePress(dispatch);
			else
				cbStack.back()->IR_OnMouseRelease(dispatch);
			break;
		}
		default: break;
		}
	}

	for (u32 b = 0; b < COUNT_MOUSE_BUTTONS; b++)
		if (mouseState[b] && mouse_prev[b])
		{
			int dispatch = (int)b;
			if (bSwitched && (b == 0 || b == 1))
				dispatch = b == 0 ? 1 : 0;
			cbStack.back()->IR_OnMouseHold(dispatch);
		}

	if (had_events)
	{
		// p4: mouse-to-menu path probe
		static int s_p4_mm = 0;
		if (s_p4_mm < 5 && (offs[0] || offs[1]))
			Msg("* p4: MouseUpdate dispatch move dx=%d dy=%d cbStack=%zu", offs[0], offs[1],
				cbStack.size());
		if (offs[0] || offs[1])
			s_p4_mm++;
		if (offs[0] || offs[1])
			cbStack.back()->IR_OnMouseMove(offs[0], offs[1]);
		if (offs[2])
			cbStack.back()->IR_OnMouseWheel(offs[2]);
	}
	else
	{
		if (timeStamp[1] && ((dwCurTime - timeStamp[1]) >= mouse_property.mouse_dt))
			cbStack.back()->IR_OnMouseStop(DIMOFS_Y, timeStamp[1] = 0);
		if (timeStamp[0] && ((dwCurTime - timeStamp[0]) >= mouse_property.mouse_dt))
			cbStack.back()->IR_OnMouseStop(DIMOFS_X, timeStamp[0] = 0);
	}
}

//-----------------------------------------------------------------------------
void CInput::iCapture(IInputReceiver* p)
{
	VERIFY(p);
	MouseUpdate();
	KeyUpdate();

	// change focus
	if (!cbStack.empty())
		cbStack.back()->IR_OnDeactivate();
	cbStack.push_back(p);
	cbStack.back()->IR_OnActivate();

	// prepare for _new_ controller
	ZeroMemory(timeStamp, sizeof(timeStamp));
	ZeroMemory(timeSave, sizeof(timeStamp));
	ZeroMemory(offs, sizeof(offs));
}

void CInput::iRelease(IInputReceiver* p)
{
	if (p == cbStack.back())
	{
		cbStack.back()->IR_OnDeactivate();
		cbStack.pop_back();
		IInputReceiver* ir = cbStack.back();
		ir->IR_OnActivate();
	}
	else
	{
		// we are not topmost receiver, so remove the nearest one
		u32 cnt = (u32)cbStack.size();
		for (; cnt > 0; --cnt)
			if (cbStack[cnt - 1] == p)
			{
				xr_vector<IInputReceiver*>::iterator it = cbStack.begin();
				std::advance(it, cnt - 1);
				cbStack.erase(it);
				break;
			}
	}
}

//-----------------------------------------------------------------------------

void CInput::OnAppActivate(void)
{
	if (CurrentIR())
		CurrentIR()->IR_OnActivate();

	SetAllAcquire(true);
	ZeroMemory(mouseState, sizeof(mouseState));
	ZeroMemory(KBState, sizeof(KBState));
	ZeroMemory(timeStamp, sizeof(timeStamp));
	ZeroMemory(timeSave, sizeof(timeStamp));
	ZeroMemory(offs, sizeof(offs));
}

void CInput::OnAppDeactivate(void)
{
	if (CurrentIR())
		CurrentIR()->IR_OnDeactivate();

	SetAllAcquire(false);
	ZeroMemory(mouseState, sizeof(mouseState));
	ZeroMemory(KBState, sizeof(KBState));
	ZeroMemory(timeStamp, sizeof(timeStamp));
	ZeroMemory(timeSave, sizeof(timeStamp));
	ZeroMemory(offs, sizeof(offs));
}

void CInput::DeactivateSoft()
{
	if (CurrentIR())
		CurrentIR()->IR_OnDeactivate();

	ZeroMemory(mouseState, sizeof(mouseState));
	ZeroMemory(KBState, sizeof(KBState));
	ZeroMemory(timeStamp, sizeof(timeStamp));
	ZeroMemory(timeSave, sizeof(timeStamp));
	ZeroMemory(offs, sizeof(offs));
}

void CInput::OnFrame(void)
{
	RDEVICE.Statistic->Input.Begin();
	dwCurTime = RDEVICE.TimerAsync_MMT();
	KeyUpdate();
	MouseUpdate();
	ControllerUpdate();
	RDEVICE.Statistic->Input.End();
}

IInputReceiver* CInput::CurrentIR()
{
	if (cbStack.size())
		return cbStack.back();
	else
		return NULL;
}

//-----------------------------------------------------------------------------
// Acquisition — DirectInput cooperative levels map onto SDL window grab +
// relative mouse mode.

static SDL_Window* input_window()
{
	SDL_Window* win = xr_sdl_window_of(Device.m_hWnd);
	if (!win)
		win = SDL_GL_GetCurrentWindow();
	return win;
}

void CInput::unacquire()
{
	if (SDL_Window* win = input_window())
	{
		SDL_SetWindowGrab(win, SDL_FALSE);
		SDL_SetRelativeMouseMode(SDL_FALSE);
	}
}

void CInput::acquire(const bool& exclusive)
{
	if (SDL_Window* win = input_window())
	{
		SDL_SetWindowInputFocus(win);
		SDL_SetWindowGrab(win, exclusive ? SDL_TRUE : SDL_FALSE);
		SDL_SetRelativeMouseMode(exclusive ? SDL_TRUE : SDL_FALSE);
	}
}

void CInput::exclusive_mode(const bool& exclusive)
{
	g_exclusive = exclusive;
	unacquire();
	acquire(exclusive);
}

bool CInput::get_exclusive_mode()
{
	return g_exclusive;
}

void CInput::SetAllAcquire(BOOL bAcquire)
{
	if (bAcquire)
		acquire(g_exclusive);
	else
		unacquire();
}

void CInput::SetMouseAcquire(BOOL bAcquire)
{
	if (bAcquire)
		acquire(g_exclusive);
	else
		unacquire();
}

void CInput::SetKBDAcquire(BOOL /*bAcquire*/)
{
	// keyboard is always available through the SDL event pump
}

//-----------------------------------------------------------------------------

BOOL CInput::iGetAsyncKeyState(int dik)
{
	if (dik < COUNT_KB_BUTTONS)
		return !!KBState[dik];

	const int MOUSE_1 = (0xED + 100);
	const int MOUSE_8 = (0xED + 107);
	if (dik >= MOUSE_1 && dik <= MOUSE_8)
		return iGetAsyncBtnState(dik - MOUSE_1);
	return FALSE; // unknown key ???
}

BOOL CInput::iGetAsyncBtnState(int btn)
{
	if ((btn == 0 || btn == 1) && !!GetSystemMetrics(SM_SWAPBUTTON))
		btn = btn == 0 ? 1 : 0;
	return !!mouseState[btn];
}

//-----------------------------------------------------------------------------
// Physical key names (DIPROP_KEYNAME equivalent): single characters for
// printable keys (the line editor derives typed characters from these),
// full names otherwise. Unknown keys report failure (callers fall back).

bool CInput::get_dik_name(int dik, LPSTR dest_str, int dest_sz)
{
	static const struct
	{
		int dik;
		const char* name;
	} names[] = {
		{DIK_ESCAPE, "ESCAPE"}, {DIK_1, "1"}, {DIK_2, "2"}, {DIK_3, "3"}, {DIK_4, "4"},
		{DIK_5, "5"}, {DIK_6, "6"}, {DIK_7, "7"}, {DIK_8, "8"}, {DIK_9, "9"}, {DIK_0, "0"},
		{DIK_MINUS, "-"}, {DIK_EQUALS, "="}, {DIK_BACK, "BACKSPACE"}, {DIK_TAB, "TAB"},
		{DIK_Q, "Q"}, {DIK_W, "W"}, {DIK_E, "E"}, {DIK_R, "R"}, {DIK_T, "T"}, {DIK_Y, "Y"},
		{DIK_U, "U"}, {DIK_I, "I"}, {DIK_O, "O"}, {DIK_P, "P"},
		{DIK_LBRACKET, "["}, {DIK_RBRACKET, "]"}, {DIK_RETURN, "RETURN"},
		{DIK_A, "A"}, {DIK_S, "S"}, {DIK_D, "D"}, {DIK_F, "F"}, {DIK_G, "G"}, {DIK_H, "H"},
		{DIK_J, "J"}, {DIK_K, "K"}, {DIK_L, "L"},
		{DIK_SEMICOLON, ";"}, {DIK_APOSTROPHE, "'"}, {DIK_GRAVE, "`"},
		{DIK_BACKSLASH, "\\"},
		{DIK_Z, "Z"}, {DIK_X, "X"}, {DIK_C, "C"}, {DIK_V, "V"}, {DIK_B, "B"}, {DIK_N, "N"},
		{DIK_M, "M"},
		{DIK_COMMA, ","}, {DIK_PERIOD, "."}, {DIK_SLASH, "/"},
		{DIK_SPACE, "SPACE"}, {DIK_CAPITAL, "CAPSLOCK"},
		{DIK_F1, "F1"}, {DIK_F2, "F2"}, {DIK_F3, "F3"}, {DIK_F4, "F4"}, {DIK_F5, "F5"},
		{DIK_F6, "F6"}, {DIK_F7, "F7"}, {DIK_F8, "F8"}, {DIK_F9, "F9"}, {DIK_F10, "F10"},
		{DIK_F11, "F11"}, {DIK_F12, "F12"},
		{DIK_NUMLOCK, "NUMLOCK"}, {DIK_SCROLL, "SCROLLLOCK"}, {DIK_SNAPSHOT, "PRINTSCREEN"},
		{DIK_PAUSE, "PAUSE"},
		{DIK_HOME, "HOME"}, {DIK_UP, "UP"}, {DIK_PRIOR, "PAGEUP"}, {DIK_LEFT, "LEFT"},
		{DIK_RIGHT, "RIGHT"}, {DIK_END, "END"}, {DIK_DOWN, "DOWN"}, {DIK_NEXT, "PAGEDOWN"},
		{DIK_INSERT, "INSERT"}, {DIK_DELETE, "DELETE"},
		{DIK_LCONTROL, "LCONTROL"}, {DIK_RCONTROL, "RCONTROL"},
		{DIK_LSHIFT, "LSHIFT"}, {DIK_RSHIFT, "RSHIFT"},
		{DIK_LMENU, "LMENU"}, {DIK_RMENU, "RMENU"},
		{DIK_LWIN, "LWIN"}, {DIK_RWIN, "RWIN"}, {DIK_APPS, "APPS"},
		{DIK_MULTIPLY, "*"}, {DIK_ADD, "+"}, {DIK_SUBTRACT, "-"}, {DIK_DECIMAL, "."},
		{DIK_DIVIDE, "/"},
		{DIK_NUMPAD0, "NUMPAD0"}, {DIK_NUMPAD1, "NUMPAD1"}, {DIK_NUMPAD2, "NUMPAD2"},
		{DIK_NUMPAD3, "NUMPAD3"}, {DIK_NUMPAD4, "NUMPAD4"}, {DIK_NUMPAD5, "NUMPAD5"},
		{DIK_NUMPAD6, "NUMPAD6"}, {DIK_NUMPAD7, "NUMPAD7"}, {DIK_NUMPAD8, "NUMPAD8"},
		{DIK_NUMPAD9, "NUMPAD9"}, {DIK_NUMPADENTER, "NUMPADENTER"},
	};

	for (const auto& n : names)
	{
		if (n.dik == dik)
		{
			strncpy_s(dest_str, dest_sz, n.name, _TRUNCATE);
			return true;
		}
	}
	dest_str[0] = 0;
	return false;
}

//-----------------------------------------------------------------------------

void CInput::feedback(u16 s1, u16 s2, float time)
{
	stop_vibration_time = RDEVICE.fTimeGlobal + time;
	xr_controller_rumble(s1, s2, time);
}
