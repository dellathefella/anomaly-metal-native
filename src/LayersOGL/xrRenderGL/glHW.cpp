// glHW.cpp: implementation of the OpenGL specialisation of CHW.
//////////////////////////////////////////////////////////////////////

#include "stdafx.h"
#pragma hdrstop

#include "glHW.h"
#include "xrEngine/XR_IOConsole.h"
#include "Include/xrAPI/xrAPI.h" // p4: vid_mode_token (settings dialog enumerates it)

// p4: xrEngine's globals live at C++ global scope (unmangled on Mach-O). An
// extern declared inside the render_gl namespace binds to
// xray::render::render_gl::vid_quality_token -> dyld "symbol not found in
// flat namespace" abort at launch. Declare at global scope.
extern xr_token* vid_quality_token; // defined in xrEngine/xr_ioc_cmd.cpp

namespace xray::render::RENDER_NAMESPACE
{
// p4: monolith DX11 filled vid_mode_token from DXGI mode enumeration
// (fill_vid_mode_list); the GL path left it null, so game.get_resolutions()
// returned "" and ui_options.script cont_vid_mode() did arithmetic on nil
// (settings dialog aborted). Enumerate SDL display modes instead.
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
        // No enumerable modes (headless/odd driver): at least the current
        // drawable size, so the settings dialog always has one entry.
        int w = 0, h = 0;
        if (win)
            SDL_GL_GetDrawableSize(win, &w, &h);
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

// p4: the settings UI (ui_options.script) gates every video option through
// for_renderer() against the "renderer" cvar status, which reads
// vid_quality_token. DX11 filled it; the GL path left it null so
// get_console_cmd(0,"renderer") returned "?" and no option matched.
// The GL renderer implements the R2 feature set, so advertise exactly that:
// r1/r3/r4-only rows (DX11 tessellation, MSAA list, fixed-function gamma)
// then hide themselves, and the renderer picker offers one entry.
static void fill_vid_quality_list()
{
    if (vid_quality_token != nullptr)
        return;
    vid_quality_token = xr_alloc<xr_token>(2);
    vid_quality_token[0].name = xr_strdup("renderer_r2");
    vid_quality_token[0].id = 1; // monolith quality ids: 0=r1, 1..3=r2 family
    vid_quality_token[1].name = nullptr;
    vid_quality_token[1].id = -1;
}
CHW HW;

void CALLBACK OnDebugCallback(GLenum /*source*/, GLenum /*type*/, GLuint id, GLenum severity, GLsizei /*length*/,
    const GLchar* message, const void* /*userParam*/)
{
    if (severity != GL_DEBUG_SEVERITY_NOTIFICATION)
        Log(message, id);
}

static_assert(std::is_same_v<decltype(&OnDebugCallback), GLDEBUGPROC>);

void UpdateVSync()
{
#ifdef XR_PLATFORM_WEB
    return; // presentation is paced by the browser
#endif
    if (psDeviceFlags.test(rsVSync))
    {
        // Try adaptive vsync first
        if (SDL_GL_SetSwapInterval(-1) == -1)
            SDL_GL_SetSwapInterval(1);
    }
    else
    {
        SDL_GL_SetSwapInterval(0);
    }
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
    {
        SDL_RestoreWindow(m_window);
    }
}

void CHW::OnAppDeactivate()
{
    if (m_window)
    {
        if (SDL_GetWindowFlags(m_window) & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_FULLSCREEN_DESKTOP)) // p4: monolith device has no psDeviceMode; ask SDL
            SDL_MinimizeWindow(m_window);
    }
}

