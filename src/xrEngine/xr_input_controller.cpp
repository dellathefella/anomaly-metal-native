// xr_input_controller.cpp — SDL2 gamepad backend for CInput (t4).
//
// Anomaly's input layer (engine + xrGame + UI) is entirely keyboard/mouse
// (DIK codes and mouse buttons). Rather than teaching every receiver about
// gamepad events, this backend synthesizes keyboard/mouse actions from the
// controller, so all existing keybindings and menu navigation work with a
// pad, and users can rebind actions to the underlying keys.
//
// Features: hotplug, stick deadzones (inner/outer), right-stick look with
// sensitivity + cubic falloff, trigger-as-mouse-button thresholds, rumble.
// Tunables mirror OpenXRay's cvar names; they are exposed to the console via
// xrGame's config layer and can be overridden from the game ini section
// [controller_options].

#include "stdafx.h"
#pragma hdrstop

#include "xr_input.h"
#include "IInputReceiver.h"
#include "device.h"

#include <SDL.h>
#include <deque>
#include <cmath>

#ifndef WHEEL_DELTA
#define WHEEL_DELTA 120
#endif

// from xr_input_sdl.cpp
extern float stop_vibration_time;
std::deque<XrRawInputEvent>& xr_pending_controller_events();

ENGINE_API float psControllerStickSensX = 0.12f;
ENGINE_API float psControllerStickSensY = 0.7f;
ENGINE_API float psControllerStickSensScale = 1.f;
ENGINE_API float psControllerStickInnerDeadZone = 0.15f;
ENGINE_API float psControllerStickOuterDeadZone = 0.96f;
ENGINE_API float psControllerSensorSens = 0.5f; // reserved (gyro)
ENGINE_API int psControllerEnabled = 1;
ENGINE_API int psControllerVibration = 1;

namespace
{

struct SDLGameControllerDeleter
{
	void operator()(SDL_GameController* c) const
	{
		if (c)
			SDL_GameControllerClose(c);
	}
};

SDL_GameController* g_pad = nullptr; // owned (hotplug open/close)
int g_pad_instance = -1;
bool g_pad_buttons[SDL_CONTROLLER_BUTTON_MAX] = {};
s16 g_pad_axes[SDL_CONTROLLER_AXIS_MAX] = {};
bool g_cfg_loaded = false;

// Synthesized action for a pad button
enum SynKind
{
	SynNone = 0,
	SynKey, // keyboard DIK press/release/hold
	SynMouseButton, // mouse button press/release/hold
	SynWheelUp, // wheel tick on press
	SynWheelDown,
};

struct SynAction
{
	SynKind kind;
	int code; // DIK or mouse button index
};

// Default mapping (Xbox layout). A/B/X/Y drive menus (Enter/Escape) and the
// most common gameplay keys; LB/RB are weapon-switch wheel ticks; the
// triggers are fire/aim (mouse 0/1) via the axis path below.
const SynAction kButtonMap[SDL_CONTROLLER_BUTTON_MAX] = {
	/* A             */ { SynKey, DIK_RETURN },
	/* B             */ { SynKey, DIK_ESCAPE },
	/* X             */ { SynKey, DIK_I }, // inventory
	/* Y             */ { SynKey, DIK_M }, // map
	/* BACK          */ { SynKey, DIK_TAB },
	/* GUIDE         */ { SynNone, 0 },
	/* START         */ { SynKey, DIK_ESCAPE }, // pause menu
	/* LEFTSTICK     */ { SynKey, DIK_LSHIFT }, // sprint
	/* RIGHTSTICK    */ { SynKey, DIK_LCONTROL }, // crouch
	/* LEFTSHOULDER  */ { SynWheelUp, 0 },
	/* RIGHTSHOULDER */ { SynWheelDown, 0 },
	/* DPAD_UP       */ { SynKey, DIK_UP },
	/* DPAD_DOWN     */ { SynKey, DIK_DOWN },
	/* DPAD_LEFT     */ { SynKey, DIK_LEFT },
	/* DPAD_RIGHT    */ { SynKey, DIK_RIGHT },
	/* MISC1         */ { SynNone, 0 },
	/* PADDLE1..4    */ { SynNone, 0 }, { SynNone, 0 }, { SynNone, 0 }, { SynNone, 0 },
	/* TOUCHPAD      */ { SynNone, 0 },
};

// Left stick -> movement keys
const int kStickUpKey = DIK_W;
const int kStickDownKey = DIK_S;
const int kStickLeftKey = DIK_A;
const int kStickRightKey = DIK_D;
// trigger thresholds (SDL axis range -32768..32767)
const int kTriggerPress = 4000;
const int kTriggerRelease = 1500;

bool g_trigger_l_down = false;
bool g_trigger_r_down = false;
bool g_wasd[4] = {}; // W A S D synthesized state

void load_config()
{
	if (g_cfg_loaded)
		return;
	g_cfg_loaded = true;
	if (!pSettings)
		return;
	const LPCSTR sec = "controller_options";
	if (!pSettings->section_exist(sec))
		return;
	if (pSettings->line_exist(sec, "enabled"))
		psControllerEnabled = pSettings->r_bool(sec, "enabled") ? 1 : 0;
	if (pSettings->line_exist(sec, "stick_sens_x"))
		psControllerStickSensX = pSettings->r_float(sec, "stick_sens_x");
	if (pSettings->line_exist(sec, "stick_sens_y"))
		psControllerStickSensY = pSettings->r_float(sec, "stick_sens_y");
	if (pSettings->line_exist(sec, "deadzone_inner"))
		psControllerStickInnerDeadZone = pSettings->r_float(sec, "deadzone_inner");
	if (pSettings->line_exist(sec, "deadzone_outer"))
		psControllerStickOuterDeadZone = pSettings->r_float(sec, "deadzone_outer");
	if (pSettings->line_exist(sec, "vibration"))
		psControllerVibration = pSettings->r_bool(sec, "vibration") ? 1 : 0;
}

void open_controller(int joystick_index)
{
	if (g_pad)
		return; // single pad model
	if (!SDL_IsGameController(joystick_index))
		return;
	g_pad = SDL_GameControllerOpen(joystick_index);
	if (g_pad)
	{
		g_pad_instance = SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pad));
		Msg("* controller: connected '%s'", SDL_GameControllerName(g_pad));
	}
	else
		Msg("! controller: failed to open (index %d): %s", joystick_index, SDL_GetError());
}

