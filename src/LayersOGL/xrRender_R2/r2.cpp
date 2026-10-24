#include "stdafx.h"

#include "xrCore/PostProcess/PPInfo.hpp"

#include "xrEngine/IGame_Persistent.h"
#include "xrEngine/GameFont.h"
#include "xrEngine/PerformanceAlert.hpp"

#include "Layers/xrRender/FBasicVisual.h"
#include "Layers/xrRender/SkeletonCustom.h"
#include "Layers/xrRender/dxWallMarkArray.h"
#include "Layers/xrRender/dxUIShader.h"

#if defined(USE_DX11)
#include "Layers/xrRenderDX11/3DFluid/dx113DFluidManager.h"
#endif

namespace xray::render::RENDER_NAMESPACE
{
CRender RImplementation;

// p6 band-hunt: published by CRender::OnCameraUpdated, dumped from the Metal
// pass manager's endEncoder (a proven-live path) via xrMetalDumpFrustum.
// If the stamp advances across dumps, OnCameraUpdated runs; a frozen stamp
// means ViewBase is stale — itself the smoking gun for a culled wedge.
void* g_xrViewBasePub = nullptr;
volatile u32 g_xrViewBaseStamp = 0;

//////////////////////////////////////////////////////////////////////////
class CGlow : public IRender_Glow
{
public:
    bool bActive;

public:
    CGlow() : bActive(false) {}
    virtual void set_active(bool b) { bActive = b; }
    virtual bool get_active() { return bActive; }
    virtual void set_position(const Fvector& P) {}
    virtual void set_direction(const Fvector& D) {}
    virtual void set_radius(float R) {}
    virtual void set_texture(LPCSTR name) {}
    virtual void set_color(const Fcolor& C) {}
    virtual void set_color(float r, float g, float b) {}
};

float r_dtex_range = 50.f;
//////////////////////////////////////////////////////////////////////////
ShaderElement* CRender::rimp_select_sh_dynamic(dxRender_Visual* pVisual, float cdist_sq, u32 phase)
{
    int id = SE_R2_SHADOW;
    if (CRender::PHASE_NORMAL == phase)
    {
        id = ((_sqrt(cdist_sq) - pVisual->vis.sphere.R) < r_dtex_range) ? SE_R2_NORMAL_HQ : SE_R2_NORMAL_LQ;
    }
    return pVisual->shader->E[id]._get();
}
//////////////////////////////////////////////////////////////////////////
ShaderElement* CRender::rimp_select_sh_static(dxRender_Visual* pVisual, float cdist_sq, u32 phase)
{
    if (!pVisual->shader)
        return nullptr;
    int id = SE_R2_SHADOW;
    if (CRender::PHASE_NORMAL == phase)
    {
        id = ((_sqrt(cdist_sq) - pVisual->vis.sphere.R) < r_dtex_range) ? SE_R2_NORMAL_HQ : SE_R2_NORMAL_LQ;
    }
    return pVisual->shader->E[id]._get();
}
static class cl_parallax : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
        float h = ps_r2_df_parallax_h;
        cmd_list.set_c(C, h, -h / 2.f, 1.f / r_dtex_range, 1.f / r_dtex_range);
    }
} binder_parallax;

#if defined(USE_DX11)
static class cl_LOD : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override { cmd_list.LOD.set_LOD(C); }
} binder_LOD;
#endif

static class cl_pos_decompress_params : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
#if defined(USE_DX11) || defined(USE_METAL)
        const float VertTan = -1.0f * tanf(deg2rad(Device.fFOV / 2.0f));
        const float HorzTan = -VertTan / Device.fASPECT;
#elif defined(USE_OGL)
        const float VertTan = tanf(deg2rad(Device.fFOV / 2.0f));
        const float HorzTan = VertTan / Device.fASPECT;
#else
#   error No graphics API selected or enabled!
#endif
        cmd_list.set_c(
            C, HorzTan, VertTan, (2.0f * HorzTan) / (float)Device.dwWidth, (2.0f * VertTan) / (float)Device.dwHeight);
    }
} binder_pos_decompress_params;

static class cl_pos_decompress_params2 : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
        cmd_list.set_c(C, (float)Device.dwWidth, (float)Device.dwHeight, 1.0f / (float)Device.dwWidth,
            1.0f / (float)Device.dwHeight);
    }
} binder_pos_decompress_params2;

static class cl_water_intensity : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
        const auto& env = *g_pGamePersistent->Environment().CurrentEnv;
        const float fValue = env.m_fWaterIntensity;
        cmd_list.set_c(C, fValue, fValue, fValue, 0.f);
    }
} binder_water_intensity;

static class cl_sun_shafts_intensity : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
        const auto& env = *g_pGamePersistent->Environment().CurrentEnv;
        const float fValue = env.m_fSunShaftsIntensity;
        cmd_list.set_c(C, fValue, fValue, fValue, 0.f);
    }
} binder_sun_shafts_intensity;

static class cl_alpha_ref : public R_constant_setup
{
    void setup(CBackend& cmd_list, R_constant* C) override
    {
        // TODO: OGL: Implement AlphaRef.
#   if defined(USE_DX11)
        cmd_list.StateManager.BindAlphaRef(C);
#   endif
    }
} binder_alpha_ref;

// Defined in ResourceManager.cpp
IReader* open_shader(pcstr shader);

