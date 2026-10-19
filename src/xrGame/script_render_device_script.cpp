////////////////////////////////////////////////////////////////////////////
//	Module 		: script_render_device_script.cpp
//	Created 	: 28.06.2004
//  Modified 	: 28.06.2004
//	Author		: Dmitriy Iassenev
//	Description : Script render device script export
////////////////////////////////////////////////////////////////////////////

#include "pch_script.h"
#include "script_render_device.h"

using namespace luabind;

bool is_device_paused(CRenderDevice* d)
{
	return !!Device.Paused();
}

void set_device_paused(CRenderDevice* d, bool b)
{
	Device.Pause(b, TRUE, FALSE, "set_device_paused_script");
}

extern ENGINE_API BOOL g_appLoaded;

bool is_app_ready()
{
	return !!g_appLoaded;
}

u32 time_global(const CRenderDevice* self)
{
	THROW(self);
	return (self->dwTimeGlobal);
}

u32 time_continual(const CRenderDevice* self)
{
	THROW(self);
	return (self->dwTimeContinual);
}

#pragma optimize("s",on)
// p4: MSVC typed `&CRenderDevice::member` as CRenderDevice::* even for
// inherited (CRenderDeviceData) members; clang uses the standard
// CRenderDeviceData::*, which luabind's def_readonly rejects. Getter
// properties restore the same observable binding.
namespace rd_getters {
	u32 width(const CRenderDevice& d) { return d.dwWidth; }
	u32 height(const CRenderDevice& d) { return d.dwHeight; }
	u32 time_delta(const CRenderDevice& d) { return d.dwTimeDelta; }
	float f_time_delta(const CRenderDevice& d) { return d.fTimeDelta; }
	const Fvector& cam_pos(const CRenderDevice& d) { return d.vCameraPosition; }
	const Fvector& cam_dir(const CRenderDevice& d) { return d.vCameraDirection; }
	const Fvector& cam_top(const CRenderDevice& d) { return d.vCameraTop; }
	const Fvector& cam_right(const CRenderDevice& d) { return d.vCameraRight; }
	float fov(const CRenderDevice& d) { return d.fFOV; }
	float aspect_ratio(const CRenderDevice& d) { return d.fASPECT; }
	u32 precache_frame(const CRenderDevice& d) { return d.dwPrecacheFrame; }
	u32 frame(const CRenderDevice& d) { return d.dwFrame; }
} // namespace rd_getters

template<> void class_exporter<CRenderDevice>::script_register(lua_State* L)
{
	module(L)
	[
		class_<CRenderDevice>("render_device")
		.property("width", &rd_getters::width)
		.property("height", &rd_getters::height)
		.property("time_delta", &rd_getters::time_delta)
		.property("f_time_delta", &rd_getters::f_time_delta)
		.property("cam_pos", &rd_getters::cam_pos)
		.property("cam_dir", &rd_getters::cam_dir)
		.property("cam_top", &rd_getters::cam_top)
		.property("cam_right", &rd_getters::cam_right)
		//			.def_readonly("view",					&CRenderDevice::mView)
		//			.def_readonly("projection",				&CRenderDevice::mProject)
		//			.def_readonly("full_transform",			&CRenderDevice::mFullTransform)
		.property("fov", &rd_getters::fov)
		.property("aspect_ratio", &rd_getters::aspect_ratio)
		.def("time_global", &time_global)
		.def("time_continual", &time_continual)
		.property("precache_frame", &rd_getters::precache_frame)
		.property("frame", &rd_getters::frame)
		.def("is_paused", &is_device_paused)
		.def("pause", &set_device_paused),
		def("app_ready", &is_app_ready)
	];
}