//////////////////////////////////////////////////////////////////////
// Construction/Destruction
//////////////////////////////////////////////////////////////////////
void CHW::CreateDevice(SDL_Window* hWnd)
{
    ZoneScoped;

    m_window = hWnd;

    R_ASSERT(m_window);

    // Choose the closest pixel format
    SDL_DisplayMode mode;
    SDL_GetWindowDisplayMode(m_window, &mode);
    mode.format = SDL_PIXELFORMAT_RGBA8888;
    // Apply the pixel format to the device context
    SDL_SetWindowDisplayMode(m_window, &mode);

    Caps.fTarget = D3DFMT_A8R8G8B8;
    Caps.fDepth = D3DFMT_D24S8;

    // p4: the monolith engine only assigns dwWidth/dwHeight on D3D device
    // reset, which never happens on the GL path — size them from the SDL
    // window so the r2 main-RT chain (and everything using Device.dwWidth)
    // gets a real resolution.
    {
        int win_w = 0, win_h = 0;
        SDL_GL_GetDrawableSize(m_window, &win_w, &win_h);
        if (win_w <= 0 || win_h <= 0)
            SDL_GetWindowSize(m_window, &win_w, &win_h);
        if (win_w <= 0 || win_h <= 0)
        {
            win_w = 1280;
            win_h = 720;
        }
        Device.dwWidth = (u32)win_w;
        Device.dwHeight = (u32)win_h;
    }

    // p4: the monolith engine owns window creation, so dev's
    // SetPrimaryAttributes() never ran on this path — SDL defaults to a legacy
    // 2.1 context without these hints.
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    if (!strstr(Core.Params, "-no_gl_context"))
    {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);
    }
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

    // Create the context
#ifdef XR_PLATFORM_WEB
    EmscriptenWebGLContextAttributes attributes;
    emscripten_webgl_init_context_attributes(&attributes);
    attributes.majorVersion = 2;
    attributes.minorVersion = 0;
    attributes.alpha = false;
    attributes.depth = false;
    attributes.stencil = false;
    attributes.antialias = false;
    attributes.powerPreference = EM_WEBGL_POWER_PREFERENCE_HIGH_PERFORMANCE;

    m_webgl = emscripten_webgl_create_context("#canvas", &attributes);
    if (m_webgl <= 0)
    {
        Log("! WebGL2: could not create drawing context:", m_webgl);
        return;
    }

    if (MakeContextCurrent(IRender::PrimaryContext) != 0)
    {
        Log("! WebGL2: could not make context current");
        return;
    }

    int version;
    {
        ZoneScopedN("gladLoadGLES2");
        version = gladLoadGLES2(reinterpret_cast<GLADloadfunc>(emscripten_webgl_get_proc_address));
    }
    BaseVertexDrawSupported =
        emscripten_webgl_enable_extension(m_webgl, "WEBGL_draw_instanced_base_vertex_base_instance");
    Msg("* WebGL base vertex draws: %s", BaseVertexDrawSupported ? "extension" : "attribute re-pointing");
#else
    m_context = SDL_GL_CreateContext(m_window);
    if (m_context == nullptr)
    {
        Log("! OpenGL: could not create drawing context:", SDL_GetError());
        return;
    }

    if (MakeContextCurrent(IRender::PrimaryContext) != 0)
    {
        Log("! OpenGL: could not make context current:", SDL_GetError());
        return;
    }

    int version;
    {
        ZoneScopedN("gladLoadGL");
        version = gladLoadGL(reinterpret_cast<GLADloadfunc>(SDL_GL_GetProcAddress));
    }
#endif
    if (version == 0)
    {
        Log("! OpenGL: could not initialize GLAD.");
        if (const auto err = SDL_GetError())
            Log("SDL Error:", err);
        return;
    }

    if (ThisInstanceIsGlobal())
    {
        UpdateVSync();

#ifdef DEBUG
        if (glDebugMessageCallback)
        {
            CHK_GL(glEnable(GL_DEBUG_OUTPUT));
            CHK_GL(glDebugMessageCallback((GLDEBUGPROC)OnDebugCallback, nullptr));
        }
#endif // DEBUG
    }

    int iMaxVTFUnits, iMaxCTIUnits;
    glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &iMaxVTFUnits);
    glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &iMaxCTIUnits);

    AdapterName = reinterpret_cast<pcstr>(glGetString(GL_RENDERER));
    OpenGLVersionString = reinterpret_cast<pcstr>(glGetString(GL_VERSION));
    ShadingVersion = reinterpret_cast<pcstr>(glGetString(GL_SHADING_LANGUAGE_VERSION));

    Msg("* GPU vendor: [%s] device: [%s]", glGetString(GL_VENDOR), AdapterName);
    Msg("* GPU OpenGL version: %s", OpenGLVersionString);
    Msg("* GPU OpenGL shading language version: %s", ShadingVersion);
    Msg("* GPU OpenGL VTF units: [%d] CTI units: [%d]", iMaxVTFUnits, iMaxCTIUnits);

