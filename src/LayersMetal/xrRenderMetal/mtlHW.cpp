// mtlHW.cpp — CHW on the Metal substrate (mirror of glHW.cpp). No ObjC here:
// device/swapchain access goes through the plain-C++ facades (mtl_device.h),
// so this TU compiles against the engine stdafx like the GL device layer.
#include "stdafx.h"
#pragma hdrstop

#include "xrEngine/XR_IOConsole.h"
#include "mtlRuntime.h"

// p4 rule: xrEngine globals live at C++ global scope (unmangled on Mach-O).
extern xr_token* vid_mode_token;   // defined in xrEngine/xr_ioc_cmd.cpp
extern xr_token* vid_quality_token;

namespace xray::render::RENDER_NAMESPACE
{
// Same SDL display-mode enumeration as the GL path (settings dialog +
// game.get_resolutions()).
static void fill_vid_mode_list_sdl(SDL_Window* win)
{
    if (vid_mode_token != nullptr)
        return;

    xr_vector<LPCSTR> _tmp;
    const int nd = SDL_GetNumDisplayModes(0);
    for (int i = 0; i < nd; ++i)
    {
        SDL_DisplayMode dm{};
        if (SDL_GetDisplayMode(0, i, &dm) != 0)
            continue;
        if (dm.w < 800 || dm.h < 600)
            continue;
        string32 str;
        xr_sprintf(str, sizeof(str), "%dx%d", dm.w, dm.h);
        bool dup = false;
        for (const auto& s : _tmp)
            if (xr_strcmp(s, str) == 0)
            {
                dup = true;
                break;
            }
        if (!dup)
            _tmp.push_back(xr_strdup(str));
    }

    if (_tmp.empty())
    {
        int w = 0, h = 0;
        if (win)
            SDL_GetWindowSize(win, &w, &h);
        if (w <= 0 || h <= 0)
        {
            SDL_DisplayMode dm{};
            if (SDL_GetDesktopDisplayMode(0, &dm) == 0)
            {
                w = dm.w;
                h = dm.h;
            }
        }
        if (w > 0 && h > 0)
        {
            string32 str;
            xr_sprintf(str, sizeof(str), "%dx%d", w, h);
            _tmp.push_back(xr_strdup(str));
        }
    }
    if (_tmp.empty())
        return;

    vid_mode_token = xr_alloc<xr_token>(_tmp.size() + 1);
    for (size_t i = 0; i < _tmp.size(); ++i)
    {
        vid_mode_token[i].name = _tmp[i];
        vid_mode_token[i].id = (int)i;
    }
    vid_mode_token[_tmp.size()].name = nullptr;
    vid_mode_token[_tmp.size()].id = -1;
}

// Renderer advertisement for ui_options.script for_renderer() gating (GL parity).
static void fill_vid_quality_list()
{
    if (vid_quality_token != nullptr)
        return;
    vid_quality_token = xr_alloc<xr_token>(2);
    vid_quality_token[0].name = xr_strdup("renderer_r2");
    vid_quality_token[0].id = 1;
    vid_quality_token[1].name = nullptr;
    vid_quality_token[1].id = -1;
}

CHW HW;

void UpdateVSync()
{
    HW.MtlDev.SetPresentInterval(psDeviceFlags.test(rsVSync) ? 1 : 0);
}

CHW::CHW()
{
    if (!ThisInstanceIsGlobal())
        return;

    Device.seqAppActivate.Add(this);
    Device.seqAppDeactivate.Add(this);
}

CHW::~CHW()
{
    if (!ThisInstanceIsGlobal())
        return;

    Device.seqAppActivate.Remove(this);
    Device.seqAppDeactivate.Remove(this);
}

void CHW::OnAppActivate()
{
    if (m_window)
        SDL_RestoreWindow(m_window);
}

void CHW::OnAppDeactivate()
{
    if (m_window)
    {
        if (SDL_GetWindowFlags(m_window) & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_FULLSCREEN_DESKTOP))
            SDL_MinimizeWindow(m_window);
    }
}

static std::pair<u32, u32> sdl_drawable_size(SDL_Window* wnd)
{
    int w = 0, h = 0;
    SDL_GL_GetDrawableSize(wnd, &w, &h); // backing pixels (works w/o GL ctx)
    if (w <= 0 || h <= 0)
        SDL_GetWindowSize(wnd, &w, &h);
    if (w <= 0 || h <= 0)
    {
        w = 1280;
        h = 720;
    }
    return { (u32)w, (u32)h };
}