// Check shadow cascades type (old SOC/CS or new COP)
static bool must_enable_old_cascades()
{
    bool oldCascades = false;
#if RENDER != R_R1
    {
        IReader* accumSunNear = open_shader("accum_sun_near.ps");
        R_ASSERT3(accumSunNear, "Can't open shader", "accum_sun_near.ps");
        do
        {
            xr_string str(static_cast<cpcstr>(accumSunNear->pointer()), accumSunNear->length());

            pcstr begin = strstr(str.c_str(), "float4");
            if (!begin)
                break;

            begin = strstr(begin, "main");
            if (!begin)
                break;

            cpcstr end = strstr(begin, "SV_Target");
            if (!end)
                break;

            str.assign(begin, end);
            cpcstr ptr = str.data();

            if (strstr(ptr, "v2p_TL2uv"))
            {
                oldCascades = true;
            }
            else if (strstr(ptr, "v2p_volume"))
            {
                oldCascades = false;
            }
        } while (false);
        FS.r_close(accumSunNear);
    }
#endif
    return oldCascades;
}

// Returns true if compute shaders for HDAO Ultra exist
[[maybe_unused]] static bool ssao_hdao_cs_shaders_exist()
{
    IReader* hdao_cs      = open_shader("ssao_hdao.cs");
    IReader* hdao_cs_msaa = open_shader("ssao_hdao_msaa.cs");

    const bool exist      = hdao_cs && hdao_cs_msaa;

    FS.r_close(hdao_cs);
    FS.r_close(hdao_cs_msaa);

    return exist;
}

