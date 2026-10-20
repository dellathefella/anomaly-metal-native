// Rain.h: interface for the CRain class.
//
//////////////////////////////////////////////////////////////////////

#ifndef RainH
#define RainH
#pragma once

// p4: the ported GL renderer (LayersOGL) declares the same class inside
// xray::render::render_gl; grant it the same friend access as the DX11 one.
namespace xray::render::render_gl { class dxRainRender; }
namespace xray::render::render_metal { class dxRainRender; } // p5

#include "../xrcdb/xr_collide_defs.h"

//refs
class ENGINE_API IRender_DetailModel;

#include "../Include/xrRender/FactoryPtr.h"
#include "../Include/xrRender/RainRender.h"

//
class ENGINE_API CEffect_Rain
{
	friend class dxRainRender;
	friend class xray::render::render_gl::dxRainRender; // p4
	friend class xray::render::render_metal::dxRainRender; // p5
private:
	struct Item
	{
		Fvector P;
		Fvector Phit;
		Fvector D;
		float fSpeed;
		u32 dwTime_Life;
		u32 dwTime_Hit;
		u32 uv_set;

		void invalidate()
		{
			dwTime_Life = 0;
		}
	};

	struct Particle
	{
		Particle *next, *prev;
		Fmatrix mXForm;
		Fsphere bounds;
		float time;
	};

	enum States
	{
		stIdle = 0,
		stWorking
	};

private:
	// Visualization (rain) and (drops)
	FactoryPtr<IRainRender> m_pRender;
	/*
	// Visualization (rain)
	ref_shader SH_Rain;
	ref_geom hGeom_Rain;

	// Visualization (drops)
	IRender_DetailModel* DM_Drop;
	ref_geom hGeom_Drops;
	*/

	// Data and logic
	xr_vector<Item> items;
	States state;

	// Particles
	xr_vector<Particle> particle_pool;
	Particle* particle_active;
	Particle* particle_idle;

	// Sounds
	ref_sound snd_Ambient;
	float rain_volume;

	// Utilities
	void p_create();
	void p_destroy();

	void p_remove(Particle* P, Particle*& LST);
	void p_insert(Particle* P, Particle*& LST);
	int p_size(Particle* LST);
	Particle* p_allocate();
	void p_free(Particle* P);

	// Some methods
	void Born(Item& dest, float radius);
	void Hit(Fvector& pos);
	BOOL RayPick(const Fvector& s, const Fvector& d, float& range, collide::rq_target tgt);
	void RenewItem(Item& dest, float height, BOOL bHit);
public:
	CEffect_Rain();
	~CEffect_Rain();

	void Render();
	void OnFrame();

	void InvalidateState()
	{
		if (state != stIdle) snd_Ambient.stop();
		rain_volume = 0.0f;
		state = stIdle;
	}

	float GetRainVolume() { return rain_volume; }
};

#endif //RainH
