#pragma once
// p5 Metal device layer — CHW (mirror of xrRenderGL/glHW.h).
// The Metal substrate (xray::metal::MetalDevice: device/queue/CAMetalLayer
// swapchain + resource arena, and MetalStateCache: pipeline/depth-state caches)
// lives one level up in LayersMetal; CHW owns instances of both and exposes
// borrowed void* handles to the rest of the renderer.

#include "Layers/xrRender/HWCaps.h"
#include "xrCore/ModuleLookup.hpp"

// Substrate facades: included via the include path (src/LayersMetal) — a
// relative path would resolve through the LayersMetal/Layers symlink and
// overshoot one level.
#include "mtl_device.h"
#include "mtl_state.h"
namespace xray::render::RENDER_NAMESPACE
{
class CHW
    : public pureAppActivate,
      public pureAppDeactivate
{
public:
    CHW();
    ~CHW();

    void CreateDevice(SDL_Window* sdlWnd);
    void DestroyDevice();

    void Reset();

    void SetPrimaryAttributes(u32& windowFlags);

    IRender::RenderContext GetCurrentContext() const;
    int  MakeContextCurrent(IRender::RenderContext context) const;

    static std::pair<u32, u32> GetSurfaceSize();
    DeviceState GetDeviceState() const;

public:
    void BeginScene();
    void EndScene();
    void Present();

public:
    void OnAppActivate() override;
    void OnAppDeactivate() override;

private:
    void UpdateViews();
    bool ThisInstanceIsGlobal() const;

public:
    void BeginPixEvent(pcstr name) const;
    void EndPixEvent() const;

public:
    // Single immediate context (Metal command queue serializes; the DX11
    // parallel-context machinery collapses onto it, same as the GL port).
    static constexpr auto IMM_CTX_ID = 0;

    CHWCaps Caps;

    u32 BackBufferCount{ 3 };
    u32 CurrentBackBuffer{};

    // p5 Metal: no FBOs — kept for the shared OnFrameBegin shape (always null).
    void* pFB{ nullptr };

    SDL_Window* m_window{};

    // Substrate (plain-C++ facades; ObjC objects stay inside their .mm TUs).
    // NOTE: named MtlDev, NOT Device — the engine global Device
    // (IRender_device) must stay reachable inside CHW methods (GL rule:
    // glHW.h names its context member m_context for the same reason).
    xray::metal::MetalDevice MtlDev;
    xray::metal::MetalStateCache Pipelines;

    // Frame capture state (mtlRuntime.mm). CommandBuffer: id<MTLCommandBuffer>,
    // one per frame, created in BeginScene, presented in Present.
    void* CommandBuffer{ nullptr };
    // Current swapchain drawable texture (id<MTLTexture>), borrowed.
    void* BackBufferTexture{ nullptr };

    pcstr AdapterName;
    pcstr MetalVersionString;
    bool ComputeShadersSupported{ true }; // MTLComputeCommandEncoder always available
};

struct texture_upload_unit
{
    // Metal has no texture-binding point for uploads (replaceRegion /
    // blit encoder); the unit is a no-op scope marker like on desktop GL.
    explicit texture_upload_unit(u32 /*dim*/) {}
};

extern ECORE_API CHW HW;
} // namespace xray::render::RENDER_NAMESPACE