//////////////////////////////////////////////////////////////////////////
// Just two static storage
void CRender::create()
{
    ZoneScoped;

    Device.seqFrame.Add(this, REG_PRIORITY_HIGH + 0x12345678);

    m_skinning = -1;
    m_MSAASample = -1;

    // hardware
    o.mrt = (HW.Caps.raster.dwMRT_count >= 3);
    o.mrtmixdepth = (HW.Caps.raster.b_MRT_mixdepth);

    // Check for NULL render target support
    o.nullrt = false;

    /*
    if (o.nullrt)		{
    Msg				("* NULLRT supported and used");
    };
    */
    if (o.nullrt)
    {
        Msg("* NULLRT supported");

        //.	    _tzset			();
        //.		??? _strdate	( date, 128 );	???
        //.		??? if (date < 22-march-07)
        if (0)
        {
            u32 device_id = HW.Caps.id_device;
            bool disable_nullrt = false;
            switch (device_id)
            {
            case 0x190:
            case 0x191:
            case 0x192:
            case 0x193:
            case 0x194:
            case 0x197:
            case 0x19D:
            case 0x19E:
            {
                disable_nullrt = true; // G80
                break;
            }
            case 0x400:
            case 0x401:
            case 0x402:
            case 0x403:
            case 0x404:
            case 0x405:
            case 0x40E:
            case 0x40F:
            {
                disable_nullrt = true; // G84
                break;
            }
            case 0x420:
            case 0x421:
            case 0x422:
            case 0x423:
            case 0x424:
            case 0x42D:
            case 0x42E:
            case 0x42F:
            {
                disable_nullrt = true; // G86
                break;
            }
            }
            if (disable_nullrt)
                o.nullrt = false;
        }
        if (o.nullrt)
            Msg("* ...and used");
    }

    // SMAP / DST
    o.HW_smap_FETCH4 = FALSE;
    o.HW_smap = true;
    o.HW_smap_PCF = o.HW_smap;

    if (o.HW_smap)
    {
#if defined(USE_DX11)
        //	For ATI it's much faster on DX11 to use D32F format
        if (HW.Caps.id_vendor == 0x1002)
            o.HW_smap_FORMAT = D3DFMT_D32F_LOCKABLE;
        else
#endif
        {
            o.HW_smap_FORMAT = D3DFMT_D24X8;
        }
        Msg("* HWDST/PCF supported and used");
    }

    o.fp16_filter = true;
    o.fp16_blend = true;

    // emulate ATI-R4xx series
    if (strstr(Core.Params, "-r4xx"))
    {
        o.mrtmixdepth = FALSE;
        o.HW_smap = FALSE;
        o.HW_smap_PCF = FALSE;
        o.fp16_filter = FALSE;
        o.fp16_blend = FALSE;
    }

    VERIFY2(o.mrt && (HW.Caps.raster.dwInstructions >= 256), "Hardware doesn't meet minimum feature-level");
    if (o.mrtmixdepth)
        o.albedo_wo = FALSE;
    else if (o.fp16_blend)
        o.albedo_wo = FALSE;
    else
        o.albedo_wo = TRUE;

    // nvstencil on NV40 and up
    // nvstencil should be enabled only for GF 6xxx and GF 7xxx
    // if hardware support early stencil (>= GF 8xxx) stencil reset trick only
    // slows down.
    o.nvstencil = FALSE;
    if (strstr(Core.Params, "-nonvs"))
        o.nvstencil = FALSE;

    // nv-dbt
    o.nvdbt = false;

    if (o.nvdbt)
        Msg("* NV-DBT supported and used");

    o.ffp = false;

    // options (smap-pool-size)
    if (strstr(Core.Params, "-smap1024"))
        o.smapsize = 1024;
    else if (strstr(Core.Params, "-smap1536"))
        o.smapsize = 1536;
    else if (strstr(Core.Params, "-smap2048"))
        o.smapsize = 2048;
    else if (strstr(Core.Params, "-smap2560"))
        o.smapsize = 2560;
    else if (strstr(Core.Params, "-smap3072"))
        o.smapsize = 3072;
    else if (strstr(Core.Params, "-smap4096"))
        o.smapsize = 4096;
    else if (strstr(Core.Params, "-smap8192"))
        o.smapsize = 8192;
    else
        o.smapsize = ps_r2_smapsize;

    // gloss
    cpcstr g = strstr(Core.Params, "-gloss ");
    o.forcegloss = g ? TRUE : FALSE;
    if (g)
    {
        o.forcegloss_v = float(atoi(g + xr_strlen("-gloss "))) / 255.f;
    }

    // options
    o.bug = (strstr(Core.Params, "-bug")) ? TRUE : FALSE;
    o.sunfilter = (strstr(Core.Params, "-sunfilter")) ? TRUE : FALSE;
    //.	o.sunstatic			= (strstr(Core.Params,"-sunstatic"))?	TRUE	:FALSE	;
    o.sunstatic = ps_r2_sun_static;
    o.advancedpp = ps_r2_advanced_pp;
#if defined(USE_DX11)
    o.volumetricfog = ps_r2_ls_flags.test(R3FLAG_VOLUMETRIC_SMOKE);
#elif defined(USE_OGL)
    // TODO: OGL: temporary disabled, need to fix it
    o.volumetricfog = false;
#endif
    o.sjitter = (strstr(Core.Params, "-sjitter")) ? TRUE : FALSE;
    o.depth16 = (strstr(Core.Params, "-depth16")) ? TRUE : FALSE;
    o.noshadows = (strstr(Core.Params, "-noshadows")) ? TRUE : FALSE;
    o.Tshadows = (strstr(Core.Params, "-tsh")) ? TRUE : FALSE;
    o.oldshadowcascades = must_enable_old_cascades() || ps_r2_ls_flags_ext.test(R2FLAGEXT_SUN_OLD);
    o.mblur = (strstr(Core.Params, "-mblur")) ? TRUE : FALSE;
    o.distortion_enabled = (strstr(Core.Params, "-nodistort")) ? FALSE : TRUE;
    o.distortion = o.distortion_enabled;
    o.disasm = (strstr(Core.Params, "-disasm")) ? TRUE : FALSE;
    o.forceskinw = (strstr(Core.Params, "-skinw")) ? TRUE : FALSE;

    o.ssao_blur_on = ps_r2_ls_flags_ext.test(R2FLAGEXT_SSAO_BLUR) && (ps_r_ssao != 0);
    o.ssao_opt_data = ps_r2_ls_flags_ext.test(R2FLAGEXT_SSAO_OPT_DATA) && (ps_r_ssao != 0);
    o.ssao_half_data = ps_r2_ls_flags_ext.test(R2FLAGEXT_SSAO_HALF_DATA) && o.ssao_opt_data && (ps_r_ssao != 0);
#if defined(USE_DX11)
    o.ssao_hdao = ps_r2_ls_flags_ext.test(R2FLAGEXT_SSAO_HDAO) && (ps_r_ssao != 0);
    o.ssao_ultra = HW.ComputeShadersSupported && ssao_hdao_cs_shaders_exist();
    o.ssao_hbao = !o.ssao_hdao && ps_r2_ls_flags_ext.test(R2FLAGEXT_SSAO_HBAO) && (ps_r_ssao != 0);
#elif defined(USE_OGL) || defined(USE_METAL)
    // TODO: OGL/Metal: temporary disabled HBAO/HDAO, need to fix it
    o.ssao_hbao = false;
    o.ssao_hdao = false;
#else
#   error No graphics API selected or enabled!
#endif

    //	TODO: fix hbao shader to allow to perform per-subsample effect!
    if (o.ssao_hbao && HW.Caps.id_vendor == 0x1002)
        o.hbao_vectorized = true;
    else
        o.hbao_vectorized = false;

#if defined(USE_DX11)
    o.dx11_sm4_1 = ps_r2_ls_flags.test((u32)R3FLAG_USE_DX10_1);
    o.dx11_sm4_1 = o.dx11_sm4_1 && (HW.FeatureLevel >= D3D_FEATURE_LEVEL_10_1);
#elif defined(USE_OGL) || defined(USE_METAL)
    o.dx11_sm4_1 = true;
#else
#   error No graphics API selected or enabled!
#endif

    //	MSAA option dependencies
#if defined(USE_DX11)
    o.msaa = !!ps_r3_msaa;
    o.msaa_samples = (1 << ps_r3_msaa);

    o.msaa_opt = ps_r2_ls_flags.test(R3FLAG_MSAA_OPT);
    o.msaa_opt = o.msaa_opt && o.msaa && (HW.FeatureLevel >= D3D_FEATURE_LEVEL_10_1) ||
        o.msaa && (HW.FeatureLevel >= D3D_FEATURE_LEVEL_11_0);

    // o.msaa_hybrid	= ps_r2_ls_flags.test(R3FLAG_MSAA_HYBRID);
    o.msaa_hybrid = ps_r2_ls_flags.test((u32)R3FLAG_USE_DX10_1);
    o.msaa_hybrid &= !o.msaa_opt && o.msaa && (HW.FeatureLevel >= D3D_FEATURE_LEVEL_10_1);
#elif defined(USE_OGL) || defined(USE_METAL)
    // TODO: OGL/Metal: temporary disabled, need to fix it
    o.msaa = false;
    o.msaa_samples = 0;
    o.msaa_opt = o.msaa;
    o.msaa_hybrid = false;
#else
#   error No graphics API selected or enabled!
#endif
    //	Allow alpha test MSAA for DX10.0

    // o.msaa_alphatest= ps_r2_ls_flags.test((u32)R3FLAG_MSAA_ALPHATEST);
    // o.msaa_alphatest= o.msaa_alphatest && o.msaa;

    // o.msaa_alphatest_atoc= (o.msaa_alphatest && !o.msaa_opt && !o.msaa_hybrid);

    o.msaa_alphatest = 0;
    if (o.msaa)
    {
        if (o.msaa_opt || o.msaa_hybrid)
        {
            if (ps_r3_msaa_atest == 1)
                o.msaa_alphatest = MSAA_ATEST_DX10_1_ATOC;
            else if (ps_r3_msaa_atest == 2)
                o.msaa_alphatest = MSAA_ATEST_DX10_1_NATIVE;
        }
        else
        {
            if (ps_r3_msaa_atest)
                o.msaa_alphatest = MSAA_ATEST_DX10_0_ATOC;
        }
    }

    // p5 launch199: forced OFF on Metal — the shipped DXBC r2 shaders were
    // compiled WITHOUT GBUFFER_OPTIMIZATION (combine_1 samples a real
    // s_normal RT). With the packed 2-attachment gbuffer, rt_Normal was
    // never created/written: combine_1's hemi (ambient) read black → the
    // whole scene sat unlit.
    o.gbuffer_opt = false;

    o.minmax_sm = ps_r3_minmax_sm;
    o.minmax_sm_screenarea_threshold = 1600 * 1200;

#if defined(USE_DX11)
    o.tessellation =
        HW.FeatureLevel >= D3D_FEATURE_LEVEL_11_0 && ps_r2_ls_flags_ext.test(R2FLAGEXT_ENABLE_TESSELLATION);
    o.support_rt_arrays = true;
#else
    o.support_rt_arrays = false;
#endif

    if (o.minmax_sm == MMSM_AUTODETECT)
    {
        o.minmax_sm = MMSM_OFF;

        //	AMD device
        if (HW.Caps.id_vendor == 0x1002)
        {
            if (ps_r_sun_quality >= 3)
                o.minmax_sm = MMSM_AUTO;
            else if (ps_r_sun_shafts >= 2)
            {
                o.minmax_sm = MMSM_AUTODETECT;
                //	Check resolution in runtime in use_minmax_sm_this_frame
                o.minmax_sm_screenarea_threshold = 1600 * 1200;
            }
        }

        //	NVidia boards
        if (HW.Caps.id_vendor == 0x10DE)
        {
            if (ps_r_sun_shafts >= 2)
            {
                o.minmax_sm = MMSM_AUTODETECT;
                //	Check resolution in runtime in use_minmax_sm_this_frame
                o.minmax_sm_screenarea_threshold = 1280 * 1024;
            }
        }
    }

    // constants
    Resources->RegisterConstantSetup("parallax", &binder_parallax);
    Resources->RegisterConstantSetup("water_intensity", &binder_water_intensity);
    Resources->RegisterConstantSetup("sun_shafts_intensity", &binder_sun_shafts_intensity);
    Resources->RegisterConstantSetup("pos_decompression_params", &binder_pos_decompress_params);
    Resources->RegisterConstantSetup("pos_decompression_params2", &binder_pos_decompress_params2);
    Resources->RegisterConstantSetup("m_AlphaRef", &binder_alpha_ref);
#if defined(USE_DX11)
    Resources->RegisterConstantSetup("triLOD", &binder_LOD);
#endif

    Target = xr_new<CRenderTarget>(); // Main target

    Models = xr_new<CModelPool>();
    PSLibrary.OnCreate();
    HWOCC.occq_create(occq_size);

    rmNormal(RCache);
    q_sync_point.Create();

    //	TODO: OGL: Implement FluidManager.
#if defined(USE_DX11)
    FluidManager.Initialize(70, 70, 70);
    //	FluidManager.Initialize( 100, 100, 100 );
    FluidManager.SetScreenSize(Device.dwWidth, Device.dwHeight);
#endif
}

