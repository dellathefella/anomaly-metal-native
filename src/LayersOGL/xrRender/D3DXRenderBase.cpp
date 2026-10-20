#include "stdafx.h"

#include "D3DXRenderBase.h"
#include "xrRender_console.h"
#include "D3DUtils.h"
#include "dxUIRender.h"
#include "xrEngine/GameFont.h"
#include "xrEngine/PerformanceAlert.hpp"

#if defined(XR_PLATFORM_WINDOWS) || defined(XR_PLATFORM_LINUX) || defined(XR_PLATFORM_APPLE)
#   ifndef MASTER_GOLD
#       define USE_RENDERDOC
#   endif
#endif

#ifdef USE_RENDERDOC
#include <renderdoc/renderdoc_app.h>
#endif

namespace xray::render::RENDER_NAMESPACE
{
#ifdef USE_RENDERDOC
RENDERDOC_API_1_0_0* g_renderdoc_api;
#endif

void D3DXRenderBase::setGamma(float fGamma)
{
    m_Gamma.Gamma(fGamma);
}

void D3DXRenderBase::setBrightness(float fGamma)
{
    m_Gamma.Brightness(fGamma);
}

void D3DXRenderBase::setContrast(float fGamma)
{
    m_Gamma.Contrast(fGamma);
}

void D3DXRenderBase::updateGamma()
{
    m_Gamma.Update();
}

void D3DXRenderBase::OnDeviceDestroy(bool bKeepTextures)
{
    if (!GEnv.isDedicatedServer)
    {
        UIRenderImpl.DestroyUIGeom();
        DUImpl.OnDeviceDestroy();
        m_PortalFadeGeom.destroy();
        m_PortalFadeShader.destroy();
        m_SelectionShader.destroy();
        m_WireShader.destroy();
    }
    destroy();

    Resources->OnDeviceDestroy(bKeepTextures);
#if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.OnDeviceDestroy();
    }
#else
    RCache.OnDeviceDestroy();
#endif

    // Quad
    QuadIB.Release();

    // streams
    Index.Destroy();
    Vertex.Destroy();
}

void D3DXRenderBase::Destroy()
{
    xr_delete(Resources);
    HW.DestroyDevice();
}

void D3DXRenderBase::Reset(SDL_Window* hWnd, u32& dwWidth, u32& dwHeight, float& fWidth_2, float& fHeight_2)
{
    ZoneScoped;
#if defined(DEBUG) && defined(USE_DX11)
    _SHOW_REF("*ref -CRenderDevice::ResetTotal: DeviceREF:", HW.pDevice);
#endif // DEBUG

    reset_begin();
    Memory.mem_compact();

    HW.Reset();

    std::tie(dwWidth, dwHeight) = HW.GetSurfaceSize();
    fWidth_2 = float(dwWidth / 2);
    fHeight_2 = float(dwHeight / 2);

    Resources->reset_end();

    // create everything, renderer may use
    reset_end();

#ifndef MASTER_GOLD
    Resources->Dump(true);
#endif

#if defined(DEBUG) && defined(USE_DX11)
    _SHOW_REF("*ref +CRenderDevice::ResetTotal: DeviceREF:", HW.pDevice);
#endif
}

void D3DXRenderBase::ObtainRequiredWindowFlags(u32& windowFlags)
{
    HW.SetPrimaryAttributes(windowFlags);
}

void D3DXRenderBase::SetupStates()
{
    HW.Caps.Update();
#if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.SetupStates();
    }
#else
    RCache.SetupStates();
#endif
}

void D3DXRenderBase::OnDeviceCreate(const char* shName)
{
    ZoneScoped;

    // p4: dev registered renderer cvars via its own console object; in the
    // monolith bridge xrRender_initconsole() has no caller — run it first so
    // r2_*/r3_*/ps_* commands exist before configs and xrGame query them.
    xrRender_initconsole();

    // Signal everyone - device created

    // streams
    Vertex.Create();
    Index.Create();

    CreateQuadIB();

#if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.context_id = id;
        contexts_pool[id].cmd_list.OnDeviceCreate();
    }
#else
    RCache.OnDeviceCreate();
#endif
    m_Gamma.Update();
    Resources->OnDeviceCreate(shName);
    Resources->CompatibilityCheck();
    create();
    if (!GEnv.isDedicatedServer)
    {
        m_WireShader.create("editor" DELIMITER "wire");
        m_SelectionShader.create("editor" DELIMITER "selection");
        m_PortalFadeShader.create("portal");
        m_PortalFadeGeom.create(FVF::F_L, RImplementation.Vertex.Buffer(), 0);
        DUImpl.OnDeviceCreate();
        UIRenderImpl.CreateUIGeom();
    }
}

void D3DXRenderBase::Create(SDL_Window* hWnd, u32& dwWidth, u32& dwHeight, float& fWidth_2, float& fHeight_2)
{
    ZoneScoped;

#if defined(USE_RENDERDOC) && defined(USE_DX11)
    if (!g_renderdoc_api)
    {
        HMODULE hModule = GetModuleHandleA("renderdoc.dll");
        if (hModule == 0)
        {
            hModule = LoadLibraryA("renderdoc.dll");
        }

        if (hModule)
        {
            auto const RENDERDOC_GetAPI =
                reinterpret_cast<pRENDERDOC_GetAPI>(GetProcAddress(hModule, "RENDERDOC_GetAPI"));
            auto const Result =
                RENDERDOC_GetAPI(eRENDERDOC_API_Version_1_0_0, reinterpret_cast<void**>(&g_renderdoc_api));
            if (Result == 1)
            {
                g_renderdoc_api->UnloadCrashHandler();

                string_path FolderName;
                FS.update_path(FolderName, "$app_data_root$", "captures\\openxray");
                g_renderdoc_api->SetCaptureFilePathTemplate(FolderName);

                RENDERDOC_InputButton CaptureButton[] = {eRENDERDOC_Key_PrtScrn};
                g_renderdoc_api->SetCaptureKeys(CaptureButton, ARRAYSIZE(CaptureButton));

                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_AllowVSync, 0);
                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_DebugOutputMute, 0);

                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_RefAllResources, 1);
                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_CaptureCallstacks, 1);
                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_VerifyBufferAccess, 1);
                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_APIValidation, 1);
                g_renderdoc_api->SetCaptureOptionU32(eRENDERDOC_Option_CaptureAllCmdLists, 1);
            }
        }
    }