void close_controller(int instance_id)
{
	if (!g_pad)
		return;
	if (g_pad_instance != instance_id)
		return;
	Msg("* controller: disconnected");
	SDL_GameControllerClose(g_pad);
	g_pad = nullptr;
	g_pad_instance = -1;
	memset(g_pad_buttons, 0, sizeof(g_pad_buttons));
	memset(g_pad_axes, 0, sizeof(g_pad_axes));
	g_trigger_l_down = g_trigger_r_down = false;
	g_wasd[0] = g_wasd[1] = g_wasd[2] = g_wasd[3] = false;
}

// normalized magnitude beyond the inner deadzone, remapped between the
// inner and outer edges (symmetric around zero)
float stick_response(float v)
{
	const float inner = psControllerStickInnerDeadZone;
	const float outer = psControllerStickOuterDeadZone;
	const float a = std::fabs(v);
	if (a <= inner)
		return 0.f;
	const float r = a >= outer ? 1.f : (a - inner) / (outer - inner);
	return v > 0.f ? r : -r;
}

float stick_axis(int axis) { return g_pad_axes[axis] / 32767.0f; }

void syn_key(IInputReceiver* ir, int dik, bool down)
{
	if (dik < 0 || dik >= CInput::COUNT_KB_BUTTONS)
		return;
	if (down)
		ir->IR_OnKeyboardPress(dik);
	else
		ir->IR_OnKeyboardRelease(dik);
}

} // namespace

void xr_controller_rumble(u16 low, u16 high, float seconds)
{
	if (!psControllerVibration || !g_pad)
		return;
	const Uint32 ms = seconds > 0.f ? (Uint32)(seconds * 1000.f) : 150u;
	SDL_GameControllerRumble(g_pad, low, high, ms);
}