void CRender::destroy()
{
#if defined(USE_DX11)
    FluidManager.Destroy();
#endif
    q_sync_point.Destroy();
    HWOCC.occq_destroy();
    xr_delete(Models);
    xr_delete(Target);
    PSLibrary.OnDestroy();
    Device.seqFrame.Remove(this);
}

void CRender::reset_begin()
{
    ZoneScoped;
    // Wait for tasks to be done
    r_main.sync();
    r_sun.sync();
    r_sun_old.sync();
#if RENDER != R_R2
    r_rain.sync();
#endif

    Resources->reset_begin();

    // Update incremental shadowmap-visibility solver
    // BUG-ID: 10646
    {
        u32 it = 0;
        for (it = 0; it < Lights_LastFrame.size(); it++)
        {
            if (0 == Lights_LastFrame[it])
                continue;
            try
            {
                for (int id = 0; id < 3; ++id)
                    Lights_LastFrame[it]->svis[id].resetoccq();
            }
            catch (...)
            {
                Msg("! Failed to flush-OCCq on light [%d] %X", it, *(u32*)(&Lights_LastFrame[it]));
            }
        }
        Lights_LastFrame.clear();
    }

    //AVO: let's reload details while changed details options on vid_restart
    if (b_loaded && (dm_current_size != dm_size ||
        !fsimilar(ps_r__Detail_density, ps_current_detail_density) ||
        !fsimilar(ps_r__Detail_height, ps_current_detail_height)))
    {
        Details->Unload();
        xr_delete(Details);
    }
    //-AVO

    xr_delete(Target);
    HWOCC.occq_destroy();
    q_sync_point.Destroy();
}

