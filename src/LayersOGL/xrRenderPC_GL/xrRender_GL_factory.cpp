// xrRender_GL_factory.cpp — monolith dxRenderFactory bridge (p4).
//
// xrEngine/xrGame's FactoryPtr<T> templates call methods on the GLOBAL
// dxRenderFactory class (Layers/xrRender/dxRenderFactory.h) and bind the
// xrAPI RenderFactory global to &RenderFactoryImpl. The staged OpenXRay GL
// renderer keeps its own factory in xray::render::render_gl, so this file
// exposes the boundary class and delegates to it. Classes that only existed
// for the monolith DX11 renderer get GL adapters or no-op stubs:
//   RenderDeviceRender   -> GLRenderDeviceRender (delegates to IRender_interface)
//   ApplicationRender    -> invisible-sky stub (monolith DX11 sky not ported yet)
//   ConsoleRender        -> no-op (dev console stays text/log-only)
//   StatsRender          -> no-op (F3 stats overlay not ported)
//   EnvDescriptorMixerRender -> no-op (the engine's CEnvDescriptorMixer does
//                            its own blending; the renderer-side mixer is unused)

#include "stdafx.h"

// Staged internal factory: render_gl::dxRenderFactory + its RenderFactoryImpl.
#include "Layers/xrRender/dxRenderFactory.h"

// Monolith boundary class (global namespace). The relative include bypasses
// the identically named staged header; the redefinition of the
// RENDER_FACTORY_DECLARE macro is harmless (same shape, warnings suppressed).
#include "../../Layers/xrRender/dxRenderFactory.h"

#include "Include/xrAPI/xrAPI.h"
#include "Include/xrRender/ApplicationRender.h"
#include "Include/xrRender/ConsoleRender.h"
#include "Include/xrRender/StatsRender.h"
#include "Include/xrRender/RenderDeviceRender.h"
#include "Include/xrRender/EnvironmentRender.h"

namespace xray::render::render_gl
{
	extern CRender RImplementation;
} // namespace xray::render::render_gl

// The boundary factory instance the engine's FactoryPtr binds to
// (extern-declared by the monolith dxRenderFactory.h above).
dxRenderFactory RenderFactoryImpl;

// ---------------------------------------------------------------------------
// Delegation to the staged GL factory
// ---------------------------------------------------------------------------
#define GL_FACTORY_DELEGATE(Class)                                                    \
	I##Class* dxRenderFactory::Create##Class()                                        \
	{                                                                                 \
		return render_gl::RenderFactoryImpl.Create##Class();                          \
	}                                                                                 \
	void dxRenderFactory::Destroy##Class(I##Class* pObject)                           \
	{                                                                                 \
		render_gl::RenderFactoryImpl.Destroy##Class(pObject);                         \
	}

GL_FACTORY_DELEGATE(UISequenceVideoItem)
GL_FACTORY_DELEGATE(UIShader)
GL_FACTORY_DELEGATE(StatGraphRender)
GL_FACTORY_DELEGATE(WallMarkArray)
GL_FACTORY_DELEGATE(FlareRender)
GL_FACTORY_DELEGATE(ThunderboltRender)
GL_FACTORY_DELEGATE(ThunderboltDescRender)
GL_FACTORY_DELEGATE(RainRender)
GL_FACTORY_DELEGATE(LensFlareRender)
GL_FACTORY_DELEGATE(EnvironmentRender)
GL_FACTORY_DELEGATE(EnvDescriptorRender)
GL_FACTORY_DELEGATE(FontRender)

// ---------------------------------------------------------------------------
// IRenderDeviceRender adapter (the monolith's CRender_Device equivalent)
// ---------------------------------------------------------------------------
namespace
{
	class GLRenderDeviceRender : public IRenderDeviceRender
	{
		// p4: OpenXRay merged the device surface into IRender; delegate.
		IRender_interface* R() const { return ::Render; }

