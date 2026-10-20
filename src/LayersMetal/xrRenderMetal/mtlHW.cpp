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
        Device.dwWidth = sz.first;
        Device.dwHeight = sz.second;
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
    MtlDev.Resize(Device.dwWidth, Device.dwHeight);
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
        Device.dwWidth = sz.first;
        Device.dwHeight = sz.second;
        MtlDev.Resize(sz.first, sz.second);
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

    // MCP 'screenshot' captures land here — the frame is complete and the
    // final PP target is still bound as pass color0.
    p4_present_screenshot_mtl();

    const bool can = MtlDev.CanPresent();
    void* drawable = nullptr;
    std::string error;
    if (can && !MtlDev.NextDrawable(&drawable, error))
        drawable = nullptr;

    if (drawable)
    {
        void* src = MtlCurrentPassColor0();
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
        Sleep(10);
    }

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