void CRender::reset_end()
{
    ZoneScoped;
    q_sync_point.Create();
    HWOCC.occq_create(occq_size);

    Target = xr_new<CRenderTarget>();

    //AVO: let's reload details while changed details options on vid_restart
    if (b_loaded && (dm_current_size != dm_size ||
        !fsimilar(ps_r__Detail_density, ps_current_detail_density) ||
        !fsimilar(ps_r__Detail_height, ps_current_detail_height)))
    {
        Details = xr_new<CDetailManager>();
        Details->Load();
    }
    //-AVO

#if defined(USE_DX11)
    FluidManager.SetScreenSize(Device.dwWidth, Device.dwHeight);
#endif

    cleanup_contexts();

    // Set this flag true to skip the first render frame,
    // that some data is not ready in the first frame (for example device camera position)
    m_bFirstFrameAfterReset = true;
}

void CRender::OnCameraUpdated()
{
    ZoneScoped;

    // Frustum
    ViewBase.CreateFromMatrix(Device.mFullTransform, FRUSTUM_P_LRTB + FRUSTUM_P_FAR);

    // p6 band-hunt: publish ViewBase + stamp for the endEncoder-driven dump
    // (xrMetalDumpFrustum in mtlRuntime). If OnCameraUpdated ever runs, the
    // stamp advances; a frozen stamp across dumps = stale culling frustum.
    {
        extern void* g_xrViewBasePub;
        extern volatile u32 g_xrViewBaseStamp;
        g_xrViewBasePub = &ViewBase;
        g_xrViewBaseStamp = Device.dwFrame;
    }

    // p6 band-hunt: XR_METAL_FRUSPROBE=1 — dump the culling frustum planes in
    // game. A right-plane whose screen-space boundary predicts the band edge
    // (x~2300 @y840, tilted ~1 deg) proves the hole is a CPU cull, not GPU.
    {
        static const bool s_fpen = !!getenv("XR_METAL_FRUSPROBE");
        if (s_fpen && Device.dwFrame > 300 && (Device.dwFrame % 300) == 0)
        {
            char fp[512];
            int off = snprintf(fp, sizeof fp, "* frusprobe:");
            for (int i = 0; i < ViewBase.p_count && off < 300; i++)
                off += snprintf(fp + off, sizeof fp - off, " p%d=(%.4f %.4f %.4f|%.3f)", i,
                                (double)ViewBase.planes[i].n.x, (double)ViewBase.planes[i].n.y,
                                (double)ViewBase.planes[i].n.z, (double)ViewBase.planes[i].d);
            snprintf(fp + off, sizeof fp - off, " aspect=%.4f fov=%.2f", (double)Device.fASPECT,
                     (double)Device.fFOV);
            Msg("%s", fp);
            Msg("* frusprobeM: (%.4f %.4f %.4f %.4f|%.4f %.4f %.4f %.4f|%.4f %.4f %.4f %.4f|"
                "%.4f %.4f %.4f %.4f)",
                (double)Device.mFullTransform._11, (double)Device.mFullTransform._12,
                (double)Device.mFullTransform._13, (double)Device.mFullTransform._14,
                (double)Device.mFullTransform._21, (double)Device.mFullTransform._22,
                (double)Device.mFullTransform._23, (double)Device.mFullTransform._24,
                (double)Device.mFullTransform._31, (double)Device.mFullTransform._32,
                (double)Device.mFullTransform._33, (double)Device.mFullTransform._34,
                (double)Device.mFullTransform._41, (double)Device.mFullTransform._42,
                (double)Device.mFullTransform._43, (double)Device.mFullTransform._44);
        }
    }

    // p4: dev guards its menu-without-level scene here; the monolith engine
    // only drives the renderer when a level is active, so no guard is needed.
    ProcessHOMTask = &HOM.DispatchMTRender();
    if (Details)
        Details->DispatchMTCalc();
}

void CRender::OnFrame()
{
    ZoneScoped;

    Models->DeleteQueue();
    // p4: dev's menu guard removed (see OnCalculate note above).
}

// p4: monolith IRender::getTarget — the engine (CameraManager pp queries,
// GameFont DPI scaling) asks the renderer for its main render target.
IRender_Target* CRender::getTarget()
{
    return Target;
}

#ifdef USE_OGL
IRender::RenderContext CRender::GetCurrentContext() const
{
    return HW.GetCurrentContext();
}

void CRender::MakeContextCurrent(RenderContext context)
{
    R_ASSERT3(HW.MakeContextCurrent(context) == 0,
        "Failed to switch OpenGL context", SDL_GetError());
}
#endif

// Implementation
IRender_ObjectSpecific* CRender::ros_create(IRenderable* parent) { return xr_new<CROS_impl>(); }
void CRender::ros_destroy(IRender_ObjectSpecific*& p) { xr_delete(p); }
IRenderVisual* CRender::model_Create(LPCSTR name, IReader* data) { return Models->Create(name, data); }
IRenderVisual* CRender::model_CreateChild(LPCSTR name, IReader* data) { return Models->CreateChild(name, data); }
IRenderVisual* CRender::model_Duplicate(IRenderVisual* V) { return Models->Instance_Duplicate((dxRender_Visual*)V); }