#ifdef XR_PLATFORM_WEB
    TextureUploadUnit = u32(iMaxCTIUnits) - 1;
    R_ASSERT2(TextureUploadUnit >= CTexture::rstVertex + CTexture::mtMaxVertexShaderTextures,
        "too few texture units for a dedicated upload unit");
#endif

    ComputeShadersSupported = false; // XXX: Implement compute shaders support

    if (glGenFramebuffers && glBindFramebuffer)
        UpdateViews();

    fill_vid_mode_list_sdl(m_window);
    fill_vid_quality_list();
}

void CHW::DestroyDevice()
{
    CHK_GL(glDeleteFramebuffers(1, &pFB));
    pFB = 0;

#ifdef XR_PLATFORM_WEB
    emscripten_webgl_destroy_context(m_webgl);
    m_webgl = 0;
    return;
#endif

    const auto context = SDL_GL_GetCurrentContext();
    if (context == m_context)
        SDL_GL_MakeCurrent(nullptr, nullptr);

    SDL_GL_DeleteContext(m_context);
    m_context = nullptr;
}

//////////////////////////////////////////////////////////////////////
// Resetting device
//////////////////////////////////////////////////////////////////////
void CHW::Reset()
{
    ZoneScoped;

    CHK_GL(glDeleteFramebuffers(1, &pFB));
    pFB = 0;
    UpdateViews();

    UpdateVSync();
}

void CHW::SetPrimaryAttributes(u32& windowFlags)
{
#ifdef XR_PLATFORM_WEB
    return; // the WebGL2 context is created on the canvas directly, not through SDL
#endif
    windowFlags |= SDL_WINDOW_OPENGL;

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);

    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

    if (!strstr(Core.Params, "-no_gl_context"))
    {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);
    }
}

IRender::RenderContext CHW::GetCurrentContext() const
{
#ifdef XR_PLATFORM_WEB
    if (emscripten_webgl_get_current_context() == m_webgl)
        return IRender::PrimaryContext;
    return IRender::NoContext;
#else
    const auto context = SDL_GL_GetCurrentContext();
    if (context == m_context)
        return IRender::PrimaryContext;
    return IRender::NoContext;
#endif
}

int CHW::MakeContextCurrent(IRender::RenderContext context) const
{
    switch (context)
    {
#ifdef XR_PLATFORM_WEB
    case IRender::NoContext:
        return emscripten_webgl_make_context_current(0);

    case IRender::PrimaryContext:
        return emscripten_webgl_make_context_current(m_webgl);
#else
    case IRender::NoContext:
        return SDL_GL_MakeCurrent(nullptr, nullptr);

    case IRender::PrimaryContext:
        return SDL_GL_MakeCurrent(m_window, m_context);
#endif

    default:
        NODEFAULT;
    }
    return -1;
}

void CHW::UpdateViews()
{
    // Create the default framebuffer
    glGenFramebuffers(1, &pFB);
    CHK_GL(glBindFramebuffer(GL_FRAMEBUFFER, pFB));

    BackBufferCount = 1;
}

void CHW::BeginScene() { }
void CHW::EndScene() { }

// p4: defined in glr_screenshot.cpp — deferred screenshot capture hook.
void p4_present_screenshot();
void p4_gl_fence(pcstr stage);

// p4: macOS occlusion guard. With vsync on, SDL3/Cocoa's SDL_GL_SwapWindow blocks in a
// condition-wait for the swap-completion callback while the window receives no frames:
// hidden behind other apps, on another Space, or the SCREEN LOCKED (window server freezes
// app windows without touching any SDL flag). The callback then never fires and the whole
// engine freezes: 0% CPU, MCP dead, log frozen — indistinguishable from a hang.
// Ground truth is NSWindow.occlusionState (NSWindowOcclusionStateVisible covers occlusion,
// Spaces and lock) — fetched via SDL_GetWindowWMInfo and the objc runtime, since this TU is
// C++. CGSSessionScreenIsLocked additionally catches the lock where occlusion lags.
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <SDL_syswm.h>
// objc runtime, declared by hand: <objc/*.h> defines BOOL and collides with xrCore's.
extern "C" void* objc_msgSend(void*, void*, ...);
extern "C" void* sel_registerName(const char*);
// deprecated legacy API, still exported by CoreGraphics (loaded via libSDL3):
extern "C" CFDictionaryRef CGSessionCopyCurrentDictionary(void);