#endif

    HW.CreateDevice(hWnd);

    std::tie(dwWidth, dwHeight) = HW.GetSurfaceSize();

    fWidth_2 = float(dwWidth / 2);
    fHeight_2 = float(dwHeight / 2);
    Resources = xr_new<CResourceManager>();
}

void D3DXRenderBase::overdrawBegin()
{
    RCache.dbg_OverdrawBegin();
}

void D3DXRenderBase::overdrawEnd()
{
    RCache.dbg_OverdrawEnd();
}

void D3DXRenderBase::DeferredLoad(bool E)
{
    Resources->DeferredLoad(E);
}
void D3DXRenderBase::ResourcesDeferredUpload()
{
    Resources->DeferredUpload();
}
void D3DXRenderBase::ResourcesDeferredUnload()
{
    Resources->DeferredUnload();
}
void D3DXRenderBase::ResourcesGetMemoryUsage(u32& m_base, u32& c_base, u32& m_lmaps, u32& c_lmaps)
{
    if (Resources)
        Resources->_GetMemoryUsage(m_base, c_base, m_lmaps, c_lmaps);
}

void D3DXRenderBase::ResourcesStoreNecessaryTextures()
{
    Resources->StoreNecessaryTextures();
}
void D3DXRenderBase::ResourcesDumpMemoryUsage()
{
    Resources->_DumpMemoryUsage();
}
DeviceState D3DXRenderBase::GetDeviceState()
{
    return HW.GetDeviceState();
}

bool D3DXRenderBase::GetForceGPU_REF()
{
    return HW.Caps.bForceGPU_REF;
}
u32 D3DXRenderBase::GetCacheStatPolys()
{
    return RCache.stat.render.polys;
}
void D3DXRenderBase::Begin()
{
    HW.BeginScene();
#if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.OnFrameBegin();
        contexts_pool[id].cmd_list.set_CullMode(CULL_CW);
        contexts_pool[id].cmd_list.set_CullMode(CULL_CCW);
    }
#else
    RCache.OnFrameBegin();
    RCache.set_CullMode(CULL_CW);
    RCache.set_CullMode(CULL_CCW);
#endif
    Vertex.Flush();
    Index.Flush();
    if (HW.Caps.SceneMode)
        overdrawBegin();
}

void D3DXRenderBase::Clear()
{
    RCache.ClearZB(RCache.get_ZB(), 1.0f, 0);
    if (psDeviceFlags.test(rsClearBB))
    {
        RCache.ClearRT(RCache.get_RT(), {}); // black
    }
}

void D3DXRenderBase::End()
{
    if (HW.Caps.SceneMode)
        overdrawEnd();
 #if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.OnFrameEnd();
    }
#else
    RCache.OnFrameEnd();
#endif

    // we're done with rendering
    cleanup_contexts();

    HW.EndScene();
    HW.Present();
}

void D3DXRenderBase::ResourcesDestroyNecessaryTextures()
{
    Resources->DestroyNecessaryTextures();
}
void D3DXRenderBase::ClearTarget()
{
    RCache.ClearRT(RCache.get_RT(), {}); // black
}

void D3DXRenderBase::SetCacheXform(Fmatrix& mView, Fmatrix& mProject)
{
#if RENDER == R_R4
    for (int id = 0; id < R__NUM_CONTEXTS; ++id)
    {
        contexts_pool[id].cmd_list.set_xform_view(mView);
        contexts_pool[id].cmd_list.set_xform_project(mProject);
    }
#else
    RCache.set_xform_view(mView);
    RCache.set_xform_project(mProject);
#endif
}

bool D3DXRenderBase::HWSupportsShaderYUV2RGB()
{
    u32 v_dev = CAP_VERSION(HW.Caps.raster_major, HW.Caps.raster_minor);
    u32 v_need = CAP_VERSION(2, 0);
    return v_dev >= v_need;
}

void D3DXRenderBase::OnAssetsChanged()
{
    ZoneScoped;
    Resources->m_textures_description.UnLoad();
    Resources->m_textures_description.Load();
}

xrImTextureData D3DXRenderBase::GetImGuiTextureId(pcstr texture_name)
{
    const auto texture = Resources->_CreateTexture(texture_name);
    return
    {
        texture->GetImTextureID(),
        {
            (float)texture->get_Width(),
            (float)texture->get_Height()
        }
    };
}

void D3DXRenderBase::DumpStatistics(CGameFont& font, IPerformanceAlert* alert)
{
    // p4 port: dev stats overlay needs IGameFont/IPerformanceAlert (not in the
    // monolith) and is never called from Anomaly; keep only the stats tick.
    BasicStats.FrameEnd();
    (void)font;
    (void)alert;
}
} // namespace xray::render::RENDER_NAMESPACE