void CRender::model_Delete(IRenderVisual*& V, BOOL bDiscard)
{
    dxRender_Visual* pVisual = (dxRender_Visual*)V;
    Models->Delete(pVisual, bDiscard);
    V = nullptr;
}

IRender_DetailModel* CRender::model_CreateDM(IReader* F)
{
    CDetail* D = xr_new<CDetail>();
    D->Load(F);
    return D;
}

void CRender::model_Delete(IRender_DetailModel*& F)
{
    if (F)
    {
        CDetail* D = (CDetail*)F;
        D->Unload();
        xr_delete(D);
        F = nullptr;
    }
}

IRenderVisual* CRender::model_CreatePE(LPCSTR name)
{
    PS::CPEDef* SE = PSLibrary.FindPED(name);
    R_ASSERT3(SE, "Particle effect doesn't exist", name);
    return Models->CreatePE(SE);
}

IRenderVisual* CRender::model_CreateParticles(LPCSTR name)
{
    PS::CPEDef* SE = PSLibrary.FindPED(name);
    if (SE)
        return Models->CreatePE(SE);

    PS::CPGDef* SG = PSLibrary.FindPGD(name);
    R_ASSERT3(SG, "Particle effect or group doesn't exist", name);
    return Models->CreatePG(SG);
}
void CRender::models_Prefetch() { Models->Prefetch(); }
void CRender::models_Clear(BOOL b_complete) { Models->ClearPool(b_complete != FALSE); }
ref_shader CRender::getShader(int id)
{
    VERIFY(id < int(Shaders.size()));
    return Shaders[id];
}
IRenderVisual* CRender::getVisual(int id)
{
    VERIFY(id < int(Visuals.size()));
    return Visuals[id];
}

VertexElement* CRender::getVB_Format(int id, bool alternative)
{
    if (alternative)
    {
        VERIFY(id < int(xDC.size()));
        return xDC[id].begin();
    }
    VERIFY(id < int(nDC.size()));
    return nDC[id].begin();
}

VertexStagingBuffer* CRender::getVB(int id, bool alternative)
{
    if (alternative)
    {
        VERIFY(id<int(xVB.size()));
        return &xVB[id];
    }
    VERIFY(id < int(nVB.size()));
    return &nVB[id];
}

IndexStagingBuffer* CRender::getIB(int id, bool alternative)
{
    if (alternative)
    {
        VERIFY(id < int(xIB.size()));
        return &xIB[id];
    }
    VERIFY(id < int(nIB.size()));
    return &nIB[id];
}

FSlideWindowItem* CRender::getSWI(int id)
{
    VERIFY(id < int(SWIs.size()));
    return &SWIs[id];
}

IRender_Light* CRender::light_create() { return Lights.Create(); }
IRender_Glow* CRender::glow_create() { return xr_new<CGlow>(); }
BOOL CRender::occ_visible(vis_data& P) { return HOM.visible(P); }
BOOL CRender::occ_visible(sPoly& P) { return HOM.visible(P); }
BOOL CRender::occ_visible(Fbox& P) { return HOM.visible(P); }

// p4: monolith IRender_interface surface (see r2.h block). HUD path:
// set_Transform/set_Object/set_HUD then add_Visual feeds the dsgraph.
HRESULT CRender::shader_compile(LPCSTR name, DWORD const* pSrcData, UINT SrcDataLen, LPCSTR pFunctionName, LPCSTR pTarget, DWORD Flags, void*& result)
{
    // p4: no engine caller in the monolith tree (dev compiles GLSL through
    // shader_compile above); refuse rather than fake a D3D blob.
    (void)name; (void)pSrcData; (void)SrcDataLen; (void)pFunctionName; (void)pTarget; (void)Flags; (void)result;
    return (HRESULT)0x80004001L; // E_NOTIMPL
}

IRender_Sector* CRender::getSector(int id)
{
    return get_context(R_dsgraph_structure::IMM_CTX_ID).get_sector(id);
}

IRender_Sector* CRender::detectSector(const Fvector& P)
{
    R_dsgraph_structure& ctx = get_context(R_dsgraph_structure::IMM_CTX_ID);
    const IRender_Sector::sector_id_t id = ctx.detect_sector(P);
    return id == IRender_Sector::INVALID_SECTOR_ID ? nullptr : ctx.get_sector(id);
}

void CRender::flush()
{
    get_context(R_dsgraph_structure::IMM_CTX_ID).render_graph(0);
}

void CRender::add_Visual(IRenderVisual* V)
{
    // p4: monolith immediate path — root/transform come from set_Object/
    // set_Transform (HUDManager/player_hud/ParticlesObject).
    if (!V || !m_p4_object || !m_p4_xform)
        return;
    get_context(R_dsgraph_structure::IMM_CTX_ID).add_leafs_dynamic(m_p4_object, (dxRender_Visual*)V, *m_p4_xform);
}

void CRender::add_Geometry(IRenderVisual* V)
{
    (void)V; // p4: no monolith-engine callers (DX11-era full-culling add)
}

void CRender::models_PrefetchOne(LPCSTR name)
{
    (void)name; // p4: deferred-loading hint; GL path loads visuals on demand
}

// p4: light-manager depth phases (monolith DX9 viewport z-range equivalents).
void CRender::rmNear()
{
    m_p4_phase = 1;
#ifdef USE_OGL
    glDepthRange(0.0, 0.02);
#endif
    // p5 Metal: no viewport z-range in Metal — near/far split range emulation
    // via per-phase projection z-remap arrives with the R7 pass (p5 t3).
}

