#include "stdafx.h"

//#include "xr_effgamma.h"
#include "xrCore/Media/Image.hpp"
#include "xrEngine/xrImage_Resampler.h"

namespace xray::render::RENDER_NAMESPACE
{
using namespace XRay::Media;

#define GAMESAVE_SIZE 128

#define SM_FOR_SEND_WIDTH 640
#define SM_FOR_SEND_HEIGHT 480

// p4: deferred screenshot capture. The 'screenshot' CCC fires during seqFrame
// (before the frame is drawn), where the GL back buffer holds stale/undefined
// contents — immediate glReadPixels yields black. Queue the request and let
// CHW::Present() capture after the FTO blit, before the swap.
namespace
{
    bool g_p4_ss_pending{ false };
    string_path g_p4_ss_name{};
} // namespace

void p4_present_screenshot()
{
    if (!g_p4_ss_pending)
        return;
    g_p4_ss_pending = false;

    IWriter* fs = FS.w_open("$screenshots$", g_p4_ss_name);
    if (!fs)
    {
        Msg("! screenshot: cannot open '%s' for write", g_p4_ss_name);
        return;
    }
    xr_vector<u8> pixels;
    pixels.resize(size_t(Device.dwWidth) * Device.dwHeight * 3);
    glReadPixels(0, 0, Device.dwWidth, Device.dwHeight, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());
    Image img{ Device.dwWidth, Device.dwHeight, pixels.data(), ImageDataFormat::RGB8 };
    if (!img.SaveJPEG(*fs, 100, true))
        Log("! Failed to make a screenshot.");
    FS.w_close(fs);
    Msg("* screenshot: '%s'", g_p4_ss_name);
}

// XXX: Provide full implementation
void CRender::Screenshot(ScreenshotMode mode /*= SM_NORMAL*/, pcstr name /*= nullptr*/)
{
    switch (mode)
    {
    case SM_NORMAL:
    {
        pcstr extension = "jpg";

        string64 time;
        string_path buf;
        if (name && name[0])
            // p4: explicit harness name — deterministic filenames for diffs.
            xr_sprintf(buf, sizeof(buf), "%s.%s", name, extension);
        else
            xr_sprintf(buf, sizeof(buf), "ss_%s_%s_(%s).%s", Core.UserName, timestamp(time),
                g_pGameLevel ? g_pGameLevel->name().c_str() : "mainmenu", extension);

#ifdef XR_PLATFORM_WEB
        // web has no Present() hook to piggyback on — capture immediately
        IWriter* fs = FS.w_open("$screenshots$", buf);
        R_ASSERT(fs);
        xr_vector<u8> pixels;
        pixels.resize(size_t(Device.dwWidth) * Device.dwHeight * 3);
        xr_vector<u8> rgba;
        rgba.resize(size_t(Device.dwWidth) * Device.dwHeight * 4);
        glReadPixels(0, 0, Device.dwWidth, Device.dwHeight, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        for (size_t i = 0, count = size_t(Device.dwWidth) * Device.dwHeight; i < count; ++i)
        {
            pixels[i * 3 + 0] = rgba[i * 4 + 0];
            pixels[i * 3 + 1] = rgba[i * 4 + 1];
            pixels[i * 3 + 2] = rgba[i * 4 + 2];
        }
        Image img{ Device.dwWidth, Device.dwHeight, pixels.data(), ImageDataFormat::RGB8 };
        if (!img.SaveJPEG(*fs, 100, true))
            Log("! Failed to make a screenshot.");
        FS.w_close(fs);
#else
        xr_strcpy(g_p4_ss_name, buf);
        g_p4_ss_pending = true;
#endif
        break;
    }

    case SM_FOR_GAMESAVE:
        // XXX: Implement
        break;

    default:
        VERIFY(!"CRender::Screenshot. This screenshot type is not supported for OGL.");
    }
}

// p4: monolith screenshot family (xrEngine/screenshot_manager.cpp drives the
// async pair; the engine resizes gamesave thumbnails itself). GL readback is
// synchronous — Begin captures, End encodes.
namespace
{
    xr_vector<u8> g_p4_ss_pixels;
    u32 g_p4_ss_w{ 0 };
    u32 g_p4_ss_h{ 0 };

    void capture_backbuffer()
    {
        g_p4_ss_w = Device.dwWidth;
        g_p4_ss_h = Device.dwHeight;
        g_p4_ss_pixels.resize(size_t(g_p4_ss_w) * g_p4_ss_h * 3);
        glReadPixels(0, 0, g_p4_ss_w, g_p4_ss_h, GL_RGB, GL_UNSIGNED_BYTE, g_p4_ss_pixels.data());
    }
} // namespace

void CRender::Screenshot(ScreenshotMode mode, CMemoryWriter& memory_writer)
{
    (void)mode;
    capture_backbuffer();
    Image img{ g_p4_ss_w, g_p4_ss_h, g_p4_ss_pixels.data(), ImageDataFormat::RGB8 };
    if (!img.SaveJPEG(memory_writer, 100, true))
        Log("! Failed to make a screenshot.");
    g_p4_ss_pixels.clear();
}

void CRender::ScreenshotAsyncBegin()
{
    if (!Device.b_is_Ready)
        return;
    capture_backbuffer();
}

void CRender::ScreenshotAsyncEnd(CMemoryWriter& memory_writer)
{
    if (g_p4_ss_pixels.empty())
        return;
    Image img{ g_p4_ss_w, g_p4_ss_h, g_p4_ss_pixels.data(), ImageDataFormat::RGB8 };
    if (!img.SaveJPEG(memory_writer, 100, true))
        Log("! Failed to make a screenshot.");
    g_p4_ss_pixels.clear();
}

void CRender::ScreenshotImpl(ScreenshotMode mode, LPCSTR name, CMemoryWriter* memory_writer)
{
    if (memory_writer)
        Screenshot(mode, *memory_writer);
    else
        Screenshot(mode, name);
}
} // namespace xray::render::RENDER_NAMESPACE
