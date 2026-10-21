// mtlScreenshot.cpp — screenshot family on Metal (p5 t2).
// Mirror of glr_screenshot.cpp: MCP 'screenshot' queues a request that
// CHW::Present services after MtlFrameEnd (frame complete, final PP target
// still the pass color0); readback goes through the substrate's synchronous
// ReadbackSlice (dedicated CB + wait), so it never races the frame command
// buffer that commits later in Present.
#include "stdafx.h"

#include "xrCore/Media/Image.hpp"
#include "xrEngine/xrImage_Resampler.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "Layers/xrRenderMetal/mtlRuntime.h"

namespace xray::render::RENDER_NAMESPACE
{
using namespace XRay::Media;

// p4: deferred screenshot capture flag (set by CRender::Screenshot, drained
// by p4_present_screenshot_mtl from CHW::Present).
namespace
{
    bool g_p4_ss_pending{ false };
    string_path g_p4_ss_name{};

    // Read the finished frame (BGRA) out of the last pass color attachment.
    bool capture_frame_rgb8(xr_vector<u8>& pixels, u32& w, u32& h)
    {
        void* src = MtlCurrentPassColor0();
        if (!src)
            return false;
        w = Device.dwWidth;
        h = Device.dwHeight;
        xr_vector<u8> bgra(size_t(w) * h * 4);
        std::string err;
        if (!HW.MtlDev.ReadbackSlice(src, bgra.data(), w * 4, w, h, 0, 0, err))
        {
            Msg("! Metal screenshot readback failed: %s", err.c_str());
            return false;
        }
        // p5 diag: is the source texture actually holding pixels?
        {
            size_t nonZero = 0;
            for (size_t i = 0; i < bgra.size(); i += 64)
                if (bgra[i])
                    nonZero++;
            const size_t mid = (size_t(h / 2) * w + w / 2) * 4;
            Msg("- Metal screenshot diag: src=%p %ux%u nonzeroSamples=%zu mid=(%u,%u,%u,%u)", src, w, h,
                nonZero, bgra[mid], bgra[mid + 1], bgra[mid + 2], bgra[mid + 3]);
        }
        // p5 diag: read back every color RT bound since last frame — which of
        // them (if any) holds the drawn content?
        {
            if (std::vector<void*>* rts = MtlDbgRTs())
            {
                for (size_t i = 0; i < rts->size(); ++i)
                {
                    void* t = (*rts)[i];
                    u32 tw = 0, th = 0;
                    HW.MtlDev.TextureDims(t, &tw, &th);
                    if (!tw || !th)
                        continue;
                    xr_vector<u8> px(size_t(tw) * th * 4);
                    std::string e2;
                    if (!HW.MtlDev.ReadbackSlice(t, px.data(), tw * 4, tw, th, 0, 0, e2))
                    {
                        Msg("- Metal RT diag[%zu]: %p readback failed: %s", i, t, e2.c_str());
                        continue;
                    }
                    size_t nz = 0;
                    for (size_t k = 0; k < px.size(); k += 64)
                        if (px[k])
                            nz++;
                    Msg("- Metal RT diag[%zu]: %p %ux%u nonzeroSamples=%zu", i, t, tw, th, nz);
                }
            }
            MtlDbgClearRTs();
        }
        pixels.resize(size_t(w) * h * 3);
        for (size_t i = 0, count = size_t(w) * h; i < count; ++i)
        {
            // BGRA -> RGB
            pixels[i * 3 + 0] = bgra[i * 4 + 2];
            pixels[i * 3 + 1] = bgra[i * 4 + 1];
            pixels[i * 3 + 2] = bgra[i * 4 + 0];
        }
        return true;
    }
} // namespace

// p4: stage fence. Metal has no deferred error queue to drain; the hook is a
// no-op kept for the shared r2_R_render.cpp call sites.
void p4_gl_fence(pcstr stage)
{
    (void)stage;
}

void p4_present_screenshot_mtl()
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
    u32 w = 0, h = 0;
    if (capture_frame_rgb8(pixels, w, h))
    {
        // self-diagnostic — is the captured frame actually lit anywhere?
        u32 maxv = 0, nonzero = 0;
        const size_t step = 3 * 17; // sparse sample
        size_t sampled = 0;
        for (size_t i = 0; i < pixels.size(); i += step, ++sampled)
        {
            const u8 v = pixels[i];
            if (v > maxv) maxv = v;
            if (v) ++nonzero;
        }
        Msg("* p4 capture probe: max=%u lit=%.1f%%", maxv,
            sampled ? 100.0 * nonzero / sampled : 0.0);
        Image img{ w, h, pixels.data(), ImageDataFormat::RGB8 };
        // No scanline invert: ReadbackSlice returns Metal texture order
        // (row 0 = top). The GL port needed invert=true because glReadPixels
        // returns bottom-up rows.
        if (!img.SaveJPEG(*fs, 100, false))
            Log("! Failed to make a screenshot.");
    }
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

        xr_strcpy(g_p4_ss_name, buf);
        g_p4_ss_pending = true;
        break;
    }

    case SM_FOR_GAMESAVE:
        // XXX: Implement
        break;

    default:
        VERIFY(!"CRender::Screenshot. This screenshot type is not supported for Metal.");
    }
}

// p4: monolith screenshot family (xrEngine/screenshot_manager.cpp drives the
// async pair; the engine resizes gamesave thumbnails itself). Metal readback
// is synchronous — Begin captures, End encodes.
namespace
{
    xr_vector<u8> g_p4_ss_pixels;
    u32 g_p4_ss_w{ 0 };
    u32 g_p4_ss_h{ 0 };
} // namespace

void CRender::Screenshot(ScreenshotMode mode, CMemoryWriter& memory_writer)
{
    (void)mode;
    if (!capture_frame_rgb8(g_p4_ss_pixels, g_p4_ss_w, g_p4_ss_h))
        return;
    Image img{ g_p4_ss_w, g_p4_ss_h, g_p4_ss_pixels.data(), ImageDataFormat::RGB8 };
    if (!img.SaveJPEG(memory_writer, 100, true))
        Log("! Failed to make a screenshot.");
    g_p4_ss_pixels.clear();
}

void CRender::ScreenshotAsyncBegin()
{
    if (!Device.b_is_Ready)
        return;
    capture_frame_rgb8(g_p4_ss_pixels, g_p4_ss_w, g_p4_ss_h);
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