static bool p4_window_visible(SDL_Window* wnd)
{
    static void* occlusion_sel = sel_registerName("occlusionState");
    // SDL2 SDL_SysWMinfo cocoa layout: { version; subsystem; union { window; context; } }
    struct wm_info_t
    {
        SDL_version version;
        int subsystem;
        void* window;
        void* context;
    };
    static SDL_Window* s_cached_wnd = nullptr;
    static wm_info_t s_wm;
    static bool s_failed = false;
    if (wnd != s_cached_wnd) // window recreation (vid_mode/Reset) invalidates the cache
    {
        s_cached_wnd = wnd;
        s_failed = false;
        SDL_VERSION(&s_wm.version);
        if (!SDL_GetWindowWMInfo(wnd, (SDL_SysWMinfo*)&s_wm))
            s_failed = true;
    }
    if (s_failed)
        return true; // never block the swap on a detection failure
    if (!s_wm.window)
        return true;
    unsigned long state = (unsigned long)objc_msgSend(s_wm.window, occlusion_sel);
    return (state & 1) != 0; // NSWindowOcclusionStateVisible
}

static bool p4_screen_locked()
{
    CFDictionaryRef d = CGSessionCopyCurrentDictionary();
    if (!d)
        return false;
    bool locked = false;
    if (CFNumberRef v = (CFNumberRef)CFDictionaryGetValue(d, CFSTR("CGSSessionScreenIsLocked")))
    {
        int x = 0;
        CFNumberGetValue(v, kCFNumberIntType, &x);
        locked = x != 0;
    }
    CFRelease(d);
    return locked;
}
#endif

void CHW::Present()
{
    p4_gl_fence("present"); // drains errors from PP/UI since CRender::Render
#if 0 // kept for historical reasons
    RImplementation.Target->phase_flip();
#else
    glBindFramebuffer(GL_READ_FRAMEBUFFER, pFB);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glBlitFramebuffer(
        0, 0, Device.dwWidth, Device.dwHeight,
        0, 0, Device.dwWidth, Device.dwHeight,
        GL_COLOR_BUFFER_BIT, GL_NEAREST);
#endif

    // p4: queued 'screenshot <name>' captures land here — the rendered frame is
    // complete and pFB is bound as GL_READ_FRAMEBUFFER.
    p4_present_screenshot();

#ifndef XR_PLATFORM_WEB
    // Skip only the swap while hidden/locked: the scene still renders into pFB, so
    // screenshots and the main loop (message pump, MCP) stay fully alive. Without the
    // vsync wait, pace the loop manually so the skip doesn't spin the CPU.
#ifdef __APPLE__
    if (p4_window_visible(m_window) && !p4_screen_locked())
        SDL_GL_SwapWindow(m_window);
    else
    {
        static int s_skip_logged = 0;
        if (s_skip_logged++ < 3)
            Msg("* p4: swap skipped (window hidden or screen locked)");
        Sleep(10);
    }
#else
    SDL_GL_SwapWindow(m_window); // on the web the frame is presented when the loop callback returns
#endif
#endif
    CurrentBackBuffer = (CurrentBackBuffer + 1) % BackBufferCount;
}

DeviceState CHW::GetDeviceState() const
{
    //  TODO: OGL: Implement GetDeviceState
    return DeviceState::Normal;
}

std::pair<u32, u32> CHW::GetSurfaceSize()
{
    return
    {
        Device.dwWidth,
        Device.dwHeight
    };
}

bool CHW::ThisInstanceIsGlobal() const
{
    return this == &HW;
}

void CHW::BeginPixEvent(pcstr name) const
{
    if (glPushDebugGroup)
        glPushDebugGroup(GL_DEBUG_SOURCE_APPLICATION, 0, -1, name);
}

void CHW::EndPixEvent() const
{
    if (glPushDebugGroup)
        glPopDebugGroup();
}
} // namespace xray::render::RENDER_NAMESPACE

#ifdef XR_PLATFORM_WEB
namespace xray::render::RENDER_NAMESPACE
{
texture_upload_unit::texture_upload_unit(GLenum target) : target(target)
{
    CHK_GL(glActiveTexture(GL_TEXTURE0 + HW.TextureUploadUnit));
}

texture_upload_unit::~texture_upload_unit()
{
    CHK_GL(glBindTexture(target, 0));
}
} // namespace xray::render::RENDER_NAMESPACE
#endif