	public:
		void Copy(IRenderDeviceRender&) override {}

		// Gamma
		void setGamma(float fGamma) override { R()->setGamma(fGamma); }
		void setBrightness(float fGamma) override { R()->setBrightness(fGamma); }
		void setContrast(float fGamma) override { R()->setContrast(fGamma); }
		void updateGamma() override { R()->updateGamma(); }

		// Destroy / lifecycle
		void OnDeviceDestroy(BOOL bKeepTextures) override { R()->OnDeviceDestroy(bKeepTextures != FALSE); }
		void ValidateHW() override {}
		void DestroyHW() override {}
		void Reset(HWND hWnd, u32& dwWidth, u32& dwHeight, float& fWidth_2, float& fHeight_2) override
		{
			R()->Reset(reinterpret_cast<SDL_Window*>(hWnd), dwWidth, dwHeight, fWidth_2, fHeight_2);
		}

		// Init
		void SetupStates() override { R()->SetupStates(); }
		void OnDeviceCreate(LPCSTR shName) override { R()->OnDeviceCreate(shName); }
		void Create(HWND hWnd, u32& dwWidth, u32& dwHeight, float& fWidth_2, float& fHeight_2, bool) override
		{
			R()->Create(reinterpret_cast<SDL_Window*>(hWnd), dwWidth, dwHeight, fWidth_2, fHeight_2);
		}
		void SetupGPU(BOOL bForceGPU_SW, BOOL bForceGPU_NonPure, BOOL bForceGPU_REF) override
		{
			// p4: GL has no REF/hardware rasterizer choice; the staged glHW code
			// fills HW.Caps from the GL context on device create.
			(void)bForceGPU_SW;
			(void)bForceGPU_NonPure;
			(void)bForceGPU_REF;
		}

		// Overdraw
		void overdrawBegin() override { R()->overdrawBegin(); }
		void overdrawEnd() override { R()->overdrawEnd(); }

		// Resources
		void DeferredLoad(BOOL E) override { R()->DeferredLoad(E != FALSE); }
		void ResourcesDeferredUpload() override { R()->ResourcesDeferredUpload(); }
		void ResourcesDeferredUnload() override { R()->ResourcesDeferredUnload(); }
		void ResourcesGetMemoryUsage(u32& m_base, u32& c_base, u32& m_lmaps, u32& c_lmaps) override
		{
			R()->ResourcesGetMemoryUsage(m_base, c_base, m_lmaps, c_lmaps);
		}
		void ResourcesDestroyNecessaryTextures() override { R()->ResourcesDestroyNecessaryTextures(); }
		void ResourcesStoreNecessaryTextures() override { R()->ResourcesStoreNecessaryTextures(); }
		void ResourcesDumpMemoryUsage() override { R()->ResourcesDumpMemoryUsage(); }
		void ResourcesPrefetchCreateTexture(LPCSTR name) override
		{
			// p4: monolith prefetch (level editor path); unused at runtime.
			(void)name;
		}

		// HWSupport
		bool HWSupportsShaderYUV2RGB() override { return true; } // GL3: shader-based YUV is always available

		// Device state
		DeviceState GetDeviceState() override
		{
			switch (::Render ? ::Render->GetDeviceState() : ::DeviceState::Normal)
			{
			case ::DeviceState::Lost: return dsLost;
			case ::DeviceState::NeedReset: return dsNeedReset;
			default: return dsOK;
			}
		}
		BOOL GetForceGPU_REF() override { return FALSE; }
		u32 GetCacheStatPolys() override { return 0; }
		void Begin() override { R()->Begin(); }
		void Clear() override { R()->Clear(); }
		void End() override { R()->End(); }
		void ClearTarget() override { R()->ClearTarget(); }
		void SetCacheXform(Fmatrix& mView, Fmatrix& mProject) override { R()->SetCacheXform(mView, mProject); }
		void OnAssetsChanged() override { R()->OnAssetsChanged(); }
	};

