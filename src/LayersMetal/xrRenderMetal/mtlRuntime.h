#pragma once
// p5 Metal device layer — pass-manager / runtime surface (implemented in
// mtlRuntime.mm). The CBackend runtime header (mtlR_Backend_Runtime.h, .cpp
// side) records state here; the actual MTLRenderCommandEncoder is owned by the
// pass manager and (re)created whenever the render-target identity or a clear
// demands it.
//
// DUAL-SAFE HEADER: device .mm TUs compile this WITHOUT the engine stdafx
// (ObjC BOOL vs engine BOOL) — plain C types only; MTL objects cross as void*.
//
// Encoder contract:
//  - One command buffer per frame (CHW::BeginScene → Present).
//  - Encoders switch when pRT/pZB identity changes (Metal render passes bind
//    attachments up front, unlike GL's FBO re-attach).
//  - Constants: set_Constants selects a staging block sized from the constant
//    table's reflection offsets; draws snapshot it into the per-frame ring and
//    bind it (per-draw isolation — see metal_devicetest race notes).
//  - Texture stages: CTexture::apply_* (mtlSH_Texture.mm) records stage →
//    texture here; the draw path binds the recorded table.

#include <cstddef>
#include <cstdint>

#include "mtlState.h"

namespace xray::render::RENDER_NAMESPACE
{
// --- frame / pass lifecycle (mtlHW.mm / mtlRuntime.mm) ----------------------
void MtlFrameBegin(); // new command buffer
void MtlFrameEnd(); // end encoder; commit (no present)
void MtlInvalidatePass(); // end current encoder, forget identity

// --- targets ----------------------------------------------------------------
// Record target changes; encoder is (re)created lazily at the next draw/clear.
// rts: up to 4 color attachments (id<MTLTexture>), zb: depth attachment.
void MtlTargetsChanged(void* const* rts, const void* zb);

// Clears. Implemented as dedicated clear passes (end current encoder, pass
// with LoadActionClear, re-record identity).
void MtlClearColor(void* rt, float r, float g, float b, float a);
void MtlClearDepth(void* zb, float depth, int stencil /* -1 = leave stencil */);
bool MtlClearColorRect(void* rt, float r, float g, float b, float a, uint32_t numRects,
    const int32_t* rects /* l,t,r,b quads */);
bool MtlClearDepthRect(void* zb, float depth, uint32_t numRects, const int32_t* rects);

// Copy a whole texture (same format/size) — RT blits (menu composite etc.).
void MtlBlit(void* srcTex, void* dstTex);
// Blit the current swapchain drawable into a target texture (scaled to fit).
void MtlBlitFromBackBuffer(void* dstTex, uint32_t width, uint32_t height);

// --- viewport / scissor -------------------------------------------------------
void MtlSetViewport(float x, float y, float w, float h, float minD, float maxD);
void MtlSetScissor(bool enabled, int32_t l, int32_t t, int32_t r, int32_t b);

// --- state -------------------------------------------------------------------
// mtlState::Apply() records the simulated DX9 state into the pass manager.
void MtlApplyRecordedState(const mtlState* state);
// Direct setters (CBackend::set_Z etc. — values are D3D enum raw values).
void MtlSetCull(uint32_t d3dCullMode);
void MtlSetDepth(uint32_t enable, uint32_t func, uint32_t writeMask);
void MtlSetStencil(uint32_t enable, uint32_t func, uint32_t ref, uint32_t mask, uint32_t writeMask,
    uint32_t fail, uint32_t pass, uint32_t zfail);
void MtlSetBlend(uint32_t enable, uint32_t src, uint32_t dst, uint32_t srcAlpha, uint32_t dstAlpha,
    uint32_t op, uint32_t opAlpha, uint32_t colorMask);
void MtlSetFillMode(uint32_t mode);
void MtlSetAlphaRef(uint32_t value);

// --- constants ----------------------------------------------------------------
// Select the staging block for a pass; sizes come from the constant table's
// reflection offsets (computed by the .cpp-side caller).
void MtlConstBegin(uint32_t vsSize, uint32_t psSize);
// stage: mtl_const_stage (0=vs,1=ps,2=gs,3=pp). Writes min(bytes,size) into
// the stage image at offset.
void MtlConstWrite(uint32_t stage, uint32_t offset, uint32_t size, const void* data, uint32_t bytes);

// --- texture stages -------------------------------------------------------------
// CTexture::apply_normal/apply_seq record the stage binding here (pSurface).
void MtlRecordTextureStage(uint32_t stage, void* texture);
void MtlClearTextureStages();

// --- draw ----------------------------------------------------------------------
// Topology already translated (0=point,1=linelist,2=linestrip,3=trilist,
// 4=tristrip,5=trifan). All payloads are plain: gathered by the .cpp runtime.
struct MtlDrawState
{
    void* vb{ nullptr }; // id<MTLBuffer> (arena-owned)
    uint32_t vbStride{ 0 };
    void* ib{ nullptr }; // id<MTLBuffer> or nullptr (non-indexed)
    const void* declElements{ nullptr }; // D3DVERTEXELEMENT9 array
    uint32_t declCount{ 0 };
    void* vs{ nullptr }; // MtlStageRefl* (SVS::sh payload)
    void* ps{ nullptr }; // MtlStageRefl* (SPS::sh payload)
    void* pp{ nullptr }; // MtlShaderPair* (SPP::pp payload; wins over vs/ps)
    const mtlState* state{ nullptr }; // per-pass recorded state or null
};
void MtlDrawIndexed(uint32_t topology, uint32_t indexCount, uint32_t startI, uint32_t baseV,
    const MtlDrawState& ds);
void MtlDrawArrays(uint32_t topology, uint32_t startV, uint32_t indexCount, const MtlDrawState& ds);

// Vertex layout: current DX9 declaration (elements+count) for the next PSO.
// The pass manager builds/caches the MTLVertexDescriptor against the VS's
// [[attribute(N)]] reflection.
void MtlSetVertexLayout(const void* elements, uint32_t count);

// --- occlusion queries (mtlRuntime.mm; QueryHelper.h USE_METAL inlines) ---------
// v1: handle-allocating placeholders that always report S_FALSE (pending) so
// occlusion-culled geometry is conservatively drawn. Real
// MTLCounterSampleBuffer-based resolution arrives with p5 t3.
void* MtlCreateOcclusionQuery();
void MtlReleaseOcclusionQuery(void* query);
void MtlBeginOcclusionQuery(void* query);
void MtlEndOcclusionQuery(void* query);
int32_t MtlGetQueryDataStatus(void* query, void* data, uint32_t dataSize); // 0=S_OK,1=S_FALSE,else E_FAIL

// --- device handles for the renderer .mm classes (mtlHW.mm owns substrate) ------
void* MtlSharedDevice(); // id<MTLDevice> borrowed
void* MtlSharedQueue(); // id<MTLCommandQueue> borrowed
void* MtlCurrentCommandBuffer(); // id<MTLCommandBuffer> borrowed (frame CB)
// Arena ownership (see mtl_device.h notes): resources created by the renderer
// device classes register here for teardown release.
void* MtlArenaRetain(void* obj); // stores obj, returns it
void MtlArenaRelease(void* obj);
} // namespace xray::render::RENDER_NAMESPACE