void CInput::ControllerUpdate()
{
	load_config();

	std::deque<XrRawInputEvent>& q = xr_pending_controller_events();

	if (!psControllerEnabled)
	{
		q.clear();
		return;
	}

	IInputReceiver* ir = CurrentIR();
	if (!ir)
		return;

	// drain raw queue into pad state + dispatch press/release
	while (!q.empty())
	{
		XrRawInputEvent ev = q.front();
		q.pop_front();

		switch (ev.type)
		{
		case XrRawInputEvent::ControllerDeviceAdded: open_controller(ev.a); continue;
		case XrRawInputEvent::ControllerDeviceRemoved: close_controller(ev.a); continue;
		default: break;
		}

		if (!g_pad)
			continue;
		const int instance = (ev.type == XrRawInputEvent::ControllerAxis) ? ev.c : ev.b;
		if (g_pad_instance >= 0 && instance != g_pad_instance)
			continue; // ignore secondary pads

		if (ev.type == XrRawInputEvent::ControllerButtonDown ||
		    ev.type == XrRawInputEvent::ControllerButtonUp)
		{
			const int btn = ev.a;
			if (btn < 0 || btn >= SDL_CONTROLLER_BUTTON_MAX)
				continue;
			const bool down = ev.type == XrRawInputEvent::ControllerButtonDown;
			g_pad_buttons[btn] = down;

			const SynAction& act = kButtonMap[btn];
			switch (act.kind)
			{
			case SynKey:
				if (down)
					ir->IR_OnKeyboardPress(act.code);
				else
					ir->IR_OnKeyboardRelease(act.code);
				break;
			case SynMouseButton:
				if (down)
					ir->IR_OnMousePress(act.code);
				else
					ir->IR_OnMouseRelease(act.code);
				break;
			case SynWheelUp:
				if (down)
				{
					ir->IR_OnMouseWheel(WHEEL_DELTA);
					ir->IR_OnMousePress(3);
					ir->IR_OnMouseRelease(3);
				}
				break;
			case SynWheelDown:
				if (down)
				{
					ir->IR_OnMouseWheel(-WHEEL_DELTA);
					ir->IR_OnMousePress(4);
					ir->IR_OnMouseRelease(4);
				}
				break;
			case SynNone: break;
			}
		}
		else if (ev.type == XrRawInputEvent::ControllerAxis)
		{
			const int axis = ev.a;
			if (axis < 0 || axis >= SDL_CONTROLLER_AXIS_MAX)
				continue;
			g_pad_axes[axis] = (s16)ev.b;
		}
	}

	if (!g_pad)
		return;

	// rumble expiry (mirrors the DI backend's stop_vibration_time logic)
	if (Device.fTimeGlobal > stop_vibration_time)
	{
		stop_vibration_time = flt_max;
		xr_controller_rumble(0, 0, 0.f);
	}

	if (Device.dwPrecacheFrame)
		return;

	// --- left stick -> WASD (held-key semantics via press/release edges) ---
	const float lx = stick_response(stick_axis(SDL_CONTROLLER_AXIS_LEFTX));
	const float ly = stick_response(stick_axis(SDL_CONTROLLER_AXIS_LEFTY));

	const bool want[4] = {
		ly < -0.01f, // forward
		lx < -0.01f, // left
		ly > 0.01f, // back
		lx > 0.01f, // right
	};
	const int keys[4] = { kStickUpKey, kStickLeftKey, kStickDownKey, kStickRightKey };
	for (int i = 0; i < 4; i++)
	{
		if (want[i] && !g_wasd[i])
		{
			g_wasd[i] = true;
			syn_key(ir, keys[i], true);
		}
		else if (!want[i] && g_wasd[i])
		{
			g_wasd[i] = false;
			syn_key(ir, keys[i], false);
		}
		else if (want[i])
		{
			ir->IR_OnKeyboardHold(keys[i]);
		}
	}

	// --- triggers -> mouse buttons (edge detected on axis motion) ---------
	const float lt = g_pad_axes[SDL_CONTROLLER_AXIS_TRIGGERLEFT] / 32767.0f;
	const float rt = g_pad_axes[SDL_CONTROLLER_AXIS_TRIGGERRIGHT] / 32767.0f;
	const bool lt_down = g_trigger_l_down ? (lt * 32767.0f > kTriggerRelease)
	                                      : (lt * 32767.0f >= kTriggerPress);
	const bool rt_down = g_trigger_r_down ? (rt * 32767.0f > kTriggerRelease)
	                                      : (rt * 32767.0f >= kTriggerPress);
	if (lt_down != g_trigger_l_down)
	{
		g_trigger_l_down = lt_down;
		if (lt_down)
			ir->IR_OnMousePress(1);
		else
			ir->IR_OnMouseRelease(1);
	}
	if (rt_down != g_trigger_r_down)
	{
		g_trigger_r_down = rt_down;
		if (rt_down)
			ir->IR_OnMousePress(0);
		else
			ir->IR_OnMouseRelease(0);
	}

	// --- right stick -> mouse look (cubic curve, sens like OpenXRay) ------
	float rx = stick_axis(SDL_CONTROLLER_AXIS_RIGHTX);
	float ry = stick_axis(SDL_CONTROLLER_AXIS_RIGHTY);
	const float rlen = std::sqrt(rx * rx + ry * ry);
	if (rlen > psControllerStickInnerDeadZone)
	{
		// deadzone remap + clamp to outer
		float scale = (rlen - psControllerStickInnerDeadZone) /
		              (psControllerStickOuterDeadZone - psControllerStickInnerDeadZone);
		if (scale > 1.f)
			scale = 1.f;
		rx = (rx / rlen) * scale;
		ry = (ry / rlen) * scale;

		const float sens_scale = psControllerStickSensScale * psMouseSens;
		// cubic falloff for fine aiming near center
		const float dx = rx * std::fabs(rx) * psControllerStickSensX * sens_scale * 100.0f;
		const float dy = ry * std::fabs(ry) * psControllerStickSensY * sens_scale * 100.0f;
		const int idx = (int)dx, idy = (int)dy;
		if (idx || idy)
			ir->IR_OnMouseMove(idx, idy);
	}
}