	// Invisible sky (monolith DX11 CApplicationRender not ported yet — p4 t2).
	class CNullApplicationRender : public IApplicationRender
	{
	public:
		void Copy(IApplicationRender&) override {}
		void LoadBegin() override {}
		void destroy_loading_shaders() override {}
		void setLevelLogo(LPCSTR pszLogoName) override { (void)pszLogoName; }
		void load_draw_internal(CApplication& owner) override { (void)owner; }
		void KillHW() override {}
	};

	// Dev-console text overlay (Anomaly console remains usable via logs).
	class CNullConsoleRender : public IConsoleRender
	{
	public:
		void Copy(IConsoleRender&) override {}
		void OnRender(bool bGame) override { (void)bGame; }
	};

	// F3 stats overlay.
	class CNullStatsRender : public IStatsRender
	{
	public:
		void Copy(IStatsRender&) override {}
		void OutData1(CGameFont& F) override { (void)F; }
		void OutData2(CGameFont& F) override { (void)F; }
		void OutData3(CGameFont& F) override { (void)F; }
		void OutData4(CGameFont& F) override { (void)F; }
		void GuardVerts(CGameFont& F) override { (void)F; }
		void GuardDrawCalls(CGameFont& F) override { (void)F; }
		void SetDrawParams(IRenderDeviceRender* pRender) override { (void)pRender; }
	};

	// Renderer-side env mixer: the engine's CEnvDescriptorMixer blends on its
	// own; this interface is not exercised by Anomaly code paths.
	class CNullEnvDescriptorMixerRender : public IEnvDescriptorMixerRender
	{
	public:
		void Copy(IEnvDescriptorMixerRender&) override {}
		void Destroy() override {}
		void Clear() override {}
		void lerp(IEnvDescriptorRender* inA, IEnvDescriptorRender* inB) override
		{
			(void)inA;
			(void)inB;
		}
	};
} // namespace

// ---------------------------------------------------------------------------
// Boundary-only classes
// ---------------------------------------------------------------------------
IRenderDeviceRender* dxRenderFactory::CreateRenderDeviceRender()
{
	return new GLRenderDeviceRender();
}

void dxRenderFactory::DestroyRenderDeviceRender(IRenderDeviceRender* pObject)
{
	delete pObject;
}

IApplicationRender* dxRenderFactory::CreateApplicationRender()
{
	return new CNullApplicationRender();
}

void dxRenderFactory::DestroyApplicationRender(IApplicationRender* pObject)
{
	delete pObject;
}

IConsoleRender* dxRenderFactory::CreateConsoleRender()
{
	return new CNullConsoleRender();
}

void dxRenderFactory::DestroyConsoleRender(IConsoleRender* pObject)
{
	delete pObject;
}

IStatsRender* dxRenderFactory::CreateStatsRender()
{
	return new CNullStatsRender();
}

void dxRenderFactory::DestroyStatsRender(IStatsRender* pObject)
{
	delete pObject;
}

IEnvDescriptorMixerRender* dxRenderFactory::CreateEnvDescriptorMixerRender()
{
	return new CNullEnvDescriptorMixerRender();
}

void dxRenderFactory::DestroyEnvDescriptorMixerRender(IEnvDescriptorMixerRender* pObject)
{
	delete pObject;
}

#ifdef DEBUG
// ObjectSpaceRender (DEBUG-only editor gizmos) — monolith renders it in xrRender
// itself; not requested outside DEBUG builds.
IObjectSpaceRender* dxRenderFactory::CreateObjectSpaceRender()
{
	Msg("! xrRender_GL: ObjectSpaceRender requested (not ported)");
	return nullptr;
}

void dxRenderFactory::DestroyObjectSpaceRender(IObjectSpaceRender* pObject)
{
	(void)pObject;
}
#endif