void CRender::rmFar()
{
    m_p4_phase = 2;
#ifdef USE_OGL
    glDepthRange(0.99999, 1.0);
#endif
}

void CRender::rmNormal()
{
    m_p4_phase = 0;
#ifdef USE_OGL
    glDepthRange(0.0, 1.0);
#endif
}

u32 CRender::memory_usage()
{
    u32 m_base = 0, c_base = 0, m_lmaps = 0, c_lmaps = 0;
    ResourcesGetMemoryUsage(m_base, c_base, m_lmaps, c_lmaps);
    return m_base + c_base + m_lmaps + c_lmaps;
}

void CRender::RenderToTarget(RRT target)
{
    // p4: monolith copies the backbuffer into rt_ui_pda/rt_secondVP (DX11
    // D3DXLoadSurfaceFromSurface). GL: blit the default framebuffer into the
    // target's FBO. Bound FBO is restored; depth is not copied (the UI only
    // samples color).
    ref_rt* RT = nullptr;
    switch (target)
    {
    case rtPDA: RT = &Target->rt_ui_pda; break;
    case rtSVP: RT = &Target->rt_secondVP; break;
    default: VERIFY2(false, "None or wrong Target specified"); break;
    }
    if (!RT || !*RT)
        return;

#ifdef USE_OGL
    GLint prev_draw = 0, prev_read = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);

    const u32 w = Device.dwWidth, h = Device.dwHeight;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0); // backbuffer
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (*RT)->pRT);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, prev_read);
#elif defined(USE_METAL)
    // p5 Metal: blit the current swapchain drawable into the target texture.
    MtlBlitFromBackBuffer((*RT)->pRT, Device.dwWidth, Device.dwHeight);
#endif
}
void CRender::add_Visual(u32 context_id, IRenderable* root, IRenderVisual* V, Fmatrix& m)
{
    // TODO: this whole function should be replaced by a list of renderables+xforms returned from `renderable_Render` call
    auto& dsgraph = get_context(context_id);
    dsgraph.add_leafs_dynamic(root, (dxRender_Visual*)V, m);
}
void CRender::add_StaticWallmark(ref_shader& S, const Fvector& P, float s, CDB::TRI* T, Fvector* verts)
{
    VERIFY2(T, "Invalid static wallmark triangle");
    if (T->suppress_wm)
        return;
    VERIFY2(_valid(P) && _valid(s) && verts && (s > EPS_L), "Invalid static wallmark params");
    Wallmarks->AddStaticWallmark(T, verts, P, &*S, s);
}

void CRender::add_StaticWallmark(IWallMarkArray* pArray, const Fvector& P, float s, CDB::TRI* T, Fvector* V,
                                 float ttl, bool ignore_opt, bool random_rotation) // p4: Anomaly args (GL wallmarks ignore)
{
    (void)ttl;
    (void)ignore_opt;
    (void)random_rotation;
    dxWallMarkArray* pWMA = (dxWallMarkArray*)pArray;
    ref_shader* pShader = pWMA->dxGenerateWallmark();
    if (pShader)
        add_StaticWallmark(*pShader, P, s, T, V);
}

void CRender::add_StaticWallmark(const wm_shader& S, const Fvector& P, float s, CDB::TRI* T, Fvector* V)
{
    dxUIShader* pShader = (dxUIShader*)&*S;
    add_StaticWallmark(pShader->hShader, P, s, T, V);
}

void CRender::clear_static_wallmarks() { Wallmarks->clear(); }
void CRender::add_SkeletonWallmark(intrusive_ptr<CSkeletonWallmark> wm) { Wallmarks->AddSkeletonWallmark(wm); }
void CRender::add_SkeletonWallmark(
    const Fmatrix* xf, CKinematics* obj, ref_shader& sh, const Fvector& start, const Fvector& dir, float size)
{
    Wallmarks->AddSkeletonWallmark(xf, obj, sh, start, dir, size);
}
void CRender::add_SkeletonWallmark(
    const Fmatrix* xf, IKinematics* obj, IWallMarkArray* pArray, const Fvector& start, const Fvector& dir, float size,
    float ttl, bool ignore_opt) // p4: Anomaly args (dev GL wallmarks ignore them)
{
    (void)ttl;
    (void)ignore_opt;
    dxWallMarkArray* pWMA = (dxWallMarkArray*)pArray;
    ref_shader* pShader = pWMA->dxGenerateWallmark();
    if (pShader)
        add_SkeletonWallmark(xf, (CKinematics*)obj, *pShader, start, dir, size);
}

void CRender::rmNear(CBackend& cmd_list)
{
    const D3D_VIEWPORT viewport = { 0, 0, Target->get_width(cmd_list), Target->get_height(cmd_list), 0.f, 0.02f };
    cmd_list.SetViewport(viewport);
}

void CRender::rmFar(CBackend& cmd_list)
{
    const D3D_VIEWPORT viewport = { 0, 0, Target->get_width(cmd_list), Target->get_height(cmd_list), 0.99999f, 1.f };
    cmd_list.SetViewport(viewport);
}

void CRender::rmNormal(CBackend& cmd_list)
{
    const D3D_VIEWPORT viewport = { 0, 0, Target->get_width(cmd_list), Target->get_height(cmd_list), 0.f, 1.f };
    cmd_list.SetViewport(viewport);
}