// t4 (XR_METAL_SCALE): internal render scale. Engine resolution
// (Device.dwWidth/Height -> every scene RT) shrinks; the drawable stays at
// full window size and MtlBlitToDrawable upscales via MetalFX spatial scaler
// (falls back to the FS-triangle path). Default 1.0 = exact legacy behavior.
static float mtl_internal_scale()
{
    static float s_val = [] {
        const char* e = getenv("XR_METAL_SCALE");
        float f = e ? (float)atof(e) : 1.0f;
        return f < 0.25f ? 0.25f : (f > 1.0f ? 1.0f : f);
    }();
    return s_val;
}

static void mtl_scaled_res(const std::pair<u32, u32>& sz, u32& engW, u32& engH, u32& drawW,
                           u32& drawH)
{
    const float sc = mtl_internal_scale();
    drawW = sz.first;
    drawH = sz.second;
    engW = sc < 1.f ? std::max(2u, (u32)(sz.first * sc + 0.5f)) : sz.first;
    engH = sc < 1.f ? std::max(2u, (u32)(sz.second * sc + 0.5f)) : sz.second;
}

void CHW::CreateDevice(SDL_Window* hWnd)
{
    ZoneScoped;

    m_window = hWnd;
    R_ASSERT(m_window);

    Caps.fTarget = D3DFMT_A8R8G8B8;
    Caps.fDepth = D3DFMT_D24S8;

    // Engine reads Device.dwWidth/dwHeight everywhere (monolith sets them on
    // device reset, which the ported paths must do themselves — GL rule).
    {
        const auto sz = sdl_drawable_size(m_window);
        u32 engW = 0, engH = 0, drawW = 0, drawH = 0;
        mtl_scaled_res(sz, engW, engH, drawW, drawH);
        Device.dwWidth = engW;
        Device.dwHeight = engH;
    }

    std::string error;
    if (!MtlDev.Create(error))
    {
        Log("! Metal: device creation failed: %s", error.c_str());
        VERIFY(false);
        return;
    }
    if (!MtlDev.AttachToSDLWindow(m_window, error))
    {
        Log("! Metal: swapchain attach failed: %s", error.c_str());
        VERIFY(false);
        return;
    }
    const auto devDsz = sdl_drawable_size(m_window);
    MtlDev.Resize(devDsz.first, devDsz.second);
    UpdateVSync();

    MtlRuntimeAttach(MtlDev, Pipelines);

    AdapterName = MtlDev.DeviceName();
    MetalVersionString = "metal";
    ComputeShadersSupported = true;

    Msg("* GPU device: [%s] (Metal)", AdapterName);

    if (ThisInstanceIsGlobal())
        UpdateViews();

    fill_vid_mode_list_sdl(m_window);
    fill_vid_quality_list();
}

void CHW::DestroyDevice()
{
    MtlInvalidatePass();
    CommandBuffer = nullptr;
    BackBufferTexture = nullptr;
    MtlDev.Detach();
}

void CHW::Reset()
{
    ZoneScoped;

    if (m_window)
    {
        const auto sz = sdl_drawable_size(m_window);
        u32 engW = 0, engH = 0, drawW = 0, drawH = 0;
        mtl_scaled_res(sz, engW, engH, drawW, drawH);
        Device.dwWidth = engW;
        Device.dwHeight = engH;
        MtlDev.Resize(drawW, drawH);
    }
    UpdateVSync();
    MtlInvalidatePass();
    UpdateViews();
}

void CHW::SetPrimaryAttributes(u32& windowFlags)
{
    // Metal attaches to the plain Cocoa content view (CAMetalLayer sublayer);
    // no SDL window hints required (verified by the swapchain test).
    (void)windowFlags;
}

IRender::RenderContext CHW::GetCurrentContext() const
{
    // Metal has no contexts; the command queue is always "current".
    return IRender::PrimaryContext;
}

int CHW::MakeContextCurrent(IRender::RenderContext context) const
{
    (void)context;
    return 0;
}

void CHW::UpdateViews()
{
    BackBufferCount = 3; // CAMetalLayer drawable pool
}

void CHW::BeginScene()
{
    MtlFrameBegin();
}

