// mtl_test_hw.cpp — hardware capability probe on Metal (p5 t2).
// Mirror of r2_test_hw.cpp: spins a hidden helper window + CHW device and
// checks the Metal device came up.
#include "stdafx.h"

namespace xray::render::RENDER_NAMESPACE
{
class sdl_window_test_helper
{
    SDL_Window* m_window{};
    CHW m_hw;

public:
    sdl_window_test_helper()
    {
        u32 flags{};
        m_hw.SetPrimaryAttributes(flags);
        m_window = SDL_CreateWindow("TestMetalWindow", 0, 0, 1, 1, SDL_WINDOW_HIDDEN | flags);
        if (!m_window)
        {
            Log("~ Cannot create helper window for Metal test:", SDL_GetError());
            return;
        }
        m_hw.CreateDevice(m_window);
    }

    [[nodiscard]]
    bool successful() const
    {
        return m_window && m_hw.MtlDev.Device();
    }

    ~sdl_window_test_helper()
    {
        m_hw.DestroyDevice();
        SDL_DestroyWindow(m_window);
    }
};

BOOL xrRender_test_hw()
{
    ZoneScoped;

    // Check if a Metal device is available at all
    const sdl_window_test_helper windowTest;
    if (windowTest.successful())
        return TRUE;

    return FALSE;
}
} // namespace xray::render::RENDER_NAMESPACE