void CRender::SetPostProcessParams(const SPPInfo& ppi)
{
    Target->set_blur(ppi.blur);
    Target->set_gray(ppi.gray);

    Target->set_duality_h(ppi.duality.h);
    Target->set_duality_v(ppi.duality.v);

    Target->set_noise(ppi.noise.intensity);
    Target->set_noise_scale(ppi.noise.grain);
    Target->set_noise_fps(ppi.noise.fps);

    Target->set_color_base(const_cast<SPPInfo::SColor&>(ppi.color_base)); // p4: monolith SColor converters are non-const (read-only)
    Target->set_color_gray(const_cast<SPPInfo::SColor&>(ppi.color_gray));
    Target->set_color_add(const_cast<SPPInfo::SColor&>(ppi.color_add));

    Target->set_cm_imfluence(ppi.cm_influence);
    Target->set_cm_interpolate(ppi.cm_interpolate);
    Target->set_cm_textures(ppi.cm_tex1, ppi.cm_tex2);
}

//////////////////////////////////////////////////////////////////////
// Construction/Destruction
//////////////////////////////////////////////////////////////////////
CRender::CRender()
    : Sectors_xrc("render")
{
}

CRender::~CRender() {}

void CRender::DumpStatistics(CGameFont& font, IPerformanceAlert* alert)
{
    D3DXRenderBase::DumpStatistics(font, alert);
    Stats.FrameEnd();
    font.OutNext("Lights:");
    font.OutNext("- total:      %u", Stats.l_total);
    font.OutNext("- visible:    %u", Stats.l_visible);
    font.OutNext("- shadowed:   %u", Stats.l_shadowed);
    font.OutNext("- unshadowed: %u", Stats.l_unshadowed);
    font.OutNext("Shadow maps:");
    font.OutNext("- used:       %d", Stats.s_used);
    font.OutNext("- merged:     %d", Stats.s_merged - Stats.s_used);
    font.OutNext("- finalclip:  %d", Stats.s_finalclip);
    u32 ict = Stats.ic_total + Stats.ic_culled;
    font.OutNext("ICULL:        %03.1f", 100.f * f32(Stats.ic_culled) / f32(ict ? ict : 1));
    font.OutNext("- visible:    %u", Stats.ic_total);
    font.OutNext("- culled:     %u", Stats.ic_culled);
    Stats.FrameStart();
    HOM.DumpStatistics(font, alert);
    Sectors_xrc.DumpStatistics(font, alert);
}
} // namespace xray::render::RENDER_NAMESPACE

// p6 band-hunt: formatted by the Metal pass manager (endEncoder, proven-live)
// under XR_METAL_FRUSPROBE=1. Writes the published culling ViewBase planes +
// stamp + current mFullTransform into buf; returns bytes written, or -1 with
// "NO PUBLISHED VIEWBASE" when OnCameraUpdated never ran (stale culling).
extern "C" int xrMetalFormatFrustum(char* buf, int cap)
{
    using namespace xray::render::RENDER_NAMESPACE;
    const CFrustum* vb = static_cast<const CFrustum*>(g_xrViewBasePub);
    int off = 0;
    if (!vb)
    {
        off = snprintf(buf, (size_t)cap, "* frusprobe: NO PUBLISHED VIEWBASE "
                       "(OnCameraUpdated never ran)");
        return -1;
    }
    off = snprintf(buf, (size_t)cap, "* frusprobe: stamp=%u frame=%u",
                   (unsigned)g_xrViewBaseStamp, (unsigned)Device.dwFrame);
    for (int i = 0; i < vb->p_count && off < cap - 64; i++)
        off += snprintf(buf + off, (size_t)(cap - off), " p%d=(%.4f %.4f %.4f|%.3f)", i,
                        (double)vb->planes[i].n.x, (double)vb->planes[i].n.y,
                        (double)vb->planes[i].n.z, (double)vb->planes[i].d);
    off += snprintf(buf + off, (size_t)(cap - off), " aspect=%.4f fov=%.2f",
                    (double)Device.fASPECT, (double)Device.fFOV);
    const Fmatrix& m = Device.mFullTransform;
    off += snprintf(buf + off, (size_t)(cap - off),
                    " M=(%.4f %.4f %.4f %.4f|%.4f %.4f %.4f %.4f|%.4f %.4f %.4f %.4f|"
                    "%.4f %.4f %.4f %.4f)",
                    (double)m._11, (double)m._12, (double)m._13, (double)m._14,
                    (double)m._21, (double)m._22, (double)m._23, (double)m._24,
                    (double)m._31, (double)m._32, (double)m._33, (double)m._34,
                    (double)m._41, (double)m._42, (double)m._43, (double)m._44);
    return off;
}

// p6 band-hunt: WVP-override probe writes the engine's own mFullTransform
// into the ring slot where the VS reads m_WVP (XR_METAL_WVPOVR=1). If the
// world snaps to correct projection, the VS's matrix bytes were wrong.
extern "C" int xrMetalGetFullXform(float* out16)
{
    using namespace xray::render::RENDER_NAMESPACE;
    if (!out16)
        return 0;
    const Fmatrix& m = Device.mFullTransform;
    out16[0] = m._11; out16[1] = m._12; out16[2] = m._13; out16[3] = m._14;
    out16[4] = m._21; out16[5] = m._22; out16[6] = m._23; out16[7] = m._24;
    out16[8] = m._31; out16[9] = m._32; out16[10] = m._33; out16[11] = m._34;
    out16[12] = m._41; out16[13] = m._42; out16[14] = m._43; out16[15] = m._44;
    return 1;
}