void CHW::EndScene()
{
    MtlFrameEnd();
}

// Deferred screenshot capture hook (mtlScreenshot.cpp), same contract as GL.
void p4_present_screenshot_mtl();

void CHW::Present()
{
    MtlFrameEnd(); // finish the last encoder

    const bool can = MtlDev.CanPresent();
    void* drawable = nullptr;
    std::string error;
    if (can && !MtlDev.NextDrawable(&drawable, error))
        drawable = nullptr;

    if (drawable)
    {
        void* src = MtlCurrentPassColor0();
        static int s_p5_blit_logged = 0;
        static uint64_t s_lastDraws = 0, s_lastEnter = 0;
        static uint64_t s_lastEnc = 0, s_lastSws = 0, s_winStartDraws = 0;
        static int s_winStartNo = 0;
        const uint64_t draws = MtlDbgDrawStats(0);
        const uint64_t enter = MtlDbgDrawStats(3);
        const uint64_t sumTopo = MtlDbgDrawStats(10) + MtlDbgDrawStats(11) +
                                 MtlDbgDrawStats(12) + MtlDbgDrawStats(13) +
                                 MtlDbgDrawStats(14) + MtlDbgDrawStats(15);
        const bool print = s_p5_blit_logged < 8 || (s_p5_blit_logged % 240) == 0;
        s_p5_blit_logged++;
        if (print)
        {
            Msg("- p5 present#%d: src=%p (%ux%u) OK=%llu(+%llu) enter=%llu(+%llu) sumTopo=%llu "
                "fanOK=%llu fandrop=%llu noshader=%llu nopso=%llu nocb=%llu noenc=%llu noib=%llu "
                "topo=[%llu,%llu,%llu,%llu,%llu,%llu]",
                s_p5_blit_logged, src, Device.dwWidth, Device.dwHeight, draws,
                draws - s_lastDraws, enter, enter - s_lastEnter, sumTopo, MtlDbgDrawStats(8),
                MtlDbgDrawStats(7), MtlDbgDrawStats(1), MtlDbgDrawStats(2), MtlDbgDrawStats(4),
                MtlDbgDrawStats(5), MtlDbgDrawStats(6), MtlDbgDrawStats(10), MtlDbgDrawStats(11),
                MtlDbgDrawStats(12), MtlDbgDrawStats(13), MtlDbgDrawStats(14),
                MtlDbgDrawStats(15));
            // p5 diag: scan content of every color RT bound since last scan —
            // which render targets actually receive pixels (frozen-RT hunt).
            if (std::vector<void*>* rts = MtlDbgRTs())
            {
                static std::vector<uint64_t> s_prevHash;
                // p5 DIAG (launch103): geom-pass textures for the bisect probe
                void* s_bisPos = nullptr;
                void* s_bisAlb = nullptr;
                void* s_bisZb = nullptr;
                for (size_t i = 0; i < rts->size() && i < 24; ++i)
                {
                    void* t = (*rts)[i];
                    u32 tw = 0, th = 0;
                    MtlDev.TextureDims(t, &tw, &th);
                    if (!tw || !th)
                        continue;
                    std::vector<uint8_t> px(size_t(tw) * th * 4);
                    std::string e2;
                    if (!MtlDev.ReadbackSlice(t, px.data(), tw * 4, tw, th, 0, 0, e2))
                    {
                        Msg("- p5 rtscan[%zu]: %s %p readback failed: %s", i, MtlDbgRTGetName(t), t,
                            e2.c_str());
                        continue;
                    }
                    size_t nz = 0;
                    size_t firstNZ = SIZE_MAX;
                    uint64_t hash = 1469598103934665603ull;
                    for (size_t k = 0; k + 4 <= px.size(); k += 64)
                    {
                        if (px[k] | px[k + 1] | px[k + 2])
                        {
                            nz++;
                            if (firstNZ == SIZE_MAX)
                                firstNZ = k;
                        }
                        for (int q = 0; q < 4; q++)
                            hash = (hash ^ px[k + q]) * 1099511628211ull;
                    }
                    const uint64_t prev = i < s_prevHash.size() ? s_prevHash[i] : 0;
                    const size_t mid = (size_t(th / 2) * tw + tw / 2) * 4;
                    Msg("- p5 rtscan[%zu]: %s %p %ux%u nz=%zu mid=(%u,%u,%u,%u) hash=%016llx %s", i,
                        MtlDbgRTGetName(t), t, tw, th, nz, px[mid], px[mid + 1], px[mid + 2],
                        px[mid + 3], hash, prev && prev != hash ? "CHANGED" : (prev ? "same" : "first"));
                    // p5: raw bytes of first non-zero sample. $user$position is
                    // RGBA16F (8B/px): halves x,y,z at +0,+2,+4 — near-camera
                    // coords vs garbage distinguishes cull vs geometry bugs.
                    if (firstNZ != SIZE_MAX)
                    {
                        const char* nm = MtlDbgRTGetName(t);
                        size_t b = firstNZ;
                        size_t e = px.size();
                        Msg("- p5 rtval: %s @%zu bytes=(%02x%02x %02x%02x %02x%02x %02x%02x)",
                            nm ? nm : "?", b,
                            b < e ? px[b] : 0, b + 1 < e ? px[b + 1] : 0,
                            b + 2 < e ? px[b + 2] : 0, b + 3 < e ? px[b + 3] : 0,
                            b + 4 < e ? px[b + 4] : 0, b + 5 < e ? px[b + 5] : 0,
                            b + 6 < e ? px[b + 6] : 0, b + 7 < e ? px[b + 7] : 0);
                    }
                    // p5 DIAG (launch103): collect geom-pass textures for bisect
                    if (const char* nmSk = MtlDbgRTGetName(t))
                    {
                        if (strstr(nmSk, "position"))
                            s_bisPos = t;
                        else if (strstr(nmSk, "albedo"))
                            s_bisAlb = t;
                        else if (strstr(nmSk, "base_depth"))
                            s_bisZb = t;
                    }
                    if (s_prevHash.size() <= i)
                        s_prevHash.resize(i + 1);
                    s_prevHash[i] = hash;
                }
                if (s_bisPos)
                    MtlDbgBisectProbe(s_bisPos, s_bisAlb, s_bisZb);
            }
            MtlDbgDumpPairs();
            MtlDbgClearRTs();
            const int winPresents = s_p5_blit_logged - s_winStartNo;
            Msg("- p5 flow: encoders=%llu(+%llu) rtSwitches=%llu(+%llu) OK/present=%.1f over %d presents",
                MtlDbgDrawStats(20), MtlDbgDrawStats(20) - s_lastEnc, MtlDbgDrawStats(21),
                MtlDbgDrawStats(21) - s_lastSws,
                winPresents > 0 ? double(draws - s_winStartDraws) / winPresents : 0.0, winPresents);
            s_lastEnc = MtlDbgDrawStats(20);
            s_lastSws = MtlDbgDrawStats(21);
            s_winStartDraws = draws;
            s_winStartNo = s_p5_blit_logged;
        }
        s_lastDraws = draws;
        s_lastEnter = enter;
        if (src)
            MtlBlitToDrawable(src, drawable, Device.dwWidth, Device.dwHeight, MtlDev.Width(),
                              MtlDev.Height());
        MtlSetLastDrawable(drawable);
        BackBufferTexture = drawable;
        MtlDev.Present(MtlCurrentCommandBuffer());
    }
    else
    {
        // Occluded/locked or all drawables in flight: commit (keeps the GPU
        // advancing, screenshots stay live) but skip presentation; pace the
        // loop so the skip doesn't spin the CPU (GL occlusion-guard rule).
        MtlDev.Present(MtlCurrentCommandBuffer());
        static int s_skip_logged = 0;
        if (can && s_skip_logged++ < 3)
            Msg("* p5: metal present skipped (no drawable in flight)");
        else if (!can && s_skip_logged++ < 3)
            Msg("* p5: metal present skipped (window hidden or screen locked)");
        // p5 DIAG: RT coverage scan must run even while occluded/locked —
        // readback uses its own command buffer and does not need a drawable.
        {
            static int s_skipScan = 0;
            if ((++s_skipScan % 240) == 1)
            {
                if (std::vector<void*>* rts = MtlDbgRTs())
                {
                    static std::vector<uint64_t> s_prevHashSk;
                    // p5 DIAG (launch103): geom-pass textures for the bisect probe
                    void* s_bisPos = nullptr;
                    void* s_bisAlb = nullptr;
                    void* s_bisZb = nullptr;
                    for (size_t i = 0; i < rts->size() && i < 24; ++i)
                    {
                        void* t = (*rts)[i];
                        u32 tw = 0, th = 0;
                        MtlDev.TextureDims(t, &tw, &th);
                        if (!tw || !th)
                            continue;
                        std::vector<uint8_t> px(size_t(tw) * th * 4);
                        std::string e2;
                        if (!MtlDev.ReadbackSlice(t, px.data(), tw * 4, tw, th, 0, 0, e2))
                        {
                            Msg("- p5 rtscan[%zu]: %s %p readback failed: %s", i,
                                MtlDbgRTGetName(t), t, e2.c_str());
                            continue;
                        }
                        size_t nz = 0;
                        size_t firstNZ = SIZE_MAX;
                        uint64_t hash = 1469598103934665603ull;
                        for (size_t k = 0; k + 4 <= px.size(); k += 64)
                        {
                            if (px[k] | px[k + 1] | px[k + 2])
                            {
                                nz++;
                                if (firstNZ == SIZE_MAX)
                                    firstNZ = k;
                            }
                            for (int q = 0; q < 4; q++)
                                hash = (hash ^ px[k + q]) * 1099511628211ull;
                        }
                        const uint64_t prev = i < s_prevHashSk.size() ? s_prevHashSk[i] : 0;
                        const size_t mid = (size_t(th / 2) * tw + tw / 2) * 4;
                        Msg("- p5 rtscan[%zu]: %s %p %ux%u nz=%zu mid=(%u,%u,%u,%u) hash=%016llx %s",
                            i, MtlDbgRTGetName(t), t, tw, th, nz, px[mid], px[mid + 1], px[mid + 2],
                            px[mid + 3], hash,
                            prev && prev != hash ? "CHANGED" : (prev ? "same" : "first"));
                        if (firstNZ != SIZE_MAX)
                        {
                            const char* nm = MtlDbgRTGetName(t);
                            size_t b = firstNZ;
                            size_t e = px.size();
                            Msg("- p5 rtval: %s @%zu bytes=(%02x%02x %02x%02x %02x%02x %02x%02x)",
                                nm ? nm : "?", b,
                                b < e ? px[b] : 0, b + 1 < e ? px[b + 1] : 0,
                                b + 2 < e ? px[b + 2] : 0, b + 3 < e ? px[b + 3] : 0,
                                b + 4 < e ? px[b + 4] : 0, b + 5 < e ? px[b + 5] : 0,
                                b + 6 < e ? px[b + 6] : 0, b + 7 < e ? px[b + 7] : 0);
                        }
                        // p5 DIAG (launch103): staged pass bisect on the position
                        // Lmap — collect geom-pass textures, run once after scan.
                        if (const char* nmSk = MtlDbgRTGetName(t))
                        {
                            if (strstr(nmSk, "position"))
                                s_bisPos = t;
                            else if (strstr(nmSk, "albedo"))
                                s_bisAlb = t;
                            else if (strstr(nmSk, "base_depth"))
                                s_bisZb = t;
                        }
                        if (s_prevHashSk.size() <= i)
                            s_prevHashSk.resize(i + 1);
                        s_prevHashSk[i] = hash;
                    }
                    if (s_bisPos)
                        MtlDbgBisectProbe(s_bisPos, s_bisAlb, s_bisZb);
                }
                MtlDbgDumpPairs();
                MtlDbgClearRTs();
            }
        }
        Sleep(10);
    }

    // MCP 'screenshot' captures drain AFTER commit + GPU wait: the frame's
    // command buffer is only enqueued by Present() above, and ReadbackSlice
    // runs on its own command buffer (GL readback implicitly synced; Metal
    // does not). rt[0] still holds this frame's final PP target.
    MtlWaitCurrentCB();
    p4_present_screenshot_mtl();

    CurrentBackBuffer = (CurrentBackBuffer + 1) % BackBufferCount;
}

DeviceState CHW::GetDeviceState() const
{
    return DeviceState::Normal;
}

std::pair<u32, u32> CHW::GetSurfaceSize()
{
    return { Device.dwWidth, Device.dwHeight };
}

bool CHW::ThisInstanceIsGlobal() const
{
    return this == &HW;
}

void CHW::BeginPixEvent(pcstr) const { } // XCode capture integration: p5 t3
void CHW::EndPixEvent() const { }
} // namespace xray::render::RENDER_NAMESPACE
