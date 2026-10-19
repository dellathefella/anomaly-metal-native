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
        xr_sprintf(buf, sizeof(buf), "ss_%s_%s_(%s).%s", Core.UserName, timestamp(time),
            g_pGameLevel ? g_pGameLevel->name().c_str() : "mainmenu", extension);

        IWriter* fs = FS.w_open("$screenshots$", buf);
        R_ASSERT(fs);

        xr_vector<u8> pixels;
        pixels.resize(Device.dwWidth * Device.dwHeight * 3);

#ifdef XR_PLATFORM_WEB
        xr_vector<u8> rgba;
        rgba.resize(Device.dwWidth * Device.dwHeight * 4);
        glReadPixels(0, 0, Device.dwWidth, Device.dwHeight, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        for (size_t i = 0, count = size_t(Device.dwWidth) * Device.dwHeight; i < count; ++i)
        {
            pixels[i * 3 + 0] = rgba[i * 4 + 0];
            pixels[i * 3 + 1] = rgba[i * 4 + 1];
            pixels[i * 3 + 2] = rgba[i * 4 + 2];
        }
#else
        glReadPixels(0, 0, Device.dwWidth, Device.dwHeight, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());
#endif

        Image img{ Device.dwWidth, Device.dwHeight, pixels.data(), ImageDataFormat::RGB8 };
        if (!img.SaveJPEG(*fs, 100, true))
            Log("! Failed to make a screenshot.");

        FS.w_close(fs);
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
