// mtlRuntime.mm — the Metal pass manager (p5 t2 device layer).
//
// Owns the per-frame command buffer and the current MTLRenderCommandEncoder,
// translating the recorded DX9-style state (CBackend runtime + mtlState
// recorder) onto Metal's render-pass/encoder model:
//   - encoders switch when the RT/ZB identity changes (Metal binds
//     attachments up front, unlike GL FBO re-attach);
//   - clears run as dedicated passes (LoadActionClear), attachments are
//     Load-ed afterwards within the frame (Store on every end);
//   - constants: per-pass staging block, snapshotted per draw into a ring
//     buffer bound at [[buffer(0)]] for both stages (per-draw isolation);
//   - textures/samplers: stage-indexed tables (translator mirrors DX9 stage
//     into texture/sampler slots), bound per draw from shader reflection.
//
// Device-side TU: compiled WITHOUT the engine stdafx (ObjC BOOL rule); all
// engine-type adaptation happened in mtlR_Backend_Runtime.h.
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#include <sys/stat.h> // launch166: S13 dump mkdir

#include "mtlRuntime.h"
#include "mtlShader.h"
#include "mtl_dx9_map.h"
#include "mtl_device.h"
#include "mtl_state.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime> // p5 launch219: wall-clock era switch
#include <algorithm>
#include <array>
#include <cctype>
#include <map>
#include <set>
#include <string>
#include <vector>

// Host-side float4 (MTL vector types are device-only).
struct Float4
{
	float x, y, z, w;
};

// launch302: DX9 dynamic-stream orphaning (mtlBufferUtils.cpp). Frame gen
// drives slot rotation on Map(flush); binds resolve the baked base handle
// to the current slot so orphaning is invisible to cached geom records.
extern uint64_t g_mtlStreamFrameGen;
void* MtlStreamBufferCurrent(void* handle);

// p5 diag: draw-path counters (read via MtlDbgDrawStats from CHW::Present).
static uint64_t g_dbgDrawOK = 0, g_dbgDrawNoShader = 0, g_dbgDrawNoPso = 0;
static uint64_t g_lastSlotOff = 0; // p5 accgpu: ring slot of the last snapshot
// p5 accgpu: post-commit ring-slot re-read (aliasing/wrap-overwrite probe)
static void* g_accSlotRing = nullptr;
static uint64_t g_accSlotOff = 0;
static uint64_t g_accExpect0 = 0;
// launch166: visibility-sample counters — DECISIVE fragment-presence probe.
// g_visE13: samples rasterized by the S13 replay pass (dedicated CB, waited).
// g_visLiveBuf: samples rasterized by the just-closed LIVE $user$position pass
// (frame CB, committed+waited by the readback flush). Env XR_METAL_VIS=1.
static id<MTLBuffer> g_visE13 = nil;
static id<MTLBuffer> g_visLiveBuf = nil;
// launch279b: fragment counter for the live $user$accum pass (sun canary)
static id<MTLBuffer> g_visAccumBuf = nil;
// p5 diag: RT texture pointer -> creation name ("$user$position" etc.), so the
// periodic content scan can attribute dead render targets to R2 phases.
// (launch166: definition moved above MtlPassManager for the VIS gate.)
static std::map<void*, std::string> g_mtlRtNames;
// p5 diag: entry + silent-exit counters (EmitDraw returns false without these
// counters on some paths; scene-draw starvation hunt).
static uint64_t g_dbgDrawEnter = 0, g_dbgDrawNoCb = 0, g_dbgDrawNoEnc = 0, g_dbgDrawNoIb = 0;
// p5 diag: silent-exit hunt round 2 — fanVerts<3 drops + per-topology arrivals.
static uint64_t g_dbgFanDrop = 0, g_dbgFanOK = 0;
static uint64_t g_dbgEncoders = 0, g_dbgRtSwitches = 0;
// p6: exported by MetalDevice::Present (mtl_device.mm) — real frame clock.
namespace xray::metal { extern uint64_t g_mtlPresentCount; }
using xray::metal::g_mtlPresentCount;
static int g_pgGate = 0; // p5: position-pass-end counter (postgeom + canaryG tick)
// launch128: canaryI pass-end append state. In-pass canaries get overwritten
// by the real (zero-writing) draws that follow them in the same pass — the
// append encodes AFTER every engine draw, right before the readback commit.
struct MtlAppendCanary
{
	id<MTLRenderPipelineState> pso = nil;
	id<MTLBuffer> ring = nil, vb = nil, ib = nil;
	id<MTLBuffer> cb = nil; // launch130: CB bytes snapshotted at capture (the
	                        // ring slot is overwritten by every later draw)
	id<MTLTexture> vtex[8] = {};        // launch133: VS-stage textures exactly
	id<MTLSamplerState> vsamp[8] = {};  // as BindDraw bound (missing VS texture
	                                     // bindings => garbage VS => no frags)
	id<MTLTexture> ptex[8] = {};        // launch155: PS-stage textures/samplers
	id<MTLSamplerState> psamp[8] = {};  // (live-PS S13 needs its own bindings)
	NSUInteger ringOff = 0, ibOff = 0, idxCount = 0;
	NSInteger baseV = 0;
	uint32_t stride = 0; // launch134: for the V-draw discriminator PSO
	id<MTLRenderPipelineState> sPso = nil; // launch138: S-draw — pair VS + white
	id<MTLRenderPipelineState> s2Pso = nil; // launch144: S2 — w-abs-patched VS +
	                                        // green PS (clipper hypothesis)
	id<MTLRenderPipelineState> s4Pso = nil; // launch145: S4 — clip-coords readout VS
	id<MTLRenderPipelineState> s5Pso = nil; // launch145: S5 — z=0.5w fix only
	id<MTLRenderPipelineState> s6Pso = nil; // launch145: S6 — w=-w flip only
	id<MTLRenderPipelineState> s7Pso = nil; // launch147: S7 — clipdbg readout + z
	                                        // forced (histogram of true z/w)
	id<MTLRenderPipelineState> s8Pso = nil; // launch147: S8 — remap z'=0.5z+0.5w
	id<MTLRenderPipelineState> s9Pso = nil; // launch147: S9 — remap z'=0.5z+w
	id<MTLRenderPipelineState> s11Pso = nil; // launch149: S11 — z'=z-0.5w
	id<MTLRenderPipelineState> s12Pso = nil; // launch149: S12 — z'=clamp(z,εw,(1-ε)w)
	id<MTLRenderPipelineState> s13Pso = nil; // launch154: S13 — live VS + LIVE PS
	std::string name; // launch166: pair name for the headless-replay dump
	int sSlot = -1;                        // PS onto a clean scratch RT
	bool valid = false;
};
static MtlAppendCanary s_appI; // legacy single slot
static std::vector<MtlAppendCanary> s_appQ; // launch129: up to 8 captures per window
// launch145: engine-VS MSL patcher for the S4/S5/S6 probes. Optionally adds an
// output struct field (after the gl_Position declaration) and a statement
// before every 'return out;'. Caches nil results per (VS-name, key) so a
// failed patch never recompiles.
static void mtlLog(const char* fmt, ...);
static id<MTLFunction> MtlPatchVsFn(id<MTLDevice> dev, const std::string& msl,
                                    const char* fieldDecl, const char* stmt, const char* tag,
                                    const std::string& key,
                                    std::map<std::string, id<MTLFunction>>& cache)
{
    auto it = cache.find(key);
    if (it != cache.end())
        return it->second;
    std::string src = msl;
    if (fieldDecl)
    {
        const std::string anchor = "float4 gl_Position [[position]]";
        size_t a = src.find(anchor);
        if (a == std::string::npos)
        {
            mtlLog("! p5 canaryI: %s patch: no gl_Position field (%s)", tag, key.c_str());
            cache[key] = nil;
            return nil;
        }
        size_t e = src.find(';', a);
        src.insert(e + 1, std::string("\n    ") + fieldDecl + ";");
    }
    const std::string pat = "return out;";
    size_t p = 0, n = 0;
    while ((p = src.find(pat, p)) != std::string::npos)
    {
        // launch145 bugfix: stmt was injected WITHOUT a terminating ';' =>
        // every S4/S5/S6 compile died 'expected ; after expression'.
        std::string ins = std::string(stmt) + ";\n    return out;";
        src.replace(p, pat.size(), ins);
        p += ins.size();
        n++;
    }
    if (!n)
    {
        mtlLog("! p5 canaryI: %s patch: no 'return out;' (%s)", tag, key.c_str());
        cache[key] = nil;
        return nil;
    }
    NSError* err = nil;
    id<MTLLibrary> lib =
        [dev newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()]
                          options:nil
                            error:&err];
    id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"main0"] : nil;
    if (!fn)
        mtlLog("! p5 canaryI: %s compile failed: %s", tag,
            err ? [[err localizedDescription] UTF8String] : "?");
    cache[key] = fn;
    return fn;
}
static uint64_t g_dbgTopoEnter[8] = {};

// Device-side logging: engine Log() is a header template (no C symbol); the
// detached launch redirects stderr into the game log, so fprintf lands there.
static void mtlLog(const char* fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	fprintf(stderr, "%s\n", buf);
	fflush(stderr);
}
#define Log mtlLog

// D3D shims not pulled by mtlState.h
#ifndef D3DPT_POINTLIST
#define D3DPT_POINTLIST 1
#endif

#define MTL_D3DTADDRESS_WRAP 1
#define MTL_D3DTADDRESS_CLAMP 2
#define MTL_D3DTADDRESS_BORDER 3
#define MTL_D3DTADDRESS_MIRROR 4
#define MTL_D3DTADDRESS_CLAMPV 5

// launch114: the Metal debug layer raises its validation failures through
// NSAssertionHandler; the engine's fatal path then ABORTS the process,
// so debug-layer runs die on the first (menu-era) violation and never
// reach the marsh. When MTL_DEBUG_LAYER is set, install a log-only
// handler on the render thread: violations get logged (deduped) and
// execution continues — the offending draws are still discarded by
// validation, which is exactly the ground truth we want.
@interface MtlLogAssertionHandler : NSAssertionHandler
@end
@implementation MtlLogAssertionHandler
// NSAssert's designated entry points — MUST override these or the default
// implementation raises NSAssertionException (launch157 abort: our
// handleAssertionInThread: override below was never called).
- (void)handleAssertionInFile:(NSString*)fileName
                     selector:(NSString*)selector
                         line:(NSInteger)line
                    condition:(NSString*)condition
{
	[self handleAssertionInThread:[NSThread currentThread]
	                         file:fileName
	                         line:line
	                    condition:condition
	                      description:selector];
}
- (void)handleAssertionInFile:(NSString*)fileName
                     selector:(NSString*)selector
                         line:(NSInteger)line
                    condition:(NSString*)condition
                  description:(NSString*)description
{
	(void)selector;
	[self handleAssertionInThread:[NSThread currentThread]
	                         file:fileName
	                         line:line
	                    condition:condition
	                      description:description];
}
// NSAssertWithUserInfo — the selector the Metal debug layer actually uses
// (launch158: raw assert + raise persisted until this override).
- (void)handleAssertionInFile:(NSString*)fileName
                     selector:(NSString*)selector
                         line:(NSInteger)line
                     userInfo:(id)userInfo
                    condition:(NSString*)condition
                  description:(NSString*)description
{
	(void)selector;
	(void)userInfo;
	[self handleAssertionInThread:[NSThread currentThread]
	                         file:fileName
	                         line:line
	                    condition:condition
	                      description:description];
}
- (void)handleFatalAssertionInFile:(NSString*)fileName
                          selector:(NSString*)selector
                              line:(NSInteger)line
                          userInfo:(id)userInfo
                         condition:(NSString*)condition
                       description:(NSString*)description
{
	(void)userInfo;
	[self handleAssertionInFile:fileName selector:selector line:line
	                    condition:condition description:description];
}
- (void)handleAssertionInThread:(NSThread*)thread
                           file:(NSString*)fileName
                           line:(NSInteger)line
                      condition:(NSString*)condition
                    description:(NSString*)description
{
	static std::set<std::string>* seen = new std::set<std::string>();
	static int s_vaLogged = 0;
	const std::string d = description ? [description UTF8String] : "?";
	if (s_vaLogged < 64 && seen->insert(d.substr(0, 120)).second)
	{
		s_vaLogged++;
		Log("! MTL-VALIDATION#%d: %s", s_vaLogged, d.c_str());
	}
	// Return normally — no exception, no abort; execution continues.
}
- (void)handleFatalAssertionInThread:(NSThread*)thread
                                file:(NSString*)fileName
                                line:(NSInteger)line
                           condition:(NSString*)condition
                       description:(NSString*)description
{
	[self handleAssertionInThread:thread file:fileName line:line
	                  condition:condition description:description];
}
- (void)handleFatalAssertionInFile:(NSString*)fileName
                          selector:(NSString*)selector
                              line:(NSInteger)line
                         condition:(NSString*)condition
{
	[self handleAssertionInFile:fileName selector:selector line:line
	                    condition:condition description:selector];
}
- (void)handleFatalAssertionInFile:(NSString*)fileName
                          selector:(NSString*)selector
                              line:(NSInteger)line
                         condition:(NSString*)condition
                       description:(NSString*)description
{
	[self handleAssertionInFile:fileName selector:selector line:line
	                    condition:condition description:description];
}
@end

static void MtlInstallValidationGuard()
{
	if (!getenv("MTL_DEBUG_LAYER"))
		return;
	NSThread* t = [NSThread currentThread];
	if ([[t threadDictionary] objectForKey:@"MtlGuardInstalled"])
		return; // this thread already guarded
	[[t threadDictionary] setObject:@YES forKey:@"MtlGuardInstalled"];
	MtlLogAssertionHandler* h = [MtlLogAssertionHandler new]; // process-lifetime
	[[t threadDictionary] setObject:h forKey:NSAssertionHandlerKey];
	Log("- xrMetal: validation-continue assertion handler installed (main-thread=%d)",
	    (int)[t isMainThread]);
}

namespace xray::render::RENDER_NAMESPACE
{
uint64_t MtlDbgDrawStats(int idx)
{
	switch (idx)
	{
	case 1: return g_dbgDrawNoShader;
	case 2: return g_dbgDrawNoPso;
	case 3: return g_dbgDrawEnter;
	case 4: return g_dbgDrawNoCb;
	case 5: return g_dbgDrawNoEnc;
	case 6: return g_dbgDrawNoIb;
	case 7: return g_dbgFanDrop;
	case 8: return g_dbgFanOK;
	case 20: return g_dbgEncoders;
	case 21: return g_dbgRtSwitches;
	case 10: return g_dbgTopoEnter[0];
	case 11: return g_dbgTopoEnter[1];
	case 12: return g_dbgTopoEnter[2];
	case 13: return g_dbgTopoEnter[3];
	case 14: return g_dbgTopoEnter[4];
	case 15: return g_dbgTopoEnter[5];
	default: return g_dbgDrawOK;
	}
}

	// mtlShaderCompile.mm: XR_METAL_CLIPFIX VS injection (launch151: raw-int
	// masked VS variants bypass CreateFunction and must apply it themselves).
	NSString* MtlClipFixApply(NSString* src);

namespace
{
	using metal::MetalDevice;

	using metal::MetalStateCache;
	using metal::PipelineDesc;
	using metal::DepthStencilDesc;
	using metal::BlendDesc;
	using metal::VertexAttr;

	constexpr uint32_t kMaxStage = 36; // CTexture::mtMaxCombinedShaderTextures
	constexpr uint64_t kRingSize = 64ull * 1024 * 1024;

	inline uint32_t Align16(uint32_t v) { return (v + 15u) & ~15u; }
	inline uint64_t Align256(uint64_t v) { return (v + 255ull) & ~255ull; }

	// Built-in programs for flips/fills (no engine-shader dependency).
	const char* kBlitMSL = R"metal(
#include <metal_stdlib>
using namespace metal;
struct BlitOut { float4 pos [[position]]; float2 uv; };
vertex BlitOut xrblit_vs(uint vid [[vertex_id]], constant float4& params [[buffer(0)]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2)); // (0,0)(2,0)(0,2)
    BlitOut o;
    o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, params.z, 1.0);
    o.uv = float2(p.x * params.x, p.y * params.y);
    return o;
}
fragment float4 xrblit_ps(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return t.sample(s, in.uv);
}
fragment float4 xrfill_ps(BlitOut in [[stage_in]], constant float4& params [[buffer(0)]]) {
    return params;
}
// p6: MRT variants — the probe pipeline must output EVERY attachment of the
// pass it draws into (a 1-RT pipeline into a 3-RT pass = silently rejected draw).
// NOTE: old-school struct returns — [[color(N)]] fragment ARGS are Metal 3 and
// the runtime compiles kBlitMSL at the DEFAULT language version, which parsed
// them as plain locals: valid pipeline, legal draw, discarded outputs (the
// fill that produced no pixels).
struct Fill2 { float4 a [[color(0)]]; float4 b [[color(1)]]; };
struct Fill3 { float4 a [[color(0)]]; float4 b [[color(1)]]; float4 c [[color(2)]]; };
struct Fill4 { float4 a [[color(0)]]; float4 b [[color(1)]]; float4 c [[color(2)]];
    float4 d [[color(3)]]; };
fragment Fill2 xrfill2_ps(BlitOut in [[stage_in]], constant float4& params [[buffer(0)]])
    { return Fill2{ params, params }; }
fragment Fill3 xrfill3_ps(BlitOut in [[stage_in]], constant float4& params [[buffer(0)]])
    { return Fill3{ params, params, params }; }
fragment Fill4 xrfill4_ps(BlitOut in [[stage_in]], constant float4& params [[buffer(0)]])
    { return Fill4{ params, params, params, params }; }
// p6: zero-binding fallback — hardcoded triangle, hardcoded red, no buffers.
vertex float4 xrtri_vs(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}
// p6 band-hunt: replay VS — engine VB bytes + engine WVP bytes with the
// SAME row-vector semantics as engine MSL (v * float4x4), vertex-id driven
// through a copied index list. Zero dependence on engine decls/descriptors.
struct XrReplayU { float4x4 wvp; uint stride; uint baseV; };
vertex float4 xrreplay_vs(uint vid [[vertex_id]],
                          const device uchar* vb [[buffer(1)]],
                          const device ushort* ib [[buffer(2)]],
                          constant XrReplayU& u [[buffer(0)]])
{
    uint i = uint(ib[vid]) + u.baseV;
    const device float* p = (const device float*)(vb + size_t(i) * u.stride);
    return float4(p[0], p[1], p[2], 1.0) * u.wvp;
}
fragment float4 xrred1_ps() { return float4(1.0, 0.0, 0.0, 1.0); }
fragment Fill2 xrred2_ps() { return Fill2{ float4(1,0,0,1), float4(1,0,0,1) }; }
fragment Fill3 xrred3_ps()
    { float4 r(1,0,0,1); return Fill3{ r, r, r }; }
fragment Fill4 xrred4_ps()
    { float4 r(1,0,0,1); return Fill4{ r, r, r, r }; }
)metal";

	// p6 band-hunt: last big position-pass draw snapshot (XR_METAL_REPLAY)
	void* g_rpVb = nullptr;
	void* g_rpIb = nullptr;
	uint32_t g_rpStride = 0, g_rpStartI = 0, g_rpBaseV = 0, g_rpPrimCnt = 0;
	uint8_t g_rpWvp[64] = {};
	bool g_rpOk = false;
	bool g_rpDrew = false;
	uint32_t g_rpFront = 0;
	bool g_rpDrew2 = false;

	// p6 band-hunt: defined in xrRender_R2/r2.cpp; dumps the culling ViewBase
	// planes + stamp + mFullTransform (called from endEncoder, see frusprobe).
	extern "C" void xrMetalDumpFrustum();

	struct MtlPassManager
	{
		MetalDevice* dev = nullptr;
		MetalStateCache* cache = nullptr;

		id<MTLCommandBuffer> cb = nil;
		id<MTLRenderCommandEncoder> enc = nil;
		// RC#5: attachment-format snapshot of the CURRENT encoder's rpd taken
		// at creation — PSOs must match the framebuffer they render into, not
		// the mutable pm.rt[]/pm.zb (divergence => Metal silently discards
		// every draw; launch111 debug-layer stencil assert).
		int attColorFmt[4] = { 0, 0, 0, 0 };
		int attColorCount = 0;
		// p6: the ACTUAL texture bound as color0 of the live rpd (may differ
		// from rt[0] if a view/alias is attached) — probes read this.
		id<MTLTexture> rpdAtt0 = nil;
		int attDepthFmt = 0;

		// Pass identity (borrowed id<MTLTexture> handles)
		void* rt[4] = {};
		void* zb = nullptr;
		bool identityDirty = true;
		std::set<void*> touched; // attachments written earlier this frame

		// Live encoder state (raw D3D values)
		double vpX = 0, vpY = 0, vpW = 0, vpH = 0, vpMin = 0, vpMax = 1;
		bool scissorEn = false;
		int32_t scL = 0, scT = 0, scR = 0, scB = 0;
		bool depthEn = true;
		int depthFunc = 4; // D3DCMP_LESSEQUAL
		bool depthWrite = true;
		// p6 diag: last DSS/encoder bound by applyEncoderState (drawZ match).
		void* dbgLastDss = nullptr;
		void* dbgLastEnc = nullptr;
		bool stencilEn = false;
		uint32_t stRef = 0, stMask = 0xff, stWMask = 0xff;
		int stFunc = 8, stFail = 1, stPass = 1, stZFail = 1; // KEEP
		BlendDesc blend; // .enabled=false default (opaque)
		int cull = 3; // D3DCULL_CCW
		int fill = 1; // SOLID
		float alphaRef = 0;
		float globalBias = 0;
		const mtlState* recorded = nullptr;

		// Current vertex layout (borrowed DX9 decl)
		const D3DVERTEXELEMENT9* declElems = nullptr;
		uint32_t declCount = 0;

		// Stage tables (written by CTexture apply paths via MtlRecordTextureStage)
		void* stageTex[kMaxStage] = {};

		// p5 launch196: screen dimensions for VS screen_res fallback = max
		// viewport seen (passes render smaller RTs; the backbuffer pass is the
		// screen).
		float screenW = 0, screenH = 0;

		// p5 launch191: DX9/GL semantics let a pass sample the very RT it
		// renders to (combine_1 reads s_diffuse=rt_Color while rendering to
		// rt_Color). Immediate-mode APIs read the pre-pass content; Metal TBDR
		// gives undefined results (observed: black). Before opening an encoder,
		// any attachment texture that is also bound for sampling is copied to a
		// scratch and the sample remapped — GL's read-old semantics.
		std::map<void*, void*> fbRemap;

		// Constants
		std::vector<uint8_t> staging;
		uint32_t vsSize = 0, psSize = 0, psBase = 0;
		id<MTLBuffer> ring = nil;
		uint64_t ringOff = 0;

		// Presentation bookkeeping
		id<MTLTexture> lastDrawable = nil;

		// p5 DIAG (launch102): position RT whose pass just ended (postgeom readback)
		void* pendingPostGeom = nullptr;
		void* pendingPostGeomAlb = nullptr; // p5 launch184: albedo at same pass-end
		void* pendingAccum = nullptr;       // p5 launch255: accum RT at pass-end
		void* pendingDefferTex = nullptr;   // p5 launch227: diffuse bound to a gbuffer draw
		void* pendingMatTex = nullptr;      // p5 launch231: volume material bound to sun
		void* pendingSmapTex = nullptr;     // p5 launch232: sampled sun shadow map

		// Built-ins
		id<MTLFunction> blitVs = nil, blitPs = nil, fillPs = nil;
		id<MTLLibrary> blitLib = nil; // p6: kept for MRT fill entries
		std::map<uint32_t, id<MTLRenderPipelineState>> blitPso; // key: (dstFmt<<1|fill)
		std::map<uint32_t, id<MTLRenderPipelineState>> fillZPso; // depth-rect fills

		void initBuiltins();
		void endEncoder();
		void ensureEncoder();
		void applyEncoderState();
		void markTouched();
		id<MTLRenderPipelineState> blitPipeline(MTLPixelFormat fmt, bool fillMode, bool depthPass,
	                                        int dfmt = 0);
		// p6 band-hunt: fill pipeline matching the CURRENT pass's attachment set
		// (XR_METAL_FILLRT probe); keyed by the format vector.
		id<MTLRenderPipelineState> fillPipelineMRT();
		std::map<std::vector<int>, id<MTLRenderPipelineState>> fillMrtPso;
	};

	MtlPassManager& PM()
	{
		static MtlPassManager m;
		return m;
	}

	void MtlPassManager::initBuiltins()
	{
		if (blitVs)
			return;
		id<MTLDevice> device = (__bridge id<MTLDevice>)dev->Device();
		NSError* err = nil;
		id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:kBlitMSL]
		                                         options:nil
		                                           error:&err];
		if (!lib)
		{
			const char* msg = err ? [[err localizedDescription] UTF8String] : "?";
			Log("! xrRenderMetal: builtin blit library failed: %s", msg);
			return;
		}
		blitVs = [lib newFunctionWithName:@"xrblit_vs"];
		blitPs = [lib newFunctionWithName:@"xrblit_ps"];
		fillPs = [lib newFunctionWithName:@"xrfill_ps"];
		blitLib = lib;
	}

	void MtlPassManager::endEncoder()
	{
		if (enc)
		{
			// p6 band-hunt: XR_METAL_RECTDBG2=<substr> — dump EVERY attachment
			// (name + dims) of every closed pass whose color0 name contains
			// substr. Metal clamps rasterization to the smallest attachment;
			// a narrow rt[1..3] would clip the whole MRT pass.
			{
				static const char* s_rv2 = getenv("XR_METAL_RECTDBG2");
				static std::set<std::string> s_rv2Seen;
				if (s_rv2 && rt[0] && dev && s_rv2Seen.size() < 64)
				{
					const char* rn = MtlDbgRTGetName(rt[0]);
					if (rn && strstr(rn, s_rv2))
					{
						NSMutableString* line = [NSMutableString stringWithFormat:
						    @"- p6 rtatt: %s", rn];
						for (int ai = 0; ai < 4; ai++)
						{
							id<MTLTexture> at =
							    rt[ai] ? (__bridge id<MTLTexture>)rt[ai] : nil;
							[line appendFormat:@" c%d=%lux%lu", ai,
							 at ? (unsigned long)at.width : 0UL,
							 at ? (unsigned long)at.height : 0UL];
						}
						id<MTLTexture> zt = zb ? (__bridge id<MTLTexture>)zb : nil;
						[line appendFormat:@" z=%lux%lu vp=%.0fx%.0f", zt ? (unsigned long)zt.width : 0UL,
						 zt ? (unsigned long)zt.height : 0UL, vpW, vpH];
						if (s_rv2Seen.insert(line.UTF8String).second)
							Log("%s", line.UTF8String);
					}
				}
			}
			// p6 band-hunt: XR_METAL_FILLRT=<substr> — coverage truth: draw a
			// fullscreen red fill (MRT-matching pipeline, depth Always+no-write,
			// cull off) as the LAST op of a pass whose color0 matches substr.
			// rtdump then shows how far that pass's raster actually reaches.
			// (First fill attempt used a 1-RT pipeline => rejected in the 3-RT
			// gbuffer pass, and Never depth => both silently dropped.)
			{
				static const char* s_frt = getenv("XR_METAL_FILLRT");
				static int s_frtN = 0;
				static id<MTLDepthStencilState> s_alwaysDss = nil;
				if (s_frt && s_frtN < 30000 && rt[0] && dev && g_dbgEncoders > 2000)
				{
					const char* rn = MtlDbgRTGetName(rt[0]);
					if (rn && strstr(rn, s_frt))
					{
						id<MTLRenderPipelineState> pso = fillPipelineMRT();
						if (pso)
						{
							id<MTLDevice> mdev = (__bridge id<MTLDevice>)dev->Device();
							if (!s_alwaysDss)
							{
								MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
								dd.depthCompareFunction = MTLCompareFunctionAlways;
								dd.depthWriteEnabled = false;
								s_alwaysDss = [mdev newDepthStencilStateWithDescriptor:dd];
							}
							if (s_alwaysDss)
							{
								s_frtN++;
								// Own the viewport/scissor: the engine's last
								// per-draw viewport may be a sub-rect, which
								// would squeeze this NDC-space fill too.
								id<MTLTexture> t0 =
								    (__bridge id<MTLTexture>)rt[0];
								[enc setViewport:(MTLViewport){ 0.0, 0.0,
								    (double)t0.width, (double)t0.height, 0.0,
								    1.0 }];
								[enc setScissorRect:(MTLScissorRect){ 0, 0,
								    t0.width, t0.height }];
								[enc setDepthStencilState:s_alwaysDss];
								[enc setCullMode:MTLCullModeNone];
								[enc setTriangleFillMode:MTLTriangleFillModeFill];
								// Engine per-draw depth bias is encoder state
								// too: a leftover big bias depth-clips this
								// z=0 triangle entirely (test passes, frags
								// vanish before the store — exactly what the
								// fillverify saw).
								[enc setDepthBias:0.0 slopeScale:0.0
								            clamp:1e30];
								[enc setRenderPipelineState:pso];
								[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
								         vertexCount:3];
								if (s_frtN <= 3 || s_frtN % 300 == 0)
									Log("- p6 fillrt: pass=%s atts=%d drawn #%d "
									    "engvp=%.0fx%.0f",
									    rn, attColorCount, s_frtN, vpW, vpH);
							}
						}
					}
				}
			}
			// p6 band-hunt: XR_METAL_REPLAY=1 — replay the captured engine draw
			// with the probe pipeline: same VB bytes + same WVP bytes, but my VS
			// (vertex-id, raw-byte fetch), red MRT PS, depth Always/no-write,
			// cull none, full viewport/scissor, bias zero. Red reaching x>2500
			// => engine per-draw pipeline state kills coverage; red stopping at
			// the band => the vertex data itself dies there.
			{
				static const bool s_rpen = !!getenv("XR_METAL_REPLAY");
				static id<MTLRenderPipelineState> s_rpPso = nil;
				static int s_rpN = 0;
				static int s_rpN2 = 0;
				const bool rpScren = rt[0] && MtlDbgRTGetName(rt[0]) &&
				                             strstr(MtlDbgRTGetName(rt[0]), "generic0");
				if (s_rpen && g_rpOk && rt[0] && dev && attColorCount &&
				    (s_rpN < 400 || (rpScren && s_rpN2 < 400)))
				{
					const char* rn = MtlDbgRTGetName(rt[0]);
					if (rn && (strstr(rn, "position") || rpScren))
					{
						if (rpScren)
							s_rpN2++;
						else
							s_rpN++;
						g_rpOk = false;
						g_rpFront = 0; // re-pick the biggest draw next frame
						id<MTLDevice> mdev = (__bridge id<MTLDevice>)dev->Device();
						if (!s_rpPso)
						{
							initBuiltins();
							id<MTLFunction> rvs =
							    [blitLib newFunctionWithName:@"xrreplay_vs"];
							const char* pfn = attColorCount == 1
							                        ? "xrred1_ps"
							                        : attColorCount == 2
							                              ? "xrred2_ps"
							                              : attColorCount == 3
							                                    ? "xrred3_ps"
							                                    : "xrred4_ps";
							id<MTLFunction> rps =
							    [blitLib newFunctionWithName:@(pfn)];
							if (rvs && rps)
							{
								PipelineDesc pd;
								pd.vs = (__bridge void*)rvs;
								pd.ps = (__bridge void*)rps;
								pd.attrs.clear();
								pd.colorFormats = std::vector<int>(
								    attColorFmt, attColorFmt + attColorCount);
								if (attDepthFmt)
								{
									pd.depthFormat = attDepthFmt;
									if (attDepthFmt ==
									    (int)MTLPixelFormatDepth32Float_Stencil8)
										pd.stencilFormat = attDepthFmt;
								}
								pd.depthEnabled = false;
								pd.blend.enabled = false;
								std::string e2;
								s_rpPso = (__bridge id<MTLRenderPipelineState>)
								    cache->Pipeline(dev->Device(), pd, e2);
								if (!s_rpPso)
									Log("! p6 replay: pipeline failed: %s",
									    e2.c_str());
							}
						}
						if (s_rpPso)
						{
							struct RpU
							{
								float wvp[16];
								uint32_t stride, baseV;
							};
							RpU u;
							std::memcpy(u.wvp, g_rpWvp, 64);
							u.stride = g_rpStride;
							u.baseV = g_rpBaseV;
							id<MTLBuffer> ub = [mdev
							    newBufferWithBytes:&u
							                length:sizeof(RpU)
							               options:MTLResourceStorageModeShared];
							uint32_t nIdx = g_rpPrimCnt * 3;
							if (nIdx > 600000)
								nIdx = 600000;
							id<MTLBuffer> ibc = [mdev
							    newBufferWithLength:nIdx * 2
							                options:MTLResourceStorageModeShared];
							const uint16_t* src =
							    (const uint16_t*)[(__bridge id<MTLBuffer>)g_rpIb
							                              contents] +
							    g_rpStartI;
							std::memcpy([ibc contents], src, nIdx * 2);
							id<MTLTexture> t0 = (__bridge id<MTLTexture>)rt[0];
							[enc setViewport:(MTLViewport){ 0.0, 0.0,
							    (double)t0.width, (double)t0.height, 0.0, 1.0 }];
							[enc setScissorRect:(MTLScissorRect){ 0, 0, t0.width,
							    t0.height }];
							MTLDepthStencilDescriptor* dd =
							    [MTLDepthStencilDescriptor new];
							dd.depthCompareFunction = MTLCompareFunctionAlways;
							dd.depthWriteEnabled = false;
							[enc setDepthStencilState:
							        [mdev newDepthStencilStateWithDescriptor:dd]];
							[enc setCullMode:MTLCullModeNone];
							[enc setTriangleFillMode:MTLTriangleFillModeFill];
							[enc setDepthBias:0.0 slopeScale:0.0 clamp:1e30];
							[enc setRenderPipelineState:s_rpPso];
							[enc setVertexBuffer:ub offset:0 atIndex:0];
							[enc setVertexBuffer:(__bridge id<MTLBuffer>)g_rpVb
							                offset:0
							               atIndex:1];
							[enc setVertexBuffer:ibc offset:0 atIndex:2];
							[enc drawPrimitives:MTLPrimitiveTypeTriangle
							        vertexStart:0
							        vertexCount:nIdx];
							g_rpDrew = !rpScren;
							g_rpDrew2 = rpScren;
							// CPU clip sim over the exact replay inputs: where are
							// these triangles supposed to land?
							{
								const float* m = (const float*)g_rpWvp;
								const uint8_t* vbB = (const uint8_t*)
								    [(__bridge id<MTLBuffer>)g_rpVb contents];
								const uint16_t* ii = (const uint16_t*)[ibc contents];
								unsigned nFront = 0, nBand = 0, nOut = 0;
								double maxNx = -9.9;
								double pxLo = 1e9, pxHi = -1e9; // expected screen px
								for (uint32_t k = 0; k < nIdx; k += 3)
								{
									bool anyFront = false;
									for (int c = 0; c < 3; c++)
									{
										uint32_t vi =
										    (uint32_t)ii[k + c] + g_rpBaseV;
										const float* q =
										    (const float*)(vbB +
										                 size_t(vi) * g_rpStride);
										float cw = q[0] * m[3] + q[1] * m[7] +
										         q[2] * m[11] + m[15];
										if (cw <= 0.01f)
											continue;
										anyFront = true;
										float cx = q[0] * m[0] + q[1] * m[4] +
										         q[2] * m[8] + m[12];
										double nx = cx / cw;
										if (nx > maxNx)
											maxNx = nx;
										if (nx >= -1.0 && nx <= 1.0)
										{
											double px = (nx * 0.5 + 0.5) * 3024.0;
											if (px < pxLo)
												pxLo = px;
											if (px > pxHi)
												pxHi = px;
										}
										if (nx > 0.524)
											nBand++;
										else if (nx < -1.0 || nx > 1.0)
											nOut++;
									}
									if (anyFront)
										nFront++;
								}
								Log("- p6 replaycpu: pass=%s tris=%u front=%u bandVerts=%u "
								    "outVerts=%u maxNdcX=%.3f px=[%.0f..%.0f]",
								    rn ? rn : "?", nIdx / 3, nFront, nBand, nOut, maxNx,
								    pxLo > pxHi ? -1.0 : pxLo, pxHi);
							}
							const float* wf = (const float*)g_rpWvp;
							Log("- p6 replay: drew nIdx=%u stride=%u baseV=%u "
							    "startI=%u primCnt=%u wrow=(%.4f %.4f %.4f %.4f)",
							    nIdx, g_rpStride, g_rpBaseV, g_rpStartI,
							    g_rpPrimCnt, wf[3], wf[7], wf[11], wf[15]);
						}
					}
				}
			}
			[enc endEncoding];
			enc = nil;
			markTouched();
			// p6: replay readback — commit+wait, scan the middle row of the
			// position color0 for the exact probe-red pattern (float16
			// R=1,G=0,B=0 => bytes 00 3c 00 00). Decisive: red pixels in the
			// band => engine pipeline state was the killer; none => the
			// matrix output itself dies at the line.
			if (g_rpDrew && rt[0] && dev)
			{
				g_rpDrew = false;
				[cb commit];
				[cb waitUntilCompleted];
				cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
				id<MTLTexture> a0r = rpdAtt0 ? rpdAtt0
				                             : (__bridge id<MTLTexture>)rt[0];
				uint32_t bppR = dev->TextureBpp(rt[0]);
				if (bppR && bppR <= 8)
				{
					uint32_t Wr = (uint32_t)a0r.width, Hr = (uint32_t)a0r.height,
					         Yr = (uint32_t)a0r.height / 2;
					// wvp14 fix: the old call passed Yr as MIP (840!) — invalid,
					// silently zero. Read the whole texture, scan row Yr.
					std::vector<uint8_t> rb(size_t(Wr) * Hr * bppR);
					std::string rerr;
					bool okR = dev->ReadbackSlice((void*)(__bridge void*)a0r,
					                              rb.data(), Wr * bppR, Wr, Hr, 0,
					                              0, rerr);
					int first = -1, last = -1, n = 0;
					for (uint32_t x = 0; x < Wr; x++)
					{
						const uint8_t* p = &rb[(size_t(Yr) * Wr + x) * bppR];
						if (p[0] == 0x00 && p[1] == 0x3c && p[2] == 0x00 &&
						    p[3] == 0x00)
						{
							n++;
							if (first < 0)
								first = (int)x;
							last = (int)x;
						}
					}
					const uint8_t* q1 = &rb[(size_t(Yr) * Wr + 100) * bppR];
					const uint8_t* q2 = &rb[(size_t(Yr) * Wr + 2600) * bppR];
					Log("- p6 replayrb: ok=%d y=%u bpp=%u redN=%d x=[%d..%d] "
					    "px100=%02x%02x%02x%02x px2600=%02x%02x%02x%02x",
					    (int)okR, Yr, bppR, n, first, last, q1[0], q1[1], q1[2],
					    q1[3], q2[0], q2[1], q2[2], q2[3]);
				}
				else
					Log("- p6 replayrb: bpp=%u unsupported", bppR);
			}
			// p6: XR_METAL_FILLTEST — standalone probe pass on the same
			// color0+depth as the position pass: fresh rpd, Load/Store, my
			// own pipeline + draw, commit, wait, readback. Separates
			// "my MSL/pipeline is broken" from "the engine pass eats it".
			// p6: XR_METAL_DPROBE=<thr> — depth-threshold probe: clear color,
			// Load zb, fullscreen z=<thr> triangle with Greater depth test.
			// RED px => stored depth > thr (normal far terrain);
			// black => stored <= thr (something NEAR wrote depth there).
			{
				static const char* s_ft = getenv("XR_METAL_FILLTEST");
				static uint64_t s_ftN = 0;
				if (s_ft && rt[0] && dev && cb && g_dbgEncoders > 2000 && s_ftN < 6)
				{
					const char* rn3 = MtlDbgRTGetName(rt[0]);
					if (rn3 && strstr(rn3, s_ft))
					{
						s_ftN++;
						[cb commit];
						[cb waitUntilCompleted];
						cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
							// (rawZb relocated to dprobe block)
						id<MTLTexture> a0 = rpdAtt0 ? rpdAtt0
						                            : (__bridge id<MTLTexture>)rt[0];
						MTLRenderPassDescriptor* frpd = [MTLRenderPassDescriptor new];
						frpd.colorAttachments[0].texture = a0;
						frpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
						frpd.colorAttachments[0].storeAction = MTLStoreActionStore;
						if (zb)
						{
							frpd.depthAttachment.texture =
								(__bridge id<MTLTexture>)zb;
							frpd.depthAttachment.loadAction = MTLLoadActionLoad;
							frpd.depthAttachment.storeAction =
								MTLStoreActionStore;
							// PSO below declares stencil for the combined
							// format — attach it or debug layer aborts.
							if (((MTLPixelFormat)frpd.depthAttachment.texture
							         .pixelFormat)
							        == MTLPixelFormatDepth32Float_Stencil8)
							{
								frpd.stencilAttachment.texture =
									frpd.depthAttachment.texture;
								frpd.stencilAttachment.loadAction =
									MTLLoadActionLoad;
								frpd.stencilAttachment.storeAction =
									MTLStoreActionStore;
							}
						}
						PipelineDesc fpd;
						id<MTLFunction> vsF =
						    [blitLib newFunctionWithName:@"xrtri_vs"];
						id<MTLFunction> psF =
						    [blitLib newFunctionWithName:@"xrred1_ps"];
						fpd.vs = (__bridge void*)vsF;
						fpd.ps = (__bridge void*)psF;
						fpd.colorFormats = { (int)a0.pixelFormat };
						if (frpd.depthAttachment.texture)
						{
							fpd.depthFormat =
								(int)frpd.depthAttachment.texture.pixelFormat;
							if (fpd.depthFormat ==
							        (int)MTLPixelFormatDepth32Float_Stencil8)
								fpd.stencilFormat = fpd.depthFormat;
						}
						std::string ferr;
						void* pv = cache->Pipeline(dev->Device(), fpd, ferr);
						Log("- p6 filltest: pass=%s fmt=%ld z=%d pso=%d err=%s",
						    rn3, (long)a0.pixelFormat, (int)(zb != nullptr),
						    (int)(pv != nullptr), ferr.c_str());
						if (pv && vsF && psF)
						{
							id<MTLRenderCommandEncoder> fe =
								[cb renderCommandEncoderWithDescriptor:frpd];
							[fe setViewport:(MTLViewport){ 0.0, 0.0,
								(double)a0.width, (double)a0.height, 0.0, 1.0 }];
							[fe setScissorRect:(MTLScissorRect){ 0, 0, a0.width,
								a0.height }];
							[fe setCullMode:MTLCullModeNone];
							[fe setRenderPipelineState:
								(__bridge id<MTLRenderPipelineState>)pv];
							[fe drawPrimitives:MTLPrimitiveTypeTriangle
							        vertexStart:0
							        vertexCount:3];
							[fe endEncoding];
							[cb commit];
							[cb waitUntilCompleted];
							cb = [(__bridge id<MTLCommandQueue>)dev->Queue()
							        commandBuffer];
							const uint32_t bpp = dev->TextureBpp(rt[0]);
							if (bpp && bpp <= 8)
							{
								std::vector<uint8_t> fbuf(size_t(a0.width) * bpp);
								std::string derr;
								bool ok = dev->ReadbackSlice((void*)(__bridge void*)a0,
								                             fbuf.data(),
								                             a0.width * bpp, a0.width,
								                             1, 0, 0, derr);
								const uint8_t* f100 = &fbuf[size_t(100) * bpp];
								const uint8_t* f3k = &fbuf[size_t(3000) * bpp];
								Log("- p6 filltest px: ok=%d x100: %02x %02x %02x "
								    "%02x x3000: %02x %02x %02x %02x",
								    (int)ok, f100[0], f100[1], f100[2], f100[3],
								    f3k[0], f3k[1], f3k[2], f3k[3]);
							}
						}
					}
				}
			}
			// p6 fill self-verify: right after the first fills, commit+wait and
			// read 4 px at x=3000 of the very texture the fill targeted. Decides
			// "rasterizer won't paint the band" vs "the dump reads something else".
			{
				static const char* s_frt2 = getenv("XR_METAL_FILLRT");
				static uint64_t s_fvCnt = 0;
				if (s_frt2 && rt[0] && dev && cb && g_dbgEncoders > 2000 && s_fvCnt < 8)
				{
					const char* rn2 = MtlDbgRTGetName(rt[0]);
					if (rn2 && strstr(rn2, s_frt2))
					{
						s_fvCnt++;
						// Read the framebuffer's ACTUAL color0 (rpdAtt0), not
						// just the manager's rt[0] — exposes any alias/view.
						id<MTLTexture> t0 = rpdAtt0 ? rpdAtt0
						                            : (__bridge id<MTLTexture>)rt[0];
						const uint32_t bpp = dev->TextureBpp((void*)(__bridge void*)t0);
						if (t0.width >= 3004 && bpp && bpp <= 8)
						{
							[cb commit];
							[cb waitUntilCompleted];
							cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
							// ReadbackSlice reads from ORIGIN only (slice/mip
							// args, not x/y): take the full top row.
							std::vector<uint8_t> buf(size_t(t0.width) * bpp);
							std::string derr;
							bool ok = dev->ReadbackSlice((__bridge void*)t0, buf.data(),
							                             t0.width * bpp, t0.width, 1, 0, 0,
							                             derr);
							const uint8_t* px = &buf[size_t(3000) * bpp];
							const uint8_t* p0 = &buf[size_t(100) * bpp];
							Log("- p6 fillverify: %s ok=%d same=%d fmt=%ld y0 x100: "
								"%02x %02x %02x %02x x3000: %02x %02x %02x %02x",
								rn2, (int)ok, (int)(t0 == (__bridge id<MTLTexture>)rt[0]),
								(long)t0.pixelFormat, p0[0], p0[1], p0[2], p0[3], px[0],
								px[1], px[2], px[3]);
						}
					}
				}
			}
			// p6 band-hunt: XR_METAL_DPROBE=<z> — depth-threshold probe pass:
			// clear color, Load zb, fullscreen z=<z> fill with LESS depth test
			// (passes where stored depth is FARTHER than z). RED px =>
			// stored > z (normal far terrain); black => stored <= z
			{
				static const char* s_dp = getenv("XR_METAL_DPROBE");
				static uint64_t s_dpN = 0;
				static id<MTLDepthStencilState> s_greaterDss = nil;
				// p6: the old ">2000" gate fired during MENU/LOAD where the
				// position pass is clear-only -> vacuous all-red sweeps. The
				// 3.5-min load screen burns >100k encoders, so encoder counts
				// are useless as a phase marker; PRESENTS are not (load ends
				// ~11000, screenshot window 12000-14600). Fire per present
				// stair.
				static const uint64_t s_dpStairs[] = { 11500, 12200, 12900,
					                                   13600, 14300, 15000 };
				if (s_dp && rt[0] && zb && dev && cb && s_dpN < 6 &&
				    g_mtlPresentCount > s_dpStairs[s_dpN])
				{
					const char* rn4 = MtlDbgRTGetName(rt[0]);
					if (rn4 && strstr(rn4, "position"))
					{
						s_dpN++;
						[cb commit];
						[cb waitUntilCompleted];
						cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
						id<MTLTexture> a0 = rpdAtt0 ? rpdAtt0
						                            : (__bridge id<MTLTexture>)rt[0];
							// p6: RAW zb readback — bypass the Less-fill
							// chain entirely. Scan the bottom row of the
							// depth texture itself. All 1.0 => truly
							// unwritten; any <0.99 => the fill-chain was
							// lying and depth IS written.
							{
								id<MTLTexture> zt =
								    zb ? (__bridge id<MTLTexture>)zb : nil;
								const uint32_t zw = zt ? (uint32_t)zt.width : 0;
								const uint32_t zh = zt ? (uint32_t)zt.height : 0;
								if (zw >= 1024 && zh >= 600)
								{
									std::vector<uint8_t> zbuf(
									    size_t(zw) * zh * 4);
									std::string zerr;
									bool zok = dev->ReadbackSlice(
									    zb, zbuf.data(), zw * 4, zw, zh, 0, 0,
									    zerr);
									const uint32_t zy = zh - 40u;
									const float* zrow = reinterpret_cast<const float*>(
									    &zbuf[size_t(zy) * zw * 4]);
									float zmin = 2.f, zmax = -2.f;
									uint64_t zfar = 0;
									for (uint32_t x = 0; x < zw; x++)
									{
										const float v = zrow[x];
										if (v < zmin) zmin = v;
										if (v > zmax) zmax = v;
										if (v > 0.9999f) zfar++;
									}
									Log("- p6 rawZb: ok=%d y=%u min=%.5f "
									    "max=%.5f farfrac=%.3f x100=%.5f "
									    "x3000=%.5f err=%s",
									    (int)zok, zy, zmin, zmax,
									    (double)zfar / zw, zrow[100],
									    zrow[3000], zerr.c_str());
								}
						MTLRenderPassDescriptor* drpd = [MTLRenderPassDescriptor new];
						drpd.colorAttachments[0].texture = a0;
						drpd.colorAttachments[0].loadAction = MTLLoadActionClear;
						drpd.colorAttachments[0].storeAction = MTLStoreActionStore;
						drpd.colorAttachments[0].clearColor =
						    MTLClearColorMake(0, 0, 0, 1);
						drpd.depthAttachment.texture =
						    (__bridge id<MTLTexture>)zb;
						drpd.depthAttachment.loadAction = MTLLoadActionLoad;
						// Store (not DontCare): the sweep re-loads zb for
						// each threshold; DontCare discards it on-tile.
						drpd.depthAttachment.storeAction = MTLStoreActionStore;
						// blitPipeline declares stencil=260 for combined
						// depth formats — the pass must attach it too or the
						// debug layer aborts ("stencil ... no texture set").
						if (((MTLPixelFormat)drpd.depthAttachment.texture.pixelFormat)
						        == MTLPixelFormatDepth32Float_Stencil8)
						{
							drpd.stencilAttachment.texture =
							    drpd.depthAttachment.texture;
							drpd.stencilAttachment.loadAction =
							    MTLLoadActionLoad;
							drpd.stencilAttachment.storeAction =
							    MTLStoreActionStore;
						}
						if (!s_greaterDss)
						{
							MTLDepthStencilDescriptor* dd =
								[MTLDepthStencilDescriptor new];
							dd.depthCompareFunction = MTLCompareFunctionLess;
							dd.depthWriteEnabled = false;
							s_greaterDss = [(__bridge id<MTLDevice>)dev->Device()
							        newDepthStencilStateWithDescriptor:dd];
						}
						// p6: threshold sweep in FRAMEBUFFER depth units
						// (z_ndc = 2*fb - 1). 16 m terrain stores ~0.988
						// (near=0.2, far=500); cleared = 1.0. A black gap in
						// the red mask's MID row over the band proves a
						// nearer depth wall at/below that threshold. Full
						// texture readback + mid-row scan (top row is sky).
						static const float s_dpThr[] = { 0.90f, 0.97f, 0.995f };
						const uint32_t bpp = dev->TextureBpp(rt[0]);
						id<MTLRenderPipelineState> pso = blitPipeline(
						    (MTLPixelFormat)a0.pixelFormat, true, false,
						    (int)drpd.depthAttachment.texture.pixelFormat);
						if (pso && s_greaterDss && bpp && bpp <= 8)
						{
							std::vector<uint8_t> dbuf(
							    size_t(a0.width) * size_t(a0.height) * bpp);
							const uint32_t dh = (uint32_t)a0.height;
							for (int ti = 0; ti < 3; ti++)
							{
								const float fbz = s_dpThr[ti];
								const float dparams[4] = { 1.0f, 0.0f,
								                           2.0f * fbz - 1.0f,
								                           1.0f };
								id<MTLBuffer> pb =
								    [(__bridge id<MTLDevice>)dev->Device()
								        newBufferWithBytes:dparams
								                    length:sizeof(dparams)
								                  options:MTLResourceStorageModeShared];
								if (!pb)
									continue;
								id<MTLRenderCommandEncoder> de =
									[cb renderCommandEncoderWithDescriptor:drpd];
								[de setViewport:(MTLViewport){ 0.0, 0.0,
									(double)a0.width, (double)a0.height, 0.0,
									1.0 }];
								[de setDepthStencilState:s_greaterDss];
								[de setCullMode:MTLCullModeNone];
								[de setRenderPipelineState:pso];
								[de setVertexBuffer:pb offset:0 atIndex:0];
								[de setFragmentBuffer:pb offset:0 atIndex:0];
								[de drawPrimitives:MTLPrimitiveTypeTriangle
								        vertexStart:0
								        vertexCount:3];
								[de endEncoding];
								[cb commit];
								[cb waitUntilCompleted];
								cb = [(__bridge id<MTLCommandQueue>)dev->Queue()
								        commandBuffer];
								std::string derr;
								bool ok = dev->ReadbackSlice(
								    (void*)(__bridge void*)a0, dbuf.data(),
								    a0.width * bpp, a0.width, dh, 0, 0, derr);
								// Mid row is the HORIZON (ground
								// there is 100 m+ => fb~0.999 => red
								// regardless). The bottom row has the
								// ground 2-5 m ahead (fb 0.97-0.99):
								// black at x100 there proves depth
								// IS written; x3000 then says wall
								// (black) vs missing-geometry (red).
								const uint32_t ys[2] = { dh / 2,
									     dh > 60u ? dh - 40u : 0u };
								for (int ri = 0; ri < 2; ri++)
								{
									const uint32_t ym = ys[ri];
									const uint8_t* row =
									    &dbuf[size_t(ym) * a0.width * bpp];
									uint32_t lastred = 0;
									for (uint32_t x = a0.width; x-- > 0;)
										if (row[size_t(x) * bpp + 1] == 0x3c)
										{
											lastred = x;
											break;
										}
									const uint8_t* d100 =
									    &row[size_t(100) * bpp];
									const uint8_t* d3k =
									    &row[size_t(3000) * bpp];
									Log("- p6 dprobe: presN=%llu fbz=%.3f ok=%d y%u "
									    "lastred=%u x100:%02x%02x x3000:%02x%02x",
									    (unsigned long long)g_mtlPresentCount, fbz,
									    (int)ok, ym, lastred, d100[0],
									    d100[1], d3k[0], d3k[1]);
								}
							}
							// p6: self-calibration — stamp fb 0.97 into the
							// whole zb (LessEqual + WRITE), then probe with
							// the same Less machinery at 0.995 (must FAIL:
							// lastred==0) and 0.90 (must PASS: full red).
							// If calibration lies, the sweep proves nothing.
							id<MTLDepthStencilState> s_dssW = nil;
							{
								MTLDepthStencilDescriptor* dd =
									[MTLDepthStencilDescriptor new];
								dd.depthCompareFunction =
									MTLCompareFunctionLessEqual;
								dd.depthWriteEnabled = true;
								s_dssW = [(__bridge id<MTLDevice>)dev->Device()
								        newDepthStencilStateWithDescriptor:dd];
							}
							if (s_dssW && pso)
							{
								const float cals[3] = { 0.97f, 0.995f, 0.90f };
								uint32_t calLast[3] = { 0, 0, 0 };
								for (int ci = 0; ci < 3; ci++)
								{
									const float fbz = cals[ci];
									const float dparams[4] = { 1.0f, 0.0f,
										2.0f * fbz - 1.0f, 1.0f };
									id<MTLBuffer> pb =
									    [(__bridge id<MTLDevice>)dev->Device()
									        newBufferWithBytes:dparams
									                    length:sizeof(dparams)
									                  options:MTLResourceStorageModeShared];
									if (!pb)
										continue;
									id<MTLRenderCommandEncoder> de =
										[cb renderCommandEncoderWithDescriptor:drpd];
									[de setViewport:(MTLViewport){ 0.0, 0.0,
										(double)a0.width, (double)a0.height,
										0.0, 1.0 }];
									[de setDepthStencilState:ci == 0
									                           ? s_dssW
									                           : s_greaterDss];
									[de setCullMode:MTLCullModeNone];
									[de setRenderPipelineState:pso];
									[de setVertexBuffer:pb offset:0 atIndex:0];
									[de setFragmentBuffer:pb offset:0 atIndex:0];
									[de drawPrimitives:MTLPrimitiveTypeTriangle
									        vertexStart:0
									        vertexCount:3];
									[de endEncoding];
									[cb commit];
									[cb waitUntilCompleted];
									cb = [(__bridge id<MTLCommandQueue>)dev->Queue()
									        commandBuffer];
									std::string derr;
									if (dev->ReadbackSlice(
									        (void*)(__bridge void*)a0,
									        dbuf.data(), a0.width * bpp,
									        a0.width, dh, 0, 0, derr))
									{
										const uint8_t* row = &dbuf[size_t(dh / 2)
										                           * a0.width * bpp];
										for (uint32_t x = a0.width; x-- > 0;)
											if (row[size_t(x) * bpp + 1] == 0x3c)
											{
												calLast[ci] = x;
												break;
											}
									}
								}
								Log("- p6 dcalib: stamp0.97 then Less: "
								    "probe0.995 lastred=%u (want 0) "
								    "probe0.90 lastred=%u (want %u)",
								    calLast[1], calLast[2], a0.width - 1);
							}
							}
						}
					}
				}
			}
			// p6 band-hunt: XR_METAL_FRUSPROBE=1 — dump the culling frustum from
			// this proven-live path (the r2.cpp OnCameraUpdated probe never
			// printed). Two shots: identical planes with an ADVANCING stamp =
			// frustum live; FROZEN stamp = OnCameraUpdated dead => stale ViewBase.
			{
				static const bool s_fsEn = !!getenv("XR_METAL_FRUSPROBE");
				static int s_fsN = 0;
				if (s_fsEn && s_fsN < 2 &&
				    g_mtlPresentCount > (s_fsN ? uint64_t(6500) : uint64_t(6000)))
				{
					s_fsN++;
					xrMetalDumpFrustum();
				}
			}
			// p6 band-hunt: XR_METAL_RTDUMP=<substr> — every ~300th close of a
			// pass whose color0 creation-name contains substr, commit+wait and
			// read the RT back to /tmp/rtdump/<name>.rgba (raw RGBA8). Offline
			// conversion to PNG shows which pass first carries the black band.
			{
				static const char* s_rtd = getenv("XR_METAL_RTDUMP");
				if (s_rtd && rt[0] && dev && cb)
				{
					id<MTLTexture> t0 = (__bridge id<MTLTexture>)rt[0];
					const char* rn = MtlDbgRTGetName(rt[0]);
					if (rn && strstr(rn, s_rtd) && t0.width >= 1024 && t0.height >= 600)
					{
						static std::map<void*, uint64_t> s_rtdCnt;
						// p6 wvp13: once verified in-game (Present>gate — the
						// scenecolor-proven gate), dump each distinct RT exactly
						// ONE more time. Load-phase dumps are stale evidence.
						// wvp17: MCP frame == presents since launch, so the old
						// 12200 gate sat inside the ~frame-9500 freeze window.
						// 6000 = ~2500 frames after load-end (~3500): in-game.
						static std::set<void*> s_rtdIngame;
						const bool rtdFire = g_mtlPresentCount > 6000
						                         ? s_rtdIngame.insert(rt[0]).second
						                         : (s_rtdCnt[rt[0]]++ % 300) == 299;
						if (rtdFire)
						{
							[cb commit];
							[cb waitUntilCompleted];
							cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
							const uint32_t bw = (uint32_t)t0.width, bh = (uint32_t)t0.height;
							const uint32_t bpp = dev->TextureBpp(rt[0]);
							if (bpp)
							{
								// p6: ReadbackSlice returns RAW format bytes —
								// stride/size must use the texture's own bpp,
								// not 4 (fp16 RTs read back as 8 B/px).
								std::vector<uint8_t> buf(size_t(bw) * bh * bpp);
								std::string derr;
								if (dev->ReadbackSlice(rt[0], buf.data(), bw * bpp, bw, bh, 0, 0,
								                       derr))
								{
									mkdir("/tmp/rtdump", 0755);
									char path[256];
									snprintf(path, sizeof path, "/tmp/rtdump/%s.rgba", rn);
									for (char* p = path + strlen("/tmp/rtdump/"); *p; p++)
										if (*p == '$' || *p == '/' || *p == ' ')
											*p = '_';
									FILE* f = fopen(path, "wb");
									if (f)
									{
										fwrite(buf.data(), 1, buf.size(), f);
										fclose(f);
									}
									// row stats at mid height: rightmost lit
									// pixel. Test RGB bytes only (alpha can be
									// a constant 1.0 in fp16 RTs).
									uint32_t lastLit = 0, blackTail = 0;
									const uint32_t y = bh / 2;
									const uint32_t rgb = bpp >= 6 ? 6 : bpp - 2;
									for (uint32_t x = bw; x-- > 0;)
									{
										const uint8_t* p = &buf[(size_t(y) * bw + x) * bpp];
										uint8_t any = 0;
										for (uint32_t c = 0; c < rgb; c++)
											any |= p[c];
										if (any)
										{
											lastLit = x;
											break;
										}
										blackTail++;
									}
									Log("- p6 rtdump: %s %ux%u fmt=%ld midrow lastlit=%u "
									    "blacktail=%u -> %s",
									    rn, bw, bh, (long)t0.pixelFormat, lastLit, blackTail, path);
								}
								else
									Log("! p6 rtdump: %s readback failed: %s", rn, derr.c_str());
							}
						}
					}
				}
			}
		}
	}

	void MtlPassManager::markTouched()
	{
		for (int i = 0; i < 4; i++)
			if (rt[i])
				touched.insert(rt[i]);
		if (zb)
			touched.insert(zb);
	}

	void MtlPassManager::ensureEncoder()
	{
		if (enc && !identityDirty)
			return;
		endEncoder();
		// p5 DIAG (launch102): the position pass just closed — flush the frame CB
		// (legal mid-frame split) and read the texture back before any later
		// phase can touch it. postgeom non-zero + Present-time zero == a later
		// phase clears the target, not a lost write.
		// p5 launch255: accum pass-end readback — do the sun writes exist at
		// all before any later phase touches accum? nz>0 here + rtscan zero ==
		// later-phase destruction; nz=0 here == writes never landed.
		static const int s_paOn = getenv("XR_P5_POSTACC") ? atoi(getenv("XR_P5_POSTACC"))
		                                                 : (getenv("XR_P5_ACCFILL") ? atoi(getenv("XR_P5_ACCFILL")) : 0);
		if (s_paOn && pendingAccum && cb)
		{
			static uint64_t s_paTick = 0;
			const bool wantPa = (s_paTick++ % 120) == 0;
			void* pa = pendingAccum;
			pendingAccum = nullptr;
			if (wantPa)
			{
				[cb commit];
				[cb waitUntilCompleted];
				cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
				id<MTLTexture> pt = (__bridge id<MTLTexture>)pa;
				const uint32_t pw = (uint32_t)pt.width, ph = (uint32_t)pt.height;
				// launch273: full 8-byte RGBA16Float pixels — the old pw*4
				// readback only ever exposed the R and G halves.
				std::vector<uint8_t> pb(size_t(pw) * ph * 8);
				std::string perr;
				if (dev->ReadbackSlice(pa, pb.data(), pw * 8, pw, ph, 0, 0, perr))
				{
					size_t pnz = 0;
					uint8_t chx[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
					size_t bands[4] = { 0, 0, 0, 0 };
					for (size_t k = 0; k + 7 < pb.size(); k += 8)
					{
						uint8_t any = 0;
						for (int c = 0; c < 8; c++)
						{
							any |= pb[k + c];
							if (pb[k + c] > chx[c])
								chx[c] = pb[k + c];
						}
						if (any)
						{
							pnz++;
							const size_t px = k / 8;
							bands[(px / pw) * 4 / ph]++;
						}
					}
					const size_t pmid = (size_t(ph / 2) * pw + pw / 2) * 8;
					Log("- p5 postaccum: %p %ux%u nz=%zu/%zu chmax=(%u,%u,%u,%u,%u,%u,%u,%u) "
					    "mid=(%u,%u,%u,%u,%u,%u,%u,%u) bands=(%zu,%zu,%zu,%zu) vis=%llu",
					    pa, pw, ph, pnz, pb.size() / 8, chx[0], chx[1], chx[2], chx[3], chx[4],
					    chx[5], chx[6], chx[7], pb[pmid], pb[pmid + 1], pb[pmid + 2],
					    pb[pmid + 3], pb[pmid + 4], pb[pmid + 5], pb[pmid + 6], pb[pmid + 7],
					    bands[0], bands[1], bands[2], bands[3],
					    g_visAccumBuf ? (unsigned long long)*(const uint64_t*)g_visAccumBuf.contents
					                  : 0ull);
				// p5 accgpu: POST commit+wait re-read of the sun draw's CB
				// slot. If the bytes changed since encode, the ring slot was
				// recycled/overwritten before the GPU executed => the VS read
				// garbage m_WVP and everything legitimately clipped.
				if (g_accSlotRing)
				{
					id<MTLBuffer> rb = (__bridge id<MTLBuffer>)g_accSlotRing;
					const float* rp =
					    (const float*)[rb contents] + (g_accSlotOff / 4) + 272 / 4;
					const uint32_t got = *(const uint32_t*)&rp[0];
					const float expf = *(const float*)&g_accExpect0;
					Log("- p5 accgpu2: ring@%llu r0=(%.4g %.4g %.4g %.4g) expect=%.8g %s",
					    (unsigned long long)g_accSlotOff, rp[0], rp[1], rp[2], rp[3],
					    (double)expf,
					    (uint64_t)got == g_accExpect0 ? "INTACT" : "OVERWRITTEN");
				}
				}
				else
					Log("! p5 postaccum: readback failed: %s", perr.c_str());
				// p5 launch261: is the sun shadow map itself alive? If smap
				// content is zero the LESS_EQUAL compare fails everywhere,
				// s=0 and the sun PS outputs 0 even when fragments land.
				// Same commit+wait window => settled contents.
				if (std::vector<void*>* rts2 = MtlDbgRTs())
					for (void* t2 : *rts2)
					{
						const char* nm2 = t2 ? MtlDbgRTGetName(t2) : nullptr;
						if (!nm2 || !strstr(nm2, "smap_depth"))
							continue;
						id<MTLTexture> st = (__bridge id<MTLTexture>)t2;
						const uint32_t sw = (uint32_t)st.width, sh = (uint32_t)st.height;
						std::vector<uint8_t> sb(size_t(sw) * sh * 4);
						std::string serr;
						if (dev->ReadbackSlice(t2, sb.data(), sw * 4, sw, sh, 0, 0, serr))
						{
							size_t snz = 0;
							uint8_t sch[4] = { 0, 0, 0, 0 };
							float smin = 1e9f, smax = -1e9f;
							for (size_t k = 0; k + 3 < sb.size(); k += 4)
							{
								if (sb[k] | sb[k + 1] | sb[k + 2] | sb[k + 3])
									snz++;
								for (int c = 0; c < 4; c++)
									if (sb[k + c] > sch[c])
										sch[c] = sb[k + c];
								float f;
								std::memcpy(&f, &sb[k], 4);
								if (f > 0.f && f < 10.f)
								{
									if (f < smin)
										smin = f;
									if (f > smax)
										smax = f;
								}
							}
							Log("- p5 postsmap: %s %p %ux%u nz=%zu/%zu chmax=(%u,%u,%u,%u) "
							    "fmin=%.4g fmax=%.4g",
							    nm2, t2, sw, sh, snz, sb.size() / 4, sch[0], sch[1], sch[2],
							    sch[3], smin > smax ? -1.f : smin, smax);
						}
						else
							Log("! p5 postsmap: readback failed %s: %s", nm2, serr.c_str());
						break;
					}
			}
		}
		if (pendingPostGeom && cb)
		{
			void* pg = pendingPostGeom;
			void* pgAlb = pendingPostGeomAlb;
			pendingPostGeom = nullptr;
			pendingPostGeomAlb = nullptr;
			// p5 launch231: is this block reached at all? (postalb/deftex
			// never logged in 228-230 despite stashes firing.)
			{
				static unsigned long long s_pfN = 0;
				if ((s_pfN++ % 120) == 0)
					Log("- p5 pfetch: n=%llu alb=%p dt=%p mt=%p", s_pfN, pgAlb,
					    pendingDefferTex, pendingMatTex);
			}
			// p5 launch228: LIVE content probes (the S13/canary window below is
			// disabled; these read only settled textures after commit+wait —
			// no replay state, safe). postalb: does the gbuffer ever paint
			// albedo? deftex: is the bound diffuse texture's content alive?
			{
				static uint64_t s_lcTick = 0;
				static int s_paN = 0, s_dtN = 0, s_mtN = 0, s_smN = 0;
				const uint64_t tk = s_lcTick++;
				void* dt = pendingDefferTex;
				void* mt = pendingMatTex;
				void* sm = pendingSmapTex;
				const bool wantAlb = pgAlb && (tk % 20 == 7) && s_paN < 20;
				const bool wantDt = dt && (tk % 20 == 11) && s_dtN < 12;
				const bool wantMt = mt && (tk % 20 == 13) && s_mtN < 8;
				const bool wantSm = sm && (tk % 20 == 17) && s_smN < 6;
				if ((wantAlb || wantDt || wantMt || wantSm) && cb)
				{
					[cb commit];
					[cb waitUntilCompleted];
					// fresh CB: the encoder we are about to build needs one.
					cb = [(__bridge id<MTLCommandQueue>)dev->Queue() commandBuffer];
					if (wantAlb)
					{
						s_paN++;
						id<MTLTexture> at = (__bridge id<MTLTexture>)pgAlb;
						const uint32_t aw = (uint32_t)at.width, ah = (uint32_t)at.height;
						std::vector<uint8_t> ab(size_t(aw) * ah * 4);
						std::string aerr;
						if (dev->ReadbackSlice(pgAlb, ab.data(), aw * 4, aw, ah, 0, 0, aerr))
						{
							size_t anz = 0;
							uint8_t chx[3] = { 0, 0, 0 };
							for (size_t k = 0; k + 3 < ab.size(); k += 16)
							{
								if (ab[k] | ab[k + 1] | ab[k + 2])
									anz++;
								for (int c = 0; c < 3; c++)
									if (ab[k + c] > chx[c])
										chx[c] = ab[k + c];
							}
							const size_t amid = (size_t(ah / 2) * aw + aw / 2) * 4;
							Log("- p5 postalb: %ux%u nz=%zu chmax=(%u,%u,%u) mid=(%u,%u,%u,%u)",
							    aw, ah, anz, chx[0], chx[1], chx[2], ab[amid], ab[amid + 1],
							    ab[amid + 2], ab[amid + 3]);
						}
						else
							Log("! p5 postalb: readback failed: %s", aerr.c_str());
					}
					if (wantDt)
					{
						s_dtN++;
						id<MTLTexture> dtx = (__bridge id<MTLTexture>)dt;
						const uint32_t dw = (uint32_t)dtx.width, dh = (uint32_t)dtx.height;
						std::vector<uint8_t> db(size_t(dw) * dh * 4);
						std::string derr;
						if (dev->ReadbackSlice(dt, db.data(), dw * 4, dw, dh, 0, 0, derr))
						{
							size_t dnz = 0;
							uint8_t chx[3] = { 0, 0, 0 };
							for (size_t k = 0; k + 3 < db.size(); k += 4)
							{
								if (db[k] | db[k + 1] | db[k + 2])
									dnz++;
								for (int c = 0; c < 3; c++)
									if (db[k + c] > chx[c])
										chx[c] = db[k + c];
							}
							Log("- p5 deftex: %ux%u t%ld nz=%zu/%zu chmax=(%u,%u,%u)", dw, dh,
							    (long)dtx.textureType, dnz, db.size() / 4, chx[0], chx[1], chx[2]);
						}
						else
							Log("! p5 deftex: readback failed: %s", derr.c_str());
					}
					if (wantMt)
					{
						s_mtN++;
						id<MTLTexture> mtx = (__bridge id<MTLTexture>)mt;
						const uint32_t mw = (uint32_t)mtx.width, mh = (uint32_t)mtx.height;
						std::vector<uint8_t> mb(size_t(mw) * mh * 4);
						std::string merr;
						if (dev->ReadbackSlice(mt, mb.data(), mw * 4, mw, mh, 0, 0, merr))
						{
							size_t mnz = 0;
							uint8_t chx[3] = { 0, 0, 0 };
							for (size_t k = 0; k + 3 < mb.size(); k += 4)
							{
								if (mb[k] | mb[k + 1] | mb[k + 2])
									mnz++;
								for (int c = 0; c < 3; c++)
									if (mb[k + c] > chx[c])
										chx[c] = mb[k + c];
							}
							Log("- p5 mattex: %ux%u f%ld t%ld z%ld m%ld nz=%zu/%zu chmax=(%u,%u,%u)",
							    mw, mh, (long)mtx.pixelFormat, (long)mtx.textureType,
							    (long)mtx.depth, (long)mtx.mipmapLevelCount, mnz,
							    mb.size() / 4, chx[0], chx[1], chx[2]);
						}
						else
							Log("! p5 mattex: readback failed: %s", merr.c_str());
					}
					if (wantSm)
					{
						s_smN++;
						id<MTLTexture> smx = (__bridge id<MTLTexture>)sm;
						const uint32_t sw = (uint32_t)smx.width, sh = (uint32_t)smx.height;
						std::vector<uint8_t> sb(size_t(sw) * sh * 4);
						std::string serr;
						// Depth32Float_Stencil8 → blit yields the float plane
						// (4 Bpp); stats below interpret it as float depth.
						if (dev->ReadbackSlice(sm, sb.data(), sw * 4, sw, sh, 0, 0, serr))
						{
							size_t snz = 0;
							float smin = 1e9f, smax = -1e9f;
							for (size_t k = 0; k + 3 < sb.size(); k += 4)
							{
								if (sb[k] | sb[k + 1] | sb[k + 2] | sb[k + 3])
									snz++;
								float q;
								std::memcpy(&q, sb.data() + k, 4);
								if (q < smin)
									smin = q;
								if (q > smax)
									smax = q;
							}
							Log("- p5 smaprb: %ux%u f%ld t%ld nz=%zu/%zu dmin=%.4g dmax=%.4g",
							    sw, sh, (long)smx.pixelFormat, (long)smx.textureType, snz,
							    sb.size() / 4, smin, smax);
						}
						else
							Log("! p5 smaprb: readback failed: %s", serr.c_str());
					}
				}
			}
			// launch139: window covers TWO consecutive position pass-ends
			// (5 and 6). launch138 verdict: the frame runs the position pass
			// twice (main model + rain) and the main/rain PARITY flips with
			// weather state — launch137's single-parity window (gate 5) hit
			// the main pass, launch138's hit the rain pass for 40 windows
			// straight (skip ps=rain_apply_*), so canaryI captured nothing
			// and the append block never ran (L=0 regression was an
			// instrument artifact, not an engine change). One of gates
			// 5/6 is always the main pass; deffer draws only happen there.
			const int s_pgPeriod = getenv("MTL_DEBUG_LAYER") ? 20 : 240;
			const int g5 = ++g_pgGate % s_pgPeriod; // debug layer: 20 (slow frames)
			static int s_paForce = 0; // p5 launch187: force window on albedo stashes
			// p5 launch197: window DISABLED — the S13/canary replay probes inside
			// it read captured dynamic-VB state after the engine ring wrapped
			// (use-after-overwrite SIGSEGV in ensureEncoder, fonts trigger it).
			// Its verdicts are recorded; the black-frame fixes are in.
			if (false && (g5 == 5 || g5 == 6 || (pgAlb && g_dbgDrawOK > 60000 && s_paForce++ < 40))) // launch131: 1 readback window/240 (was 7 —
			{
				// launch128/129: canaryI pass-end appends — after ALL engine
				// draws of this pass, so nothing can overwrite them before the
				// readback. launch129: up to 8 captured draws per window (one
				// small off-screen mesh rasterizes nothing and reads as zero).
				// launch138: S-draw scratch RT (1024² BGRA8, cleared each
				// window). Declared out here so the readback (after
				// commit+wait) can see it.
				static id<MTLTexture> s_sTex = nil;
				static id<MTLTexture> s_s3Tex = nil, s_s4Tex = nil; // launch145
				static id<MTLTexture> s_s5Tex = nil, s_s6Tex = nil; // launch147
				static id<MTLTexture> s_s7Tex = nil, s_s8Tex = nil; // launch149
				static id<MTLTexture> s_s13Tex[4] = {}; // launch154: S13 live-PS MRT
				if ((g5 == 5 || g5 == 6) && !s_appQ.empty())
				{
					id<MTLTexture> atex = (__bridge id<MTLTexture>)pg;
					MTLRenderPassDescriptor* arpd = [MTLRenderPassDescriptor new];
					arpd.colorAttachments[0].texture = atex;
					arpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
					arpd.colorAttachments[0].storeAction = MTLStoreActionStore;
					id<MTLRenderCommandEncoder> ae = [cb renderCommandEncoderWithDescriptor:arpd];
					MTLViewport avp = { 0, 0, (double)atex.width, (double)atex.height, 0.0, 1.0 };
					MTLScissorRect asr = { 0, 0, atex.width, atex.height };
					[ae setViewport:avp];
					[ae setScissorRect:asr];
					[ae setCullMode:MTLCullModeNone]; // launch130: fresh
					                                          // encoder defaults to
					                                          // CullBack — DX9 CW-front
					                                          // geometry vanishes
					// launch132: full-screen discriminator — self-contained
					// trivial pipeline writes R=0.5 (the L flag) everywhere.
					// L>0 => append encoder+readback healthy and the pair
					// draws' failure is VS-side; L=0 => the append path itself
					// cannot write this texture.
					static id<MTLRenderPipelineState> s_fsqPso = nil;
					static bool s_fsqTried = false;
					if (!s_fsqTried)
					{
						s_fsqTried = true;
						id<MTLDevice> devF = (__bridge id<MTLDevice>)dev->Device();
						NSString* srcF = @"#include <metal_stdlib>\n"
						                 "using namespace metal;\n"
						                 "vertex float4 fsq_vs(uint vid [[vertex_id]]) {\n"
						                 "  const float2 p[3] = { float2(-1.0,-1.0), float2(3.0,-1.0), "
						                 "float2(-1.0,3.0) };\n"
						                 "  return float4(p[vid], 0.5, 1.0);\n"
						                 "}\n"
						                 "fragment float4 fsq_ps() { return float4(0.5, 0.5, 0.5, 0.5); }\n";
						NSError* eF = nil;
						id<MTLLibrary> libF = [devF newLibraryWithSource:srcF options:nil error:&eF];
						if (libF)
						{
							PipelineDesc pdF;
							pdF.vs = (__bridge void*)[libF newFunctionWithName:@"fsq_vs"];
							pdF.ps = (__bridge void*)[libF newFunctionWithName:@"fsq_ps"];
							pdF.stride = 0; // vertex-id-only VS
							pdF.colorFormats.clear(); // match live encoder fully
							for (int aiF = 0; aiF < attColorCount; aiF++)
								pdF.colorFormats.push_back(attColorFmt[aiF]);
							pdF.depthFormat = attDepthFmt;
							if (attDepthFmt == 260)
								pdF.stencilFormat = attDepthFmt;
							std::string errF;
							s_fsqPso = (__bridge id<MTLRenderPipelineState>)
							               cache->Pipeline(dev->Device(), pdF, errF);
							if (!s_fsqPso)
								Log("! p5 canaryI: fsq PSO failed: %s", errF.c_str());
						}
						else
							Log("! p5 canaryI: fsq lib failed: %s",
							    [[eF localizedDescription] UTF8String]);
					}
					if (s_fsqPso)
					{
						[ae setRenderPipelineState:s_fsqPso];
						[ae drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					}
					int drawn = 0;
					if (!s_sTex)
					{
						MTLTextureDescriptor* tdS = [MTLTextureDescriptor
						    texture2DDescriptorWithPixelFormat:(MTLPixelFormat)80
						                                 width:1024
						                                height:1024
						                             mipmapped:NO];
						tdS.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
						s_sTex = [(__bridge id<MTLDevice>)dev->Device()
						              newTextureWithDescriptor:tdS];
					}
					// launch145: Extra scratch (textures declared next to
					// s_sTex so the readbacks see them) — s3 keeps the S4
					// clip-coord histogram uncontaminated; s4 holds S5 (cyan)
					// + S6 (red).
					if (!s_s3Tex)
					{
						MTLTextureDescriptor* td3 = [MTLTextureDescriptor
						    texture2DDescriptorWithPixelFormat:(MTLPixelFormat)80
						                                 width:1024
						                                height:1024
						                             mipmapped:NO];
						td3.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
						s_s3Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						s_s4Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						s_s5Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						s_s6Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						s_s7Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						s_s8Tex = [(__bridge id<MTLDevice>)dev->Device()
						               newTextureWithDescriptor:td3];
						if (!s_s13Tex[0]) // launch155 S13 MRT scratch (float32:
						{                  // NaN survives, unlike BGRA8)
							MTLTextureDescriptor* td13 = [MTLTextureDescriptor
							    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
							                                 width:1024
							                                height:1024
							                             mipmapped:NO];
							td13.usage = MTLTextureUsageRenderTarget |
							             MTLTextureUsageShaderRead;
							for (int i13 = 0; i13 < 4; i13++)
								s_s13Tex[i13] = [(__bridge id<MTLDevice>)dev->Device()
								                    newTextureWithDescriptor:td13];
						}
					}
					static std::map<uint32_t, id<MTLRenderPipelineState>> s_vPso;
					static id<MTLLibrary> s_vLib = nil;
					static bool s_vTried = false;
					// launch140: W/X decomposition PSOs (see draw block below).
					static id<MTLLibrary> s_wLib = nil;
					static id<MTLRenderPipelineState> s_wPso = nil, s_xPso = nil;
					static id<MTLRenderPipelineState> s_zPso = nil, s_uPso = nil;
					static id<MTLBuffer> s_xib = nil;
					static bool s_wTried = false;
					for (const auto& ap : s_appQ)
					{
						if (!ap.pso)
							continue;
						// launch134: V-draw — trivial VS reading the pair VB's
						// position attribute (Float3@0, stream slot 1) scaled
						// into view + constant PS (R=0.75 => byte1==58 = V
						// flag). V>0 => VB+bindings healthy on the GPU => the
						// pair VS/descriptor is the poison; V=0 => the VB
						// binding path itself is dead.
						if (!s_vTried && !s_vLib)
						{
							s_vTried = true;
							id<MTLDevice> devV = (__bridge id<MTLDevice>)dev->Device();
							NSString* srcV = @"#include <metal_stdlib>\n"
							                 "using namespace metal;\n"
							                 // launch138: stage_in-struct form — this
							                 // toolchain rejects DIRECT vertex inputs
							                 // ('invalid type float4 for input
							                 // declaration in a vertex function');
							                 // the engine's VSes always use stage_in.
							                 "struct vbc_in { float4 p [[attribute(0)]]; };\n"
							                 // launch142: ring placement (same as W/X) —
							                 // finite fetch => lands; garbage => clipped.
							                 "vertex float4 vbc_vs(vbc_in in [[stage_in]], uint "
							                 "vid [[vertex_id]]) {\n"
							                 "  if (!isfinite(in.p.x) || !isfinite(in.p.y) || "
							                 "!isfinite(in.p.z))\n"
							                 "    return float4(0.0, 0.0, 2.0, 1.0);\n"
							                 "  float a = float(vid) * 0.17;\n"
							                 "  return float4(sin(a) * 0.5, cos(a) * 0.5, 0.5, "
							                 "1.0);\n"
							                 "}\n"
							                 "fragment float4 vbc_ps() { return float4(0.75, 0.25, "
							                 "0.5, 1.0); }\n";
							NSError* eV = nil;
							s_vLib = [devV newLibraryWithSource:srcV options:nil error:&eV];
							if (!s_vLib)
								Log("! p5 canaryI: vbc lib failed: %s",
								    [[eV localizedDescription] UTF8String]);
						}
						id<MTLRenderPipelineState> vp = nil;
						if (s_vLib)
						{
							auto vit = s_vPso.find(ap.stride ? ap.stride : 32);
							if (vit != s_vPso.end())
								vp = vit->second;
							else
							{
								PipelineDesc pdV;
								pdV.vs = (__bridge void*)[s_vLib newFunctionWithName:@"vbc_vs"];
								pdV.ps = (__bridge void*)[s_vLib newFunctionWithName:@"vbc_ps"];
								pdV.stride = ap.stride ? ap.stride : 32;
								pdV.vbSlot = 1;
								VertexAttr aV;
								aV.index = 0;
								aV.offset = 0;
								aV.format = (uint32_t)MTLVertexFormatFloat3;
								pdV.attrs.push_back(aV);
								pdV.colorFormats.push_back((int)atex.pixelFormat);
								std::string errV;
								vp = (__bridge id<MTLRenderPipelineState>)
								         cache->Pipeline(dev->Device(), pdV, errV);
								if (!vp)
									Log("! p5 canaryI: vbc PSO failed (stride=%u): %s", pdV.stride,
									    errV.c_str());
								s_vPso[ap.stride ? ap.stride : 32] = vp; // nil cached on purpose
							}
						}
						if (vp && ap.vb && ap.ib)
						{
							[ae setRenderPipelineState:vp];
							[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
							[ae drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						// launch140: W/X decomposition of V=0. launch139
						// verdict: draws NOT touching the pair VB land on every
						// pixel (fsq L=316008), every draw that reads the
						// captured VB/IB lands zero (V, S, pair append) => the
						// poison is in the buffer supply to the GPU.
						// W-draw: raw VB bytes via device pointer (no vertex
						// descriptor, non-indexed, first N vertices, R=0.25 =>
						// byte1==52 = W flag) — tests whether the VB bytes are
						// GPU-readable at all.
						// X-draw: full vertex-descriptor path with a CPU-built
						// known-good index buffer (R=0.125 => byte1==48 = X
						// flag) — tests the descriptor+indexed path
						// independently of the captured IB.
						// W>0,X=0 => captured IB is the poison; W=0 => VB bytes
						// are garbage on the GPU (engine/CPU view lies).
						if (!s_wTried)
						{
							s_wTried = true;
							id<MTLDevice> devW2 = (__bridge id<MTLDevice>)dev->Device();
							NSError* eW2 = nil;
							s_wLib = [devW2
							    newLibraryWithSource:@"#include <metal_stdlib>\n"
							                       "using namespace metal;\n"
							                       // launch142: launch141 verdict —
							                       // 'cos(vid)' (uint) was AMBIGUOUS and
							                       // killed the whole lib (W/X never ran;
							                       // Wgeom echo proved CPU-side VB bytes
							                       // sane: p0=(6.41 -0.35 1.78)). Clamped
							                       // scale also failed: object-space verts
							                       // (±10m) collapse to a ~5px center
							                       // patch that slips the 64-byte grid.
							                       // Now: ANY finite read -> vertex lands
							                       // on a big vid-ring (guaranteed
							                       // sampled); NaN/Inf -> clipped (z=2>1).
							                       // W/X/V = pure "did finite bytes reach
							                       // the vertex stage" binaries.
							                       "vertex float4 wbc_vs(uint vid [[vertex_id]], "
							                       "const device packed_float3* vb "
							                       "[[buffer(1)]]) {\n"
							                       "  float3 p = float3(vb[vid * 8]);\n"
							                       "  if (!isfinite(p.x) || !isfinite(p.y) || "
							                       "!isfinite(p.z))\n"
							                       "    return float4(0.0, 0.0, 2.0, 1.0);\n"
							                       "  float a = float(vid) * 0.17;\n"
							                       "  return float4(sin(a) * 0.5, cos(a) * 0.5, "
							                       "0.5, 1.0);\n"
							                       "}\n"
							                       "fragment float4 wbc_ps() { return float4(0.25, "
							                       "0.25, 0.5, 1.0); }\n"
							                       "struct xbc_in { float4 p [[attribute(0)]]; "
							                       "};\n"
							                       "vertex float4 xbc_vs(xbc_in in [[stage_in]], "
							                       "uint vid [[vertex_id]]) {\n"
							                       "  if (!isfinite(in.p.x) || !isfinite(in.p.y) "
							                       "|| !isfinite(in.p.z))\n"
							                       "    return float4(0.0, 0.0, 2.0, 1.0);\n"
							                       "  float a = float(vid) * 0.17;\n"
							                       "  return float4(sin(a) * 0.5, cos(a) * 0.5, "
							                       "0.5, 1.0);\n"
							                       "}\n"
							                       "fragment float4 xbc_ps() { return float4(0.125, "
							                       "0.25, 0.5, 1.0); }\n"
							                       // launch144: Z = captured IB at
							                       // offset 0 (R=0.1875 -> byte1
							                       // 50); U = captured IB at the
							                       // captured offset but baseVertex
							                       // 0 (R=0.375 -> byte1 54). With
							                       // V (all captured) and X (all
							                       // synthetic) these four split
							                       // IB-bytes / ibOff / baseV.
							                       "fragment float4 zbc_ps() { return float4(0.1875, "
							                       "0.25, 0.5, 1.0); }\n"
							                       "fragment float4 ubc_ps() { return float4(0.375, "
							                       "0.25, 0.5, 1.0); }\n"
							    options:nil
							      error:&eW2];
							if (!s_wLib)
								Log("! p5 canaryI: wbc lib failed: %s",
								    [[eW2 localizedDescription] UTF8String]);
							else
							{
								PipelineDesc pdW;
								pdW.vs = (__bridge void*)[s_wLib newFunctionWithName:@"wbc_vs"];
								pdW.ps = (__bridge void*)[s_wLib newFunctionWithName:@"wbc_ps"];
								pdW.stride = 0; // device-ref VS — no descriptor
								pdW.colorFormats.push_back((int)atex.pixelFormat);
								std::string errW;
								s_wPso = (__bridge id<MTLRenderPipelineState>)
								             cache->Pipeline(dev->Device(), pdW, errW);
								if (!s_wPso)
									Log("! p5 canaryI: wbc PSO failed: %s", errW.c_str());
								PipelineDesc pdX;
								pdX.vs = (__bridge void*)[s_wLib newFunctionWithName:@"xbc_vs"];
								pdX.ps = (__bridge void*)[s_wLib newFunctionWithName:@"xbc_ps"];
								pdX.stride = 32;
								pdX.vbSlot = 1;
								VertexAttr aX;
								aX.index = 0;
								aX.offset = 0;
								aX.format = (uint32_t)MTLVertexFormatFloat3;
								pdX.attrs.push_back(aX);
								pdX.colorFormats.push_back((int)atex.pixelFormat);
								std::string errX;
								s_xPso = (__bridge id<MTLRenderPipelineState>)
								             cache->Pipeline(dev->Device(), pdX, errX);
								if (!s_xPso)
									Log("! p5 canaryI: xbc PSO failed: %s", errX.c_str());
								uint16_t idx[384];
								for (int i = 0; i < 384; i++)
									idx[i] = (uint16_t)i;
								s_xib = [devW2 newBufferWithBytes:idx
								                          length:sizeof(idx)
								                         options:MTLResourceStorageModeShared];
								PipelineDesc pdZ = pdX; // launch144: same fetch,
								pdZ.ps = (__bridge void*)
								    [s_wLib newFunctionWithName:@"zbc_ps"]; // Z/U draws
								std::string errZ;
								s_zPso = (__bridge id<MTLRenderPipelineState>)
								             cache->Pipeline(dev->Device(), pdZ, errZ);
								if (!s_zPso)
									Log("! p5 canaryI: zbc PSO failed: %s", errZ.c_str());
								PipelineDesc pdU = pdX;
								pdU.ps = (__bridge void*)
								    [s_wLib newFunctionWithName:@"ubc_ps"];
								std::string errU;
								s_uPso = (__bridge id<MTLRenderPipelineState>)
								             cache->Pipeline(dev->Device(), pdU, errU);
								if (!s_uPso)
									Log("! p5 canaryI: ubc PSO failed: %s", errU.c_str());
							}
						}
						const NSUInteger maxV =
						    ap.vb ? ap.vb.length / (ap.stride ? (NSUInteger)ap.stride : 32) : 0;
						NSUInteger vStart = (NSUInteger)(ap.baseV > 0 ? (NSUInteger)ap.baseV : 0);
						if (vStart + 3 > maxV)
							vStart = 0;
						// launch141: per-entry echo of what the CPU sees in the
						// SAME bytes the W/X draws hand the GPU — pairs the W
						// flag against ground truth (W>0 + sane p0 => GPU reads
						// what the CPU wrote; W>0 + p0=(0,0,0) => GPU reads a
						// zeroed buffer => upload/identity split-brain).
						{
							const uint8_t* vbase =
								ap.vb ? (const uint8_t*)[ap.vb contents] : nullptr;
							float p0[3] = { -999, -999, -999 };
							if (vbase && vStart * (ap.stride ? ap.stride : 32) + 12 <=
							                [ap.vb length])
								memcpy(p0, vbase + vStart * (ap.stride ? ap.stride : 32), 12);
							Log("- p5 canaryI: Wgeom len=%lu stride=%u maxV=%lu vS=%lu "
							    "p0=(%.2f %.2f %.2f)",
							    (unsigned long)(ap.vb ? [ap.vb length] : 0), ap.stride,
							    (unsigned long)maxV, (unsigned long)vStart, p0[0], p0[1], p0[2]);
						}
						if (s_wPso && ap.vb && maxV >= 3)
						{
							[ae setRenderPipelineState:s_wPso];
							[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
							[ae drawPrimitives:MTLPrimitiveTypeTriangle
							          vertexStart:vStart
							          vertexCount:((maxV - vStart) < 512 ? (maxV - vStart) : 512)];
						}
						if (s_xPso && s_xib && ap.vb && maxV >= 3)
						{
							const NSUInteger ic = ((maxV < 384 ? maxV : 384) / 3) * 3;
							[ae setRenderPipelineState:s_xPso];
							[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
							[ae drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ic indexType:MTLIndexTypeUInt16
							                 indexBuffer:s_xib indexBufferOffset:0
							               instanceCount:1 baseVertex:0 baseInstance:0];
						}
						// launch144: launch143 verdict — W=181 X=1533 V=0 with
						// corrected scan bytes: descriptor fetch fine, the
						// CAPTURED IB supply is the poison (Sdraw=0 corroborates).
						// Ibgeom echo: what the CPU sees in the captured IB (the
						// live posclip said sane bytes at draw time — is it still
						// sane at pass-end?) + full range checks. Z/U draws split
						// the three remaining suspects (buffer bytes / ibOff /
						// baseVertex) on the GPU side.
						if (ap.ib)
						{
							const uint8_t* ibase = (const uint8_t*)[ap.ib contents];
							const NSUInteger ibLen = [ap.ib length];
							const uint16_t* i16 =
								ibase && ap.ibOff + 1 < ibLen
								    ? (const uint16_t*)(ibase + ap.ibOff)
								    : nullptr;
							uint32_t mx = 0;
							if (i16)
								for (NSUInteger k = 0; k < ap.idxCount; k++)
									if (i16[k] > mx)
										mx = i16[k];
							Log("- p5 canaryI: Ibgeom ib=%p len=%lu ibOff=%lu idx=%lu baseV=%ld "
							    "inR=%d i0=[%u %u %u %u] maxIdx=%u vbVerts=%lu baseV+max=%u",
						    (__bridge void*)ap.ib, (unsigned long)ibLen, (unsigned long)ap.ibOff,
							    (unsigned long)ap.idxCount, (long)ap.baseV,
							    (int)(ap.ibOff + (NSUInteger)ap.idxCount * 2 <= ibLen),
							    i16 ? i16[0] : 9999u, i16 ? i16[1] : 9999u, i16 ? i16[2] : 9999u,
							    i16 ? i16[3] : 9999u, mx, (unsigned long)maxV,
							    (unsigned)(ap.baseV + (NSInteger)mx));
						}
						else
							Log("- p5 canaryI: Ibgeom ib=nil");
						if (s_zPso && ap.vb && ap.ib)
						{
							const NSUInteger zc = (([ap.ib length] / 2 < 384
							                              ? [ap.ib length] / 2
							                              : 384) /
							                         3) *
							                      3;
							[ae setRenderPipelineState:s_zPso];
							[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
							[ae drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:zc indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:0
							               instanceCount:1 baseVertex:0 baseInstance:0];
						}
						if (s_uPso && ap.vb && ap.ib &&
						    ap.ibOff + (NSUInteger)ap.idxCount * 2 <= [ap.ib length])
						{
							[ae setRenderPipelineState:s_uPso];
							[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
							[ae drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:0 baseInstance:0];
						}
						[ae setRenderPipelineState:ap.pso];
						if (ap.cb) // launch130: captured CB snapshot
							[ae setVertexBuffer:ap.cb offset:0 atIndex:0];
						else if (ap.ring)
							[ae setVertexBuffer:ap.ring offset:ap.ringOff atIndex:0];
						for (int vi = 0; vi < 8; vi++) // launch133: VS stage state
						{
							if (ap.vtex[vi])
								[ae setVertexTexture:ap.vtex[vi] atIndex:vi];
							if (ap.vsamp[vi])
								[ae setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
						}
						[ae setVertexBuffer:ap.vb offset:0 atIndex:1];
						[ae drawIndexedPrimitives:MTLPrimitiveTypeTriangle
						               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
						                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
						               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						drawn++;
					}
					[ae endEncoding];
					Log("- p5 canaryI: APPENDED pass-end n=%d", drawn);
					// launch138: S-draw pass — clean 1024² scratch (cleared
					// black), entries drawn with the pair VS + white PS.
					// hits>0 + bbox => VS output valid and WHERE it
					// projected; hits=0 => VS output dead on arrival.
					if (s_sTex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp = [MTLRenderPassDescriptor new];
						sp.colorAttachments[0].texture = s_sTex;
						sp.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> se =
						    [cb renderCommandEncoderWithDescriptor:sp];
						[se setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[se setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.sPso || !ap.vb || !ap.ib)
								continue;
							[se setRenderPipelineState:ap.sPso];
							if (ap.cb)
								[se setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[se setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[se setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[se setVertexBuffer:ap.vb offset:0 atIndex:1];
							[se drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
							if (ap.s2Pso) // launch144: w-patched VS, green
							{
								[se setRenderPipelineState:ap.s2Pso];
								[se drawIndexedPrimitives:MTLPrimitiveTypeTriangle
								               indexCount:ap.idxCount
								                indexType:MTLIndexTypeUInt16
								                  indexBuffer:ap.ib
								            indexBufferOffset:ap.ibOff
								                  instanceCount:1
								                     baseVertex:ap.baseV
								                   baseInstance:0];
							}
						}
						[se endEncoding];
					}
					// launch147: S7 pass — clip-coord histogram on its own
					// scratch. VS forces z=0.5w (so fragments survive the clip
					// test) but forwards the ORIGINAL gl_Position through the
					// locn30 interpolant — the PS reports true sign(w)+z/w.
					if (s_s3Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp4 = [MTLRenderPassDescriptor new];
						sp4.colorAttachments[0].texture = s_s3Tex;
						sp4.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp4.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp4.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e4 =
						    [cb renderCommandEncoderWithDescriptor:sp4];
						[e4 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e4 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s7Pso || !ap.vb || !ap.ib)
								continue;
							[e4 setRenderPipelineState:ap.s7Pso];
							if (ap.cb)
								[e4 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e4 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e4 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e4 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e4 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						[e4 endEncoding];
					}
					// launch145: S5 (cyan, z=0.5w only) + S6 (red, w=-w only) —
					// which one lands names the killer clip plane.
					if (s_s4Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp5 = [MTLRenderPassDescriptor new];
						sp5.colorAttachments[0].texture = s_s4Tex;
						sp5.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp5.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp5.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e5 =
						    [cb renderCommandEncoderWithDescriptor:sp5];
						[e5 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e5 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.vb || !ap.ib)
								continue;
							if (ap.cb)
								[e5 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e5 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e5 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e5 setVertexBuffer:ap.vb offset:0 atIndex:1];
							if (ap.s5Pso)
							{
								[e5 setRenderPipelineState:ap.s5Pso];
								[e5 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
								               indexCount:ap.idxCount
								                indexType:MTLIndexTypeUInt16
								                  indexBuffer:ap.ib
								            indexBufferOffset:ap.ibOff
								                  instanceCount:1
								                     baseVertex:ap.baseV
								                   baseInstance:0];
							}
							if (ap.s6Pso)
							{
								[e5 setRenderPipelineState:ap.s6Pso];
								[e5 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
								               indexCount:ap.idxCount
								                indexType:MTLIndexTypeUInt16
								                  indexBuffer:ap.ib
								            indexBufferOffset:ap.ibOff
								                  instanceCount:1
								                     baseVertex:ap.baseV
								                   baseInstance:0];
							}
						}
						[e5 endEncoding];
					}
					// launch147: S8 pass (magenta, z'=0.5z+0.5w) and S9 pass
					// (yellow, z'=0.5z+w) — separate scratches, no overwrite.
					if (s_s5Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp8 = [MTLRenderPassDescriptor new];
						sp8.colorAttachments[0].texture = s_s5Tex;
						sp8.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp8.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp8.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e8 =
						    [cb renderCommandEncoderWithDescriptor:sp8];
						[e8 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e8 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s8Pso || !ap.vb || !ap.ib)
								continue;
							[e8 setRenderPipelineState:ap.s8Pso];
							if (ap.cb)
								[e8 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e8 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e8 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e8 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e8 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						[e8 endEncoding];
					}
					if (s_s6Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp9 = [MTLRenderPassDescriptor new];
						sp9.colorAttachments[0].texture = s_s6Tex;
						sp9.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp9.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp9.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e9 =
						    [cb renderCommandEncoderWithDescriptor:sp9];
						[e9 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e9 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s9Pso || !ap.vb || !ap.ib)
								continue;
							[e9 setRenderPipelineState:ap.s9Pso];
							if (ap.cb)
								[e9 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e9 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e9 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e9 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e9 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						[e9 endEncoding];
					}
					// launch149: S11 (lime, z'=z-0.5w) + S12 (orange,
					// z'=clamp(z,1e-4w,0.9999w)) — separate scratches.
					if (s_s7Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp11 = [MTLRenderPassDescriptor new];
						sp11.colorAttachments[0].texture = s_s7Tex;
						sp11.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp11.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp11.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e11 =
						    [cb renderCommandEncoderWithDescriptor:sp11];
						[e11 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e11 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s11Pso || !ap.vb || !ap.ib)
								continue;
							[e11 setRenderPipelineState:ap.s11Pso];
							if (ap.cb)
								[e11 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e11 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e11 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e11 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e11 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						[e11 endEncoding];
					}
					if (s_s8Tex && !s_appQ.empty())
					{
						MTLRenderPassDescriptor* sp12 = [MTLRenderPassDescriptor new];
						sp12.colorAttachments[0].texture = s_s8Tex;
						sp12.colorAttachments[0].loadAction = MTLLoadActionClear;
						sp12.colorAttachments[0].storeAction = MTLStoreActionStore;
						sp12.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
						id<MTLRenderCommandEncoder> e12 =
						    [cb renderCommandEncoderWithDescriptor:sp12];
						[e12 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e12 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s12Pso || !ap.vb || !ap.ib)
								continue;
							[e12 setRenderPipelineState:ap.s12Pso];
							if (ap.cb)
								[e12 setVertexBuffer:ap.cb offset:0 atIndex:0];
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e12 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e12 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
							}
							[e12 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e12 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
						}
						[e12 endEncoding];
					}
					// launch154 S13: captured pair with the LIVE pixel shader.
					if (s_s13Tex[0] && !s_appQ.empty())
					{
						int d13 = 0;
						MTLRenderPassDescriptor* sp13 = [MTLRenderPassDescriptor new];
						for (int a13 = 0; a13 < 4; a13++)
						{
							sp13.colorAttachments[a13].texture = s_s13Tex[a13];
							sp13.colorAttachments[a13].loadAction = MTLLoadActionClear;
							sp13.colorAttachments[a13].storeAction = MTLStoreActionStore;
							sp13.colorAttachments[a13].clearColor = MTLClearColorMake(0, 0, 0, 0);
						}
						// launch166: DECISIVE — did the replayed draws rasterize
						// ANY fragments? samples>0 + texture zero => the writes
						// are lost downstream; samples==0 => the live-PS pair
						// with real data produces no fragments at all.
						if (!g_visE13)
							g_visE13 = [(__bridge id<MTLDevice>)dev->Device()
							                newBufferWithLength:16
							                            options:MTLResourceStorageModeShared];
						sp13.visibilityResultBuffer = g_visE13;
						id<MTLRenderCommandEncoder> e13 =
						    [cb renderCommandEncoderWithDescriptor:sp13];
						// Attaching visibilityResultBuffer alone leaves the counter
						// at zero — the mode must be enabled (launch168 rastcheck).
						[e13 setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
						[e13 setViewport:(MTLViewport){0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0}];
						[e13 setCullMode:MTLCullModeNone];
						for (const auto& ap : s_appQ)
						{
							if (!ap.s13Pso || !ap.vb || !ap.ib)
								continue;
							[e13 setRenderPipelineState:ap.s13Pso];
							if (ap.cb)
							{
								[e13 setVertexBuffer:ap.cb offset:0 atIndex:0];
								[e13 setFragmentBuffer:ap.cb offset:0 atIndex:0];
							}
							for (int vi = 0; vi < 8; vi++)
							{
								if (ap.vtex[vi])
									[e13 setVertexTexture:ap.vtex[vi] atIndex:vi];
								if (ap.vsamp[vi])
									[e13 setVertexSamplerState:ap.vsamp[vi] atIndex:vi];
								if (ap.ptex[vi])
									[e13 setFragmentTexture:ap.ptex[vi] atIndex:vi];
								if (ap.psamp[vi])
									[e13 setFragmentSamplerState:ap.psamp[vi] atIndex:vi];
							}
							[e13 setVertexBuffer:ap.vb offset:0 atIndex:1];
							[e13 drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							               indexCount:ap.idxCount indexType:MTLIndexTypeUInt16
							                 indexBuffer:ap.ib indexBufferOffset:ap.ibOff
							               instanceCount:1 baseVertex:ap.baseV baseInstance:0];
							d13++;
						}
						[e13 endEncoding];
						Log("- p5 S13: drew=%d of %zu", d13, s_appQ.size());
						// launch166: one-shot headless-replay dump — the REAL
						// captured bytes (CB/VB/IB) + binding inventory, so the
						// dead draw can be replayed on /tmp tools forever after
						// without another game window. Env XR_METAL_S13DUMP=1.
						static const int s_s13Dump =
						    getenv("XR_METAL_S13DUMP") ? atoi(getenv("XR_METAL_S13DUMP")) : 0;
						static bool s_dumped = false;
						if (s_s13Dump && !s_dumped)
						{
							s_dumped = true;
							mkdir("/tmp/s13dump", 0755);
							FILE* meta = fopen("/tmp/s13dump/meta.txt", "w");
							int idx = 0;
							for (const auto& ap : s_appQ)
							{
								char path[160];
								snprintf(path, sizeof(path), "/tmp/s13dump/e%d_cb.bin", idx);
								FILE* f = fopen(path, "wb");
								if (f && ap.cb)
								{ fwrite(ap.cb.contents, 1, ap.cb.length, f); fclose(f); }
								snprintf(path, sizeof(path), "/tmp/s13dump/e%d_ib.bin", idx);
								f = fopen(path, "wb");
								if (f && ap.ib)
								{ fwrite((const uint8_t*)ap.ib.contents + ap.ibOff, 1,
								         ap.idxCount * 2, f); fclose(f); }
								snprintf(path, sizeof(path), "/tmp/s13dump/e%d_vb.bin", idx);
								f = fopen(path, "wb");
								if (f && ap.vb)
								{ size_t nvb = ap.vb.length > (size_t)(8u << 20)
								                   ? (size_t)(8u << 20) : (size_t)ap.vb.length;
								  fwrite(ap.vb.contents, 1, nvb, f); fclose(f); }
								if (meta)
								{
									fprintf(meta,
									    "e%d name=%s idxCount=%zu ibOff=%zu baseV=%ld stride=%u "
									    "vbLen=%zu ibLen=%zu\n",
									    idx, ap.name.c_str(), (size_t)ap.idxCount,
									    (size_t)ap.ibOff, (long)ap.baseV, ap.stride,
									    ap.vb ? (size_t)ap.vb.length : 0,
									    ap.ib ? (size_t)ap.ib.length : 0);
									for (int vi = 0; vi < 8; vi++)
										if (ap.ptex[vi])
											fprintf(meta,
											    "  ptex[%d] fmt=%ld type=%ld %lux%lu mips=%lu "
											    "usage=%ld%s\n",
											    vi, (long)ap.ptex[vi].pixelFormat,
											    (long)ap.ptex[vi].textureType,
											    (unsigned long)ap.ptex[vi].width,
											    (unsigned long)ap.ptex[vi].height,
											    (unsigned long)ap.ptex[vi].mipmapLevelCount,
											    (long)ap.ptex[vi].usage,
											    (ap.ptex[vi].usage & MTLTextureUsageShaderRead)
											        ? "" : " <-NO-SHADER-READ");
								}
								// p5 launch178: CONTENT check of the PS textures bound to
								// the captured geometry draws. Chain probe: position
								// output (VS-only) lands, texture-derived outputs
								// (o1/o2 = s_base.sample) are zero -> is the bound
								// texture itself black (broken BC upload)?
								// p5 launch181: BC-correct per-mip content dump
								// of the PS texture bound to the captured
								// geometry draw. Decoded offline: if mip0 has
								// content but mip4 is empty, the mip chain is
								// the black-albedo culprit.
								if (idx == 0 && ap.ptex[0])
								{
									id<MTLTexture> t0 = ap.ptex[0];
									const uint32_t tw = (uint32_t)t0.width,
									               th = (uint32_t)t0.height;
									NSUInteger bb = 0;
									switch (t0.pixelFormat)
									{
									case MTLPixelFormatBC1_RGBA:
									case MTLPixelFormatBC1_RGBA_sRGB:
										bb = 8; break;
									case MTLPixelFormatBC3_RGBA:
									case MTLPixelFormatBC3_RGBA_sRGB:
									case MTLPixelFormatBC2_RGBA:
									case MTLPixelFormatBC2_RGBA_sRGB:
									case MTLPixelFormatBC7_RGBAUnorm:
									case MTLPixelFormatBC7_RGBAUnorm_sRGB:
										bb = 16; break;
									default: break;
									}
									const uint32_t linBpp =
									    dev->TextureBpp((__bridge void*)t0);
									const uint32_t mipsToTry[2] = { 0, 4 };
									for (int mi = 0; mi < 2; mi++)
									{
										const uint32_t m = mipsToTry[mi];
										if (m >= (uint32_t)t0.mipmapLevelCount)
											continue;
										const uint32_t mw = (tw >> m) ? (tw >> m) : 1,
										               mh = (th >> m) ? (th >> m) : 1;
										const uint32_t bpr = bb
										                       ? ((mw + 3) / 4) * (uint32_t)bb
										                       : mw * linBpp;
										const uint32_t rows = bb ? ((mh + 3) / 4) : mh;
										if (!bpr)
											continue;
										std::vector<uint8_t> tp(size_t(bpr) * rows);
										std::string terr;
										if (!dev->ReadbackSlice((__bridge void*)t0,
										                        tp.data(), bpr, mw, mh,
										                        0, m, terr))
										{
											Log("! p5 S13tex: mip%u readback failed: %s",
											    m, terr.c_str());
											continue;
										}
										size_t tnz = 0;
										for (size_t k = 0; k < tp.size(); k += 16)
											if (tp[k])
												tnz++;
										char path[128];
										snprintf(path, sizeof path,
										         "/tmp/s13dump/t0_mip%u.bin", m);
										FILE* tf = fopen(path, "wb");
										if (tf)
										{
											fwrite(tp.data(), 1, tp.size(), tf);
											fclose(tf);
										}
										Log("- p5 S13tex: fmt=%ld mips=%ld mip%u %ux%u "
										    "bpr=%u nz=%zu/%zu -> %s",
										    (long)t0.pixelFormat,
										    (long)t0.mipmapLevelCount, m, mw, mh, bpr,
										    tnz, tp.size() / 16, path);
									}
								}
								idx++;
							}
							if (meta)
								fclose(meta);
							Log("- p5 S13dump: %d entries -> /tmp/s13dump", idx);
						}
					}
					else if (!s_appQ.empty())
						Log("! p5 S13: pass skipped (scratch nil=%d)", s_s13Tex[0] == nil);
					s_appQ.clear();
				}
				[cb commit];
				[cb waitUntilCompleted];
				id<MTLTexture> tex = (__bridge id<MTLTexture>)pg;
				const uint32_t w = (uint32_t)tex.width, h = (uint32_t)tex.height;
				std::vector<uint8_t> px(size_t(w) * h * 4);
				std::string err;
				if (!dev->ReadbackSlice(pg, px.data(), w * 4, w, h, 0, 0, err))
					Log("- p5 postgeom: readback failed: %s", err.c_str());
				else
				{
					size_t nz = 0, nL = 0, nT0 = 0, nT1 = 0, nV = 0, nW = 0, nX = 0, nZ = 0,
					       nU = 0;
					for (size_t k = 0; k + 6 <= px.size(); k += 64)
					{
						if (px[k] | px[k + 1] | px[k + 2])
							nz++;
						if (px[k + 1] == 56)
							nL++; // R=0.5 -> passthru fragment LANDED
						// launch144: half hi-bytes VERIFIED with a conversion
						// program (/tmp/halfchk.c): 1.0->60, 0.75->58 (the
						// launch143 'fix' said 54 = 0.375, still wrong: V=0 was
						// artifact #2, cf. mid=(0,58,..) tick=6), 0.5->56,
						// 0.375->54 (U), 0.25->52, 0.1875->50 (Z), 0.125->48.
						if (px[k + 1] == 58)
							nV++; // R=0.75 -> V-draw (trivial VS on pair VB) landed
						if (px[k + 1] == 52)
							nW++; // R=0.25 -> W-draw (device-ref raw VB) landed
						if (px[k + 1] == 48)
							nX++; // R=0.125 -> X-draw (descriptor path, good IB) landed
						if (px[k + 1] == 50)
							nZ++; // R=0.1875 -> Z-draw (captured IB, off 0, baseV 0)
						if (px[k + 1] == 54)
							nU++; // R=0.375 -> U-draw (captured IB+offset, baseV 0)
						if (px[k + 3] == 60)
							nT0++; // G=1.0 -> TEXCOORD0 interpolant alive
						if (px[k + 5] == 60)
							nT1++; // B=1.0 -> TEXCOORD1 interpolant alive
					}
					const size_t mid = (size_t(h / 2) * w + w / 2) * 4;
					Log("- p5 postgeom: position nz=%zu L=%zu V=%zu W=%zu X=%zu Z=%zu U=%zu "
					    "T0=%zu T1=%zu mid=(%u,%u,%u,%u) tick=%d pg=%p",
					    nz, nL, nV, nW, nX, nZ, nU, nT0, nT1, px[mid], px[mid + 1], px[mid + 2],
					    px[mid + 3], g_pgGate % s_pgPeriod, pg);
				}
				// p5 launch187: standalone gate — the position block can bail
				// before this line (readback failure / nil pg), so postalb needs
				// its own counter. Answers: does albedo ever hold pixels?
				{
					static uint64_t s_paTick = 0;
					static int s_paN = 0; // p5 launch228: count-based gating — the
					void* pa = nullptr;   // %240 phase missed the in-game window.
					if (pgAlb && (s_paTick++ % 20 == 7) && s_paN < 20)
					{
						pa = pgAlb;
						s_paN++;
					}
					if (pa && PM().dev)
					{
						id<MTLTexture> at = (__bridge id<MTLTexture>)pa;
						const uint32_t aw = (uint32_t)at.width, ah = (uint32_t)at.height;
						const uint32_t abpp = PM().dev->TextureBpp(pa);
						if (abpp)
						{
							std::vector<uint8_t> ap(size_t(aw) * ah * abpp);
							std::string aerr;
							if (PM().dev->ReadbackSlice(pa, ap.data(), aw * abpp, aw, ah, 0, 0,
							                            aerr))
							{
								size_t anz = 0, b0 = 0, b1 = 0, b2 = 0;
								for (size_t k = 0; k + 3 < ap.size(); k += 64)
								{
									if (ap[k] | ap[k + 1] | ap[k + 2])
										anz++;
									if (ap[k])
										b0++;
									if (ap[k + 1])
										b1++;
									if (ap[k + 2])
										b2++;
								}
								const size_t amid = (size_t(ah / 2) * aw + aw / 2) * abpp;
								Log("- p5 postalb: %s %ux%u bpp=%u nz=%zu B=%zu G=%zu R=%zu "
								    "mid=(%u,%u,%u,%u)",
								    MtlDbgRTGetName(pa), aw, ah, abpp, anz, b0, b1, b2, ap[amid],
								    ap[amid + 1], ap[amid + 2], ap[amid + 3]);
							}
							else
								Log("! p5 postalb: readback failed: %s", aerr.c_str());
						}
					}
				}
				// p5 launch227: content of the diffuse texture bound to gbuffer
				// draws (albedo-color-is-black hunt). ReadbackSlice is BC-aware.
				{
					static uint64_t s_dtTick = 0;
					static int s_dtN = 0; // p5 launch228: count-gated like postalb.
					void* dt = nullptr;
					if (PM().pendingDefferTex && (s_dtTick++ % 20 == 11) && s_dtN < 12)
					{
						dt = PM().pendingDefferTex;
						s_dtN++;
					}
					if (dt && PM().dev)
					{
						id<MTLTexture> dtx = (__bridge id<MTLTexture>)dt;
						const uint32_t dw = (uint32_t)dtx.width, dh = (uint32_t)dtx.height;
						std::vector<uint8_t> db(size_t(dw) * dh * 4);
						std::string derr;
						if (PM().dev->ReadbackSlice(dt, db.data(), dw * 4, dw, dh, 0, 0, derr))
						{
							size_t dnz = 0;
							uint8_t chx[3] = { 0, 0, 0 };
							for (size_t k = 0; k + 3 < db.size(); k += 4)
							{
								if (db[k] | db[k + 1] | db[k + 2])
									dnz++;
								for (int c = 0; c < 3; c++)
									if (db[k + c] > chx[c])
										chx[c] = db[k + c];
							}
							Log("- p5 deftex: %ux%u t%ld nz=%zu/%zu chmax=(%u,%u,%u)", dw, dh,
							    (long)dtx.textureType, dnz, db.size() / 4, chx[0], chx[1], chx[2]);
						}
						else
							Log("! p5 deftex: readback failed: %s", derr.c_str());
						PM().pendingDefferTex = nullptr;
					}
				}
				// p5 launch184 postalb block REMOVED (launch195): it read
				// RGBA16F albedo (8 bpp) with a 4-bpp buffer — heap overflow
				// → SIGSEGV in ensureEncoder seconds after entering game.
				// The standalone block above (TextureBpp-based) supersedes it.
				// launch138: S-draw readback — hit count + bbox on the 1024²
				// scratch: where the pair draws projected with a clean,
				// depth-free target. bbox centered ~ (512,512) = on-screen.
				if (s_sTex)
				{
					std::vector<uint8_t> sx(size_t(1024) * 1024 * 4);
					std::string errS2;
					if (!dev->ReadbackSlice((__bridge void*)s_sTex, sx.data(), 1024 * 4, 1024,
					                        1024, 0, 0, errS2))
						Log("- p5 canaryI: Sdraw readback failed: %s", errS2.c_str());
					else
					{
						size_t hits = 0, hits2 = 0;
						int x0 = 2000, y0 = 2000, x1 = -1, y1 = -1;
						int u0 = 2000, v0 = 2000, u1 = -1, v1 = -1;
						for (uint32_t yy = 0; yy < 1024; yy++)
							for (uint32_t xx = 0; xx < 1024; xx++)
							{
								const uint8_t* p = sx.data() + (size_t(yy) * 1024 + xx) * 4;
								if (p[0])
								{ // white (S-draw) — R set
									hits++;
									if ((int)xx < x0)
										x0 = (int)xx;
									if ((int)xx > x1)
										x1 = (int)xx;
									if ((int)yy < y0)
										y0 = (int)yy;
									if ((int)yy > y1)
										y1 = (int)yy;
								}
								else if (p[1])
								{ // green (S2-draw, launch144) — G set, R clear
									hits2++;
									if ((int)xx < u0)
										u0 = (int)xx;
									if ((int)xx > u1)
										u1 = (int)xx;
									if ((int)yy < v0)
										v0 = (int)yy;
									if ((int)yy > v1)
										v1 = (int)yy;
								}
							}
						Log("- p5 canaryI: Sdraw hits=%zu bbox=(%d,%d..%d,%d) S2draw hits=%zu "
						    "bbox=(%d,%d..%d,%d)",
						    hits, x0, y0, x1, y1, hits2, u0, v0, u1, v1);
					}
				}
				// launch145: S4 clip-coord histogram (own scratch): pixel =
				// (B=0.5 marker, G=z/w mapped, R=w<0?0.25:0.5). BGRA8 bytes:
				// p0=B p1=G p2=R.
				if (s_s3Tex)
				{
					std::vector<uint8_t> sx3(size_t(1024) * 1024 * 4);
					std::string err3;
					if (!dev->ReadbackSlice((__bridge void*)s_s3Tex, sx3.data(), 1024 * 4,
					                        1024, 1024, 0, 0, err3))
						Log("- p5 canaryI: S4 readback failed: %s", err3.c_str());
					else
					{
						// launch149 S10 fine buckets: G = clamp(2(z/w - 1)+0.5)*255.
						// G==0 => z/w<=0.75; G==255 => z/w>=1.25; G~127 => z/w~1.
						size_t wneg = 0, satLo = 0, below = 0, hug = 0, above = 0,
						       satHi = 0;
						for (size_t k = 0; k + 2 < sx3.size(); k += 4)
						{
							const uint8_t* p = sx3.data() + k;
							if (p[0] < 100 || p[0] > 180)
								continue; // not a clipps pixel (B=0.5 marker)
							if (p[2] < 100)
							{
								wneg++;
								continue;
							}
							if (p[1] == 0)
								satLo++;
							else if (p[1] == 255)
								satHi++;
							else if (p[1] < 124)
								below++;
							else if (p[1] <= 130)
								hug++;
							else
								above++;
						}
						Log("- p5 canaryI: S10fine wNeg=%zu z/w[satLo,below,hug1,above,"
						    "satHi]=%zu,%zu,%zu,%zu,%zu",
						    wneg, satLo, below, hug, above, satHi);
					}
				}
				// launch145: S5 (cyan) / S6 (red) landing booleans.
				if (s_s4Tex)
				{
					std::vector<uint8_t> sx4(size_t(1024) * 1024 * 4);
					std::string err4;
					if (!dev->ReadbackSlice((__bridge void*)s_s4Tex, sx4.data(), 1024 * 4,
					                        1024, 1024, 0, 0, err4))
						Log("- p5 canaryI: S56 readback failed: %s", err4.c_str());
					else
					{
						size_t c5 = 0, c6 = 0;
						for (size_t k = 0; k + 2 < sx4.size(); k += 4)
						{
							const uint8_t* p = sx4.data() + k;
							if (p[1] > 200 && p[0] > 200 && p[2] < 60)
								c5++; // cyan: S5 (z=0.5w) landed
							else if (p[2] > 200 && p[1] < 60 && p[0] < 60)
								c6++; // red: S6 (w=-w) landed
						}
						Log("- p5 canaryI: S5zfix hits=%zu S6wflip hits=%zu", c5, c6);
					}
				}
				// launch147: S8 (magenta, z'=0.5z+0.5w) + S9 (yellow,
				// z'=0.5z+w) landing counts — production fix deciders.
				{
					size_t c8 = 0, c9 = 0;
					std::string errC;
					std::vector<uint8_t> sx8(size_t(1024) * 1024 * 4);
					if (s_s5Tex && dev->ReadbackSlice((__bridge void*)s_s5Tex, sx8.data(),
					                                  1024 * 4, 1024, 1024, 0, 0, errC))
						for (size_t k = 0; k + 2 < sx8.size(); k += 4)
							if (sx8[k] > 200 && sx8[k + 2] > 200 && sx8[k + 1] < 60)
								c8++; // BGRA magenta: B>200,R>200,G<60
					std::vector<uint8_t> sx9(size_t(1024) * 1024 * 4);
					if (s_s6Tex && dev->ReadbackSlice((__bridge void*)s_s6Tex, sx9.data(),
					                                  1024 * 4, 1024, 1024, 0, 0, errC))
						for (size_t k = 0; k + 2 < sx9.size(); k += 4)
							if (sx9[k + 1] > 200 && sx9[k + 2] > 200 && sx9[k] < 60)
								c9++; // BGRA yellow: G>200,R>200,B<60
					Log("- p5 canaryI: S8zremap hits=%zu S9zbias hits=%zu", c8, c9);
				}
				// launch149: S11 (lime) / S12 (orange) landing counts.
				{
					size_t c11 = 0, c12 = 0;
					std::string errC;
					std::vector<uint8_t> sx11(size_t(1024) * 1024 * 4);
					if (s_s7Tex && dev->ReadbackSlice((__bridge void*)s_s7Tex, sx11.data(),
					                                  1024 * 4, 1024, 1024, 0, 0, errC))
						for (size_t k = 0; k + 2 < sx11.size(); k += 4)
							if (sx11[k] < 60 && sx11[k + 1] > 200 && sx11[k + 2] > 100 &&
							    sx11[k + 2] < 180)
								c11++; // lime: B~0 G~255 R~127
					std::vector<uint8_t> sx12(size_t(1024) * 1024 * 4);
					if (s_s8Tex && dev->ReadbackSlice((__bridge void*)s_s8Tex, sx12.data(),
					                                  1024 * 4, 1024, 1024, 0, 0, errC))
						for (size_t k = 0; k + 2 < sx12.size(); k += 4)
							if (sx12[k] < 60 && sx12[k + 1] > 100 && sx12[k + 1] < 180 &&
							    sx12[k + 2] > 200)
								c12++; // orange: B~0 G~127 R~255
					Log("- p5 canaryI: S11halfshift hits=%zu S12clamp hits=%zu", c11, c12);
				}
				// launch155: S13 live-PS landing — RGBA32Float scratch so NaN
				// survives (BGRA8 converted NaN to 0, verdict ambiguous).
				{
					size_t c13 = 0, n13 = 0;
					std::string errC;
					std::vector<uint8_t> sx13(size_t(1024) * 1024 * 16);
					if (s_s13Tex[0] && dev->ReadbackSlice((__bridge void*)s_s13Tex[0],
					                                      sx13.data(), 1024 * 16, 1024,
					                                      1024, 0, 0, errC))
					{
						const float* f13 = reinterpret_cast<const float*>(sx13.data());
						for (size_t p = 0; p + 3 < sx13.size() / 4; p += 4)
						{
							bool nan = false, real = false;
							for (int ch = 0; ch < 4; ch++)
							{
								const float v = f13[p + ch];
								if (std::isnan(v))
									nan = true;
								else if (v > 1e-6f || v < -1e-6f)
									real = true;
							}
							if (nan)
								n13++;
							else if (real)
								c13++;
						}
					}
					const uint32_t vis13 =
					    g_visE13 ? *(const uint32_t*)g_visE13.contents : 0u;
					const uint32_t visLive =
					    g_visLiveBuf ? *(const uint32_t*)g_visLiveBuf.contents : 0u;
					Log("- p5 canaryI: S13liveps real=%zu nan=%zu samples=%u livevis=%u "
					    "nopso=%llu",
					    c13, n13, vis13, visLive, (unsigned long long)g_dbgDrawNoPso);
				}
id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)dev->Queue();
				cb = [q commandBuffer];
				identityDirty = true;
			}
		}
		if (!cb)
			return;

		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		for (int i = 0; i < 4; i++)
		{
			if (!rt[i])
				continue;
			id<MTLTexture> tex = (__bridge id<MTLTexture>)rt[i];
			MTLRenderPassColorAttachmentDescriptor* att = rpd.colorAttachments[i];
			att.texture = tex;
			// DX9/GL semantics: RT contents persist between passes unconditionally.
			// DontCare on first-touch made contents *undefined* on TBDR (stale-VRAM
			// checkerboard, undefined depth = random tile coverage) — always Load.
			att.loadAction = MTLLoadActionLoad;
			att.storeAction = MTLStoreActionStore;
		}
		// p6: per-pass truth log — does THIS pass actually get zb?
		// (dprobe proved zb is never written; if the position pass
		// logs zb=0, the depth state is a no-op and DX9 z-surface
		// binding is lost on this path.)
		{
			static std::vector<std::string> s_zlinkSeen;
			const char* rnZ = rt[0] ? MtlDbgRTGetName(rt[0]) : nullptr;
			std::string nmZ = rnZ ? rnZ : "?";
			bool seen = false;
			for (const std::string& s : s_zlinkSeen)
				if (s == nmZ)
				{
					seen = true;
					break;
				}
			if (!seen && s_zlinkSeen.size() < 40)
			{
				s_zlinkSeen.push_back(nmZ);
				Log("- p6 passZlink: rt=%s zb=%p", nmZ.c_str(), zb);
			}
		}
		if (zb)
		{
			id<MTLTexture> tex = (__bridge id<MTLTexture>)zb;
			// p5 DIAG (launch152): every depth texture attached to a pass, once.
			{
				static std::vector<void*> s_zbSeen;
				bool seenZ = false;
				for (void* p : s_zbSeen)
					if (p == zb)
					{
						seenZ = true;
						break;
					}
				if (!seenZ && s_zbSeen.size() < 24)
				{
					Log("- p5 DIAG passZB: zb=%p fmt=%ld %lux%lu", zb, (long)tex.pixelFormat,
					    (unsigned long)tex.width, (unsigned long)tex.height);
					s_zbSeen.push_back(zb);
				}
			}
			MTLRenderPassDepthAttachmentDescriptor* att = rpd.depthAttachment;
			att.texture = tex;
			att.loadAction = MTLLoadActionLoad;
			att.storeAction = MTLStoreActionStore;
			if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
			{
				MTLRenderPassStencilAttachmentDescriptor* satt = rpd.stencilAttachment;
				satt.texture = tex;
				satt.loadAction = MTLLoadActionLoad;
				satt.storeAction = MTLStoreActionStore;
			}
		}
		// p5 launch191: feedback guard — copy any attachment that is also
		// bound for sampling (see fbRemap declaration).
		fbRemap.clear();
		{
			static std::map<void*, id<MTLTexture>> s_fbScratch;
			id<MTLTexture> atts[5];
			int natt = 0;
			for (int i = 0; i < 4; i++)
				if (rpd.colorAttachments[i].texture)
					atts[natt++] = rpd.colorAttachments[i].texture;
			if (rpd.depthAttachment.texture)
				atts[natt++] = rpd.depthAttachment.texture;
			std::vector<std::pair<id<MTLTexture>, id<MTLTexture>>> copies; // src,dst
			for (int s = 0; s < kMaxStage; s++)
			{
				id<MTLTexture> st = (__bridge id<MTLTexture>)stageTex[s];
				if (!st)
					continue;
				for (int a = 0; a < natt; a++)
				{
					if (st != atts[a])
						continue;
					void* key = (__bridge void*)atts[a];
					if (fbRemap.count(key))
						continue;
					id<MTLTexture> sc = s_fbScratch[key];
					if (!sc || sc.width != atts[a].width || sc.height != atts[a].height ||
					    sc.pixelFormat != atts[a].pixelFormat)
					{
						MTLTextureDescriptor* fd = [MTLTextureDescriptor
						    texture2DDescriptorWithPixelFormat:atts[a].pixelFormat
														width:atts[a].width
													   height:atts[a].height
													mipmapped:NO];
						fd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
						sc = [(__bridge id<MTLDevice>)dev->Device() newTextureWithDescriptor:fd];
						s_fbScratch[key] = sc;
					}
					if (sc)
					{
						copies.push_back({atts[a], sc});
						fbRemap[key] = (__bridge void*)sc;
					}
				}
			}
			if (!copies.empty() && cb)
			{
				id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
				for (auto& cp : copies)
				{
					MTLSize sz = MTLSizeMake(cp.first.width, cp.first.height, 1);
					[be copyFromTexture:cp.first
							 sourceSlice:0
							 sourceLevel:0
							sourceOrigin:MTLOriginMake(0, 0, 0)
								sourceSize:sz
							  toTexture:cp.second
					   destinationSlice:0
					   destinationLevel:0
					  destinationOrigin:MTLOriginMake(0, 0, 0)];
				}
				[be endEncoding];
			}
		}
		attColorCount = 0;
		for (int i = 0; i < 4; i++)
		{
			id<MTLTexture> t = rpd.colorAttachments[i].texture;
			attColorFmt[i] = t ? (int)t.pixelFormat : 0;
			if (t)
				attColorCount++;
		}
		rpdAtt0 = rpd.colorAttachments[0].texture;
		attDepthFmt = rpd.depthAttachment.texture ? (int)rpd.depthAttachment.texture.pixelFormat : 0;
		// launch166: XR_METAL_VIS=1 — per-pass sample counter on the LIVE
		// position pass. The pass is committed+waited by the readback flush,
		// so the count is CPU-readable in the SAME window as the texture
		// scan: livevis>0 + postgeom flat => fragments exist, writes lost;
		// livevis==0 => the live draws rasterize nothing.
		BOOL visAttached = NO;
		{
			static const int s_visLive =
			    getenv("XR_METAL_VIS") ? atoi(getenv("XR_METAL_VIS")) : 0;
			if (s_visLive && rt[0] && g_mtlRtNames.count(rt[0]) &&
			    g_mtlRtNames[rt[0]] == "$user$position")
			{
				g_visLiveBuf = [(__bridge id<MTLDevice>)dev->Device()
				                    newBufferWithLength:16
				                                options:MTLResourceStorageModeShared];
				rpd.visibilityResultBuffer = g_visLiveBuf;
				visAttached = YES;
			}
			// launch279b: same trick for the accum pass — pass-level fragment
			// count distinguishes "sun/canary draws rasterize nothing" (vis=0
			// despite draws) from "fragments exist, color writes lost" (vis>0,
			// readback zero). Read by the postaccum probe post commit+wait.
			if (s_visLive && rt[0] && g_mtlRtNames.count(rt[0]) &&
			    g_mtlRtNames[rt[0]] == "$user$accum")
			{
				g_visAccumBuf = [(__bridge id<MTLDevice>)dev->Device()
				                    newBufferWithLength:16
				                                options:MTLResourceStorageModeShared];
				rpd.visibilityResultBuffer = g_visAccumBuf;
				visAttached = YES;
			}
		}
		MtlInstallValidationGuard(); // render-thread first encoder
		enc = [cb renderCommandEncoderWithDescriptor:rpd];
		if (visAttached) // mode WITHOUT an attached buffer = validation abort (launch171)
			[enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
		g_dbgEncoders++;
		identityDirty = false;
		applyEncoderState();
	}

	void MtlPassManager::applyEncoderState()
	{
		if (!enc)
			return;
		const MTLViewport vp{ vpX, vpY, vpW, vpH, vpMin, vpMax };
		[enc setViewport:vp];
		// p5 launch250: XR_P5_NOSCISSOR=1 skips the rect entirely (a stale
		// small rect from an earlier phase, left because scissor-disable has
		// no Metal equivalent, silently culls every fragment).
		static const int s_noScis = getenv("XR_P5_NOSCISSOR") ? atoi(getenv("XR_P5_NOSCISSOR")) : 0;
		if (scissorEn && !s_noScis)
		{
			const MTLScissorRect r{ (NSUInteger)scL, (NSUInteger)scT, (NSUInteger)(scR - scL),
				                    (NSUInteger)(scB - scT) };
			[enc setScissorRect:r];
		}
		else if (s_noScis)
		{
			uint32_t rw = 0, rh = 0;
			if (rt[0] && dev)
				dev->TextureDims(rt[0], &rw, &rh);
			const MTLScissorRect r{ 0, 0, rw ? rw : (NSUInteger)vpW,
				                    rh ? rh : (NSUInteger)vpH };
			[enc setScissorRect:r];
		}
		// p6 band-hunt: flag every state application whose viewport or scissor
		// is narrower than the bound RT. One such rect, painted black or left
		// to cull, is the world-clipping band we keep seeing at x~2304.
		{
			uint32_t rw = 0, rh = 0;
			if (rt[0] && dev)
				dev->TextureDims(rt[0], &rw, &rh);
			if (rw > 1600 && rh > 800) // screen-sized targets only
			{
				const bool vpOff = vpX != 0 || vpY != 0 || vpW != (double)rw || vpH != (double)rh;
				const bool scNarrow = scissorEn && !s_noScis &&
				                      ((scR - scL) < (long)(rw * 0.95) || (scB - scT) < (long)(rh * 0.95));
				if (vpOff || scNarrow)
				{
					// dedupe by signature: repeated sunmask tiles must not
					// starve the budget — every UNIQUE rect gets logged.
					static std::unordered_map<std::string, int> s_seen;
					char sig[192];
					snprintf(sig, sizeof(sig), "%s|%u|%u|%.0f|%.0f|%.0f|%.0f|%d|%d|%d|%d|%d",
					         rt[0] ? "?" : "null", rw, rh, vpX, vpY, vpW, vpH,
					         (int)scissorEn, scL, scT, scR, scB);
					int& n = s_seen[sig];
					if (n++ == 0 && s_seen.size() <= 48)
					{
						const char* rnC = rt[0] ? MtlDbgRTGetName(rt[0]) : nullptr;
						Log("- p6 rectdbg #%d: rt=%s %ux%u vp=(%.0f,%.0f,%.0fx%.0f) sc=%d(%d,%d,%d,%d)",
						    (int)s_seen.size(), rnC ? rnC : "?", rw, rh, vpX, vpY, vpW, vpH,
						    (int)scissorEn, scL, scT, scR, scB);
					}
				}
			}
		}
		DepthStencilDesc ds;
		ds.depthEnable = depthEn;
		ds.depthFunc = depthFunc;
		ds.depthWrite = depthWrite;
		// p6: one-shot truth log — which Z state the first gbuffer draws
		// actually bind (the dprobe sweep showed zb never written: suspect
		// every position-pass draw runs with depth-write off).
		{
			static int s_dsLog = 0;
			const char* rnD = rt[0] ? MtlDbgRTGetName(rt[0]) : nullptr;
			if (s_dsLog < 24 && rnD && strstr(rnD, "position"))
			{
				s_dsLog++;
				Log("- p6 dssg: zE=%d zF=%d zW=%d sE=%d", (int)depthEn, depthFunc,
				    (int)depthWrite, (int)stencilEn);
			}
		}
		ds.stencilEnable = stencilEn;
		ds.readMask = stMask;
		ds.writeMask = stWMask;
		ds.func = stFunc;
		ds.failOp = stFail;
		ds.passOp = stPass;
		ds.zFailOp = stZFail;
		id<MTLDepthStencilState> dss = (__bridge id<MTLDepthStencilState>)cache->DepthStateFull(dev->Device(), ds);
		// p6: pair the created DSS + encoder pointers with the drawZ log —
		// if drawZ sees a different enc pointer, draws run on an encoder
		// applyEncoderState never configured (=> default DSS: Always/no-write).
		{
			static int s_dg2 = 0;
			const char* rnP = rt[0] ? MtlDbgRTGetName(rt[0]) : nullptr;
			if (s_dg2 < 12 && rnP && strstr(rnP, "position"))
			{
				s_dg2++;
				dbgLastDss = (__bridge void*)dss;
				dbgLastEnc = (__bridge void*)enc;
				Log("- p6 dssgPtr: enc=%p dss=%p zE=%d zF=%d zW=%d sE=%d",
				    (__bridge void*)enc, (__bridge void*)dss, (int)depthEn,
				    depthFunc, (int)depthWrite, (int)stencilEn);
			}
		}
		if (dss)
			[enc setDepthStencilState:dss];
		[enc setStencilReferenceValue:stRef];
		// DX9/D3D convention: front faces clockwise (the engine's UI quads
		// are authored for the Y-flipping 2D ortho, and stub_notransform_t
		// reproduces that flip, so CW is front for every DX9-convention
		// draw). Cull mode maps from the recorded DX9 state alongside.
		// p5 DIAG (launch104): env overrides to test the winding-cull theory
		// on the live encoder without rebuilding per hypothesis.
		// launch164 VERDICT: winding-cull theory DEAD — NOCULL=1 in-game still
		// zero-writes (same as launch153), and headless same-pair tests land
		// under every cull config with correct orientation. Keep CW mapping.
		static const int s_frontCCW = getenv("XR_METAL_FRONT") ? atoi(getenv("XR_METAL_FRONT")) : 0;
		static const int s_noCull = getenv("XR_METAL_NOCULL") ? atoi(getenv("XR_METAL_NOCULL")) : 0;
		[enc setFrontFacingWinding:s_frontCCW ? MTLWindingCounterClockwise : MTLWindingClockwise]; // D3D convention
		[enc setCullMode:s_noCull ? MTLCullModeNone : (MTLCullMode)MtlMapCull(cull)];
		[enc setTriangleFillMode:(MTLTriangleFillMode)MtlMapFillMode(fill)];
	}

	id<MTLRenderPipelineState> MtlPassManager::blitPipeline(MTLPixelFormat fmt, bool fillMode, bool depthPass,
	                                                        int dfmt)
	{
		initBuiltins();
		if (!blitVs || !blitPs)
			return nil;
		const int dfmtBits = dfmt == 0 ? 0 : (dfmt == (int)MTLPixelFormatDepth32Float_Stencil8 ? 1 : 2);
		const uint32_t key =
			((uint32_t)fmt << 4) | ((uint32_t)dfmtBits << 2) | (fillMode ? 2u : 0u) | (depthPass ? 1u : 0u);
		auto it = blitPso.find(key);
		if (it != blitPso.end())
			return it->second;
		PipelineDesc pd;
		pd.vs = (__bridge void*)blitVs;
		pd.ps = fillMode ? (__bridge void*)fillPs : (__bridge void*)blitPs;
		pd.attrs.clear(); // vertex-id VS
		pd.colorFormats = depthPass ? std::vector<int>{} : std::vector<int>{ (int)fmt };
		if (depthPass)
			pd.colorFormat = -1; // no color attachment
		else
			pd.colorFormat = (int)fmt;
		if (depthPass)
		{
			pd.depthFormat = (int)fmt; // depth format == attachment
			if (fmt == MTLPixelFormatDepth32Float_Stencil8)
				pd.stencilFormat = (int)fmt; // combined format needs BOTH declared
		}
		else if (dfmt)
		{
			// Color pipeline drawing into a depth-attached framebuffer
			// (canaryG/bisect on live encoders) — declare it to match.
			pd.depthFormat = dfmt;
			if (dfmt == (int)MTLPixelFormatDepth32Float_Stencil8)
				pd.stencilFormat = dfmt;
		}
		pd.blend.enabled = false;
		std::string error;
		id<MTLRenderPipelineState> pso =
			(__bridge id<MTLRenderPipelineState>)cache->Pipeline(dev->Device(), pd, error);
		if (!pso)
			Log("! xrRenderMetal: builtin pipeline failed: %s", error.c_str());
		else
			blitPso[key] = pso;
		return pso;
	}

	id<MTLRenderPipelineState> MtlPassManager::fillPipelineMRT()
	{
		initBuiltins();
		if (!blitVs || !attColorCount)
			return nil;
		std::vector<int> key;
		key.insert(key.end(), attColorFmt, attColorFmt + attColorCount);
		key.push_back(attDepthFmt);
		auto it = fillMrtPso.find(key);
		if (it != fillMrtPso.end())
			return it->second;
		// Zero-binding pair: xrtri_vs (hardcoded NDC triangle) + xrredN_ps
		// (hardcoded red, color(N) outputs only) - no buffers, no stage_in,
		// nothing that can silently mismatch live encoder state.
		const char* fn = attColorCount == 1 ? "xrred1_ps"
		              : attColorCount == 2 ? "xrred2_ps"
		              : attColorCount == 3 ? "xrred3_ps"
		                                   : "xrred4_ps";
		id<MTLFunction> psF = [blitLib newFunctionWithName:@(fn)];
		id<MTLFunction> vsF = [blitLib newFunctionWithName:@"xrtri_vs"];
		if (!psF || !vsF)
			return nil;
		PipelineDesc pd;
		pd.vs = (__bridge void*)vsF;
		pd.ps = (__bridge void*)psF;
		pd.attrs.clear(); // vertex-id VS
		pd.colorFormats = std::vector<int>(attColorFmt, attColorFmt + attColorCount);
		if (attDepthFmt)
		{
			pd.depthFormat = attDepthFmt;
			if (attDepthFmt == (int)MTLPixelFormatDepth32Float_Stencil8)
				pd.stencilFormat = attDepthFmt;
		}
		pd.depthEnabled = false; // pipeline-side: always + no write
		pd.blend.enabled = false;
		std::string error;
		id<MTLRenderPipelineState> pso =
			(__bridge id<MTLRenderPipelineState>)cache->Pipeline(dev->Device(), pd, error);
		if (!pso)
			Log("! p6 fillMRT: pipeline failed (%d atts): %s", attColorCount, error.c_str());
		else
			fillMrtPso[key] = pso;
		return pso;
	}

	// --- vertex layout ---------------------------------------------------------
	// Match SPIRV-Cross [[attribute(N)]] inputs (HLSL declaration order) against
	// the DX9 declaration. Semantics: POSITION/TANGENT/BINORMAL/NORMAL/COLOR<i>/
	// TEXCOORD<i>/POSITIONT map to D3DDECLUSAGE_* + index.
	struct DeclCursor
	{
		const D3DVERTEXELEMENT9* elems;
		uint32_t count;
		int next[16]; // per-usage scan cursor

		int find(uint32_t usage, uint32_t index)
		{
			if (usage >= 16)
				return -1;
			for (int i = next[usage]; i < (int)count; i++)
				if (elems[i].Usage == usage && elems[i].UsageIndex == index)
				{
					next[usage] = i + 1;
					return i;
				}
			// rewind scan (matrix rows revisit with index+1 — cursor may have passed)
			for (int i = 0; i < (int)count; i++)
				if (elems[i].Usage == usage && elems[i].UsageIndex == index)
					return i;
			return -1;
		}
	};

	bool ParseSemantic(const std::string& sem, uint32_t& usage, uint32_t& index)
	{
		index = 0;
		size_t digitsPos = sem.size();
		while (digitsPos > 0 && std::isdigit((unsigned char)sem[digitsPos - 1]))
			digitsPos--;
		if (digitsPos < sem.size())
			index = (uint32_t)std::stoi(sem.substr(digitsPos));
		const std::string base = sem.substr(0, digitsPos);
		if (base == "POSITION") usage = 0;
		else if (base == "BLENDWEIGHT") usage = 1;
		else if (base == "BLENDINDICES") usage = 2;
		else if (base == "NORMAL") usage = 3;
		else if (base == "PSIZE") usage = 4;
		else if (base == "TEXCOORD") usage = 5;
		else if (base == "TANGENT") usage = 6;
		else if (base == "BINORMAL") usage = 7;
		else if (base == "TESSFACTOR") usage = 8;
		else if (base == "POSITIONT") usage = 9;
		else if (base == "COLOR") usage = 10;
		else if (base == "FOG") usage = 11;
		else if (base == "DEPTH") usage = 12;
		else usage = 13;
		return true;
	}

	uint32_t MapDeclFormat(uint32_t d3dType)
	{
		// launch128: runtime enum probe (/tmp/vfchk.m) — UShort2Normalized=19 (was
		// wrongly 20=UShort3Normalized: 6-byte read of a 4-byte packed texcoord,
		// killing every USHORT2N TEXCOORD0 interpolant => zeroed g-buffer).
		// FLOAT1 is a single float, not Half.
		switch (d3dType)
		{
		case 0: return 28; // FLOAT1 -> Float
		case 1: return 29; // FLOAT2 -> Float2
		case 2: return 30; // FLOAT3 -> Float3
		case 3: return 31; // FLOAT4 -> Float4
		case 4: return 9;  // D3DCOLOR -> UChar4Normalized (byte order R,G,B,A)
		case 5: return 3;  // UBYTE4 -> UChar4
		case 6: return 16; // SHORT2 -> Short2
		case 7: return 18; // SHORT4 -> Short4
		case 8: return 9;  // UBYTE4N -> UChar4Normalized
		case 9: return 22; // SHORT2N -> Short2Normalized
		case 10: return 24; // SHORT4N -> Short4Normalized
		case 11: return 19; // USHORT2N -> UShort2Normalized (runtime-verified)
		case 12: return 21; // USHORT4N -> UShort4Normalized
		case 15: return 25; // FLOAT16_2 -> Half2
		case 16: return 27; // FLOAT16_4 -> Half4
		default: return 30; // Float3 fallback
		}
	}

	// launch129 GL-parity fix for raw-integer packed vertex attributes.
	// D3DDECLTYPE SHORT2/SHORT4/UBYTE4 etc. deliver RAW values to float VS
	// inputs on GL/D3D9 (normalize=GL_FALSE), but Metal's raw-int vertex
	// formats deliver raw*0.5 (measured: /tmp/vfprobe.m), and int MSL inputs
	// additionally TRUNCATE the .5 (odd bone indices die). Compile a VS
	// variant at PSO-resolve time that multiplies the affected attributes
	// back by 2: float fields scaled at main0 entry, int fields retyped to
	// float (fraction survives) and cast at each use site.
	static bool MtlFmtRawInt(uint32_t fmt)
	{
		switch (fmt)
		{
		case 3:  // UChar4
		case 6:  // Char4
		case 13: // UShort2
		case 14: // UShort3
		case 15: // UShort4
		case 16: // Short2
		case 17: // Short3
		case 18: // Short4
			return true;
		default: return false;
		}
	}

	// Components delivered by each raw-int format. Metal pads wider MSL fields
	// with D3D9 defaults (z=0, w=1) — the x2 mask must skip padded components.
	static int MtlFmtComps(uint32_t fmt)
	{
		switch (fmt)
		{
		case 13: // UShort2
		case 16: // Short2
			return 2;
		case 14: // UShort3
		case 17: // Short3
			return 3;
		default: return 4; // 3/6 UChar4/Char4, 15/18 UShort4/Short4
		}
	}

	static id<MTLFunction> MtlRawIntScaledVS(id<MTLDevice> dev, const std::string& mslIn,
	                                         const std::vector<VertexAttr>& attrs,
	                                         std::string& errOut)
	{
		const size_t s = mslIn.find("struct main0_in");
		if (s == std::string::npos)
			return nil;
		const size_t b = mslIn.find('{', s);
		const size_t e = b == std::string::npos ? std::string::npos : mslIn.find("};", b);
		const size_t v0 = mslIn.find("vertex main0_out main0(");
		if (b == std::string::npos || e == std::string::npos || v0 == std::string::npos)
			return nil;
		std::string src = mslIn;
		std::string inserts;
		bool changed = false;
		size_t pos = b + 1;
		while (pos < e)
		{
			size_t nl = src.find('\n', pos);
			if (nl == std::string::npos || nl > e)
				nl = e;
			const std::string line = src.substr(pos, nl - pos);
			const size_t at = line.find("[[attribute(");
			pos = nl + 1;
			if (at == std::string::npos)
				continue;
			const int attr = atoi(line.c_str() + at + 12);
			uint32_t fmt = 0;
			for (const auto& a : attrs)
				if (a.index == (uint32_t)attr && MtlFmtRawInt(a.format))
					fmt = a.format;
			if (!fmt)
				continue;
			// "TYPE NAME [[attribute(K)]];" -> tokens
			size_t sp1 = line.find_first_not_of(" \t");
			size_t sp2 = sp1 == std::string::npos ? std::string::npos : line.find(' ', sp1);
			if (sp1 == std::string::npos || sp2 == std::string::npos || sp2 >= at)
				continue;
			const std::string ty = line.substr(sp1, sp2 - sp1);
			size_t ns = line.find_first_not_of(" \t", sp2);
			size_t ne = line.find_first_of(" \t[", ns);
			if (ns == std::string::npos || ne == std::string::npos || ne > at)
				continue;
			const std::string nm = line.substr(ns, ne - ns);
			if (ty.empty() || ty.back() < '1' || ty.back() > '4')
				continue;
			const int width = ty.back() - '0';
			const int comps = MtlFmtComps(fmt);
			// x2 mask: delivered components scale, D3D9-padded defaults (z=0,
			// w=1) must NOT scale (else w default 1 -> 2 breaks bone parity).
			std::string mask = "2.0";
			if (comps < width && width >= 2)
			{
				if (width == 2)
					mask = "float2(2.0, 1.0)";
				else if (width == 3)
					mask = comps == 2 ? "float3(2.0, 2.0, 1.0)" : "float3(2.0, 2.0, 2.0)";
				else
					mask = comps == 2 ? "float4(2.0, 2.0, 1.0, 1.0)"
					                  : "float4(2.0, 2.0, 2.0, 1.0)";
			}
			if (ty == "int2" || ty == "int3" || ty == "int4" || ty == "uint2" || ty == "uint3" ||
			    ty == "uint4")
			{
				// retype field to floatN (accepts the raw-int format, keeps the .5),
				// then cast every use site back to the original integer type.
				const std::string oldf = ty + " " + nm;
				const size_t fp = src.find(oldf, b);
				if (fp == std::string::npos || fp > e)
					continue;
				src.replace(fp, oldf.size(), "float" + ty.substr(ty[0] == 'u' ? 4 : 3) + " " + nm);
				const std::string cast =
				    (ty[0] == 'u' ? "uint" : "int") + ty.substr(ty[0] == 'u' ? 4 : 3);
				const std::string use = "in." + nm;
				const std::string repl = "(" + cast + "(in." + nm + " * " + mask + "))";
				size_t up = v0; // main0 body only (after the struct)
				while ((up = src.find(use, up)) != std::string::npos)
				{
					src.replace(up, use.size(), repl);
					up += repl.size(); // skip past: repl still contains "in.nm"
				}
				changed = true;
			}
			else
				inserts += "in." + nm + " = in." + nm + " * " + mask + ";\n";
			changed = true;
		}
		if (!changed)
			return nil;
		const size_t ob = src.find('{', v0);
		if (ob == std::string::npos)
			return nil;
		if (!inserts.empty())
			src.insert(ob + 1, "\n" + inserts);
		NSError* err = nil;
		id<MTLLibrary> lib = [dev newLibraryWithSource:MtlClipFixApply(
		                                 [NSString stringWithUTF8String:src.c_str()])
		                                      options:nil
		                                        error:&err];
		if (!lib)
		{
			errOut = err ? [[err localizedDescription] UTF8String] : "compile failed";
			return nil;
		}
		return [lib newFunctionWithName:@"main0"];
	}

	// --- sampler descriptors ---------------------------------------------------
	MetalDevice::SamplerDesc MakeSamplerDesc(const mtlState::sSamplerState& S, float globalBias)
	{
		MetalDevice::SamplerDesc d;
		auto addr = [](uint32_t m) -> int {
			switch (m)
			{
			case MTL_D3DTADDRESS_WRAP: return 1;
			case MTL_D3DTADDRESS_BORDER: return 3; // clamp-to-border
			case MTL_D3DTADDRESS_MIRROR: return 2;
			default: return 0; // CLAMP + CLAMPV
			}
		};
		d.addressU = addr(S.AddressU);
		d.addressV = addr(S.AddressV);
		d.addressW = addr(S.AddressW);
		auto filt = [](uint32_t f) -> int { return (f == 2 || f == 3) ? 1 : 0; }; // LINEAR/ANISO -> linear
		d.minFilter = filt(S.Filter & 0x3);
		d.magFilter = filt((S.Filter >> 8) & 0x3);
		d.mipFilter = filt((S.Filter >> 16) & 0x3);
		d.maxAnisotropy = (int)S.MaxAnisotropy ? (int)S.MaxAnisotropy : 1;
		d.lodBias = globalBias; // GL parity: cvar overrides recorded bias
		if (S.MaxMipLevel)
			d.maxLod = (float)S.MaxMipLevel;
		if (S.MinLOD)
			d.minLod = (float)S.MinLOD;
		switch (S.BorderColor)
		{
		case 0x00000000: d.borderColor = 0; break; // opaque black
		default:
			// a==0 -> transparent black; full-white -> opaque white; else black
			if (((S.BorderColor >> 24) & 0xFF) == 0)
				d.borderColor = 2;
			else if ((S.BorderColor & 0x00FFFFFF) == 0x00FFFFFF)
				d.borderColor = 1;
			else
				d.borderColor = 0;
			break;
		}
		if (S.CompareEnable)
		{
			// launch263 hunt: MSL from DX9 tex2Dproj carries NO reference
			// depth (float2 coords, dref dropped by SPIRV-Cross), so Metal's
			// depth-compare sampling compares against a missing value and
			// fails every tap (s=0 => sun output 0). XR_P5_NOCMPSAMP=1 drops
			// the compare to read raw smap depth instead — if sun lands then,
			// the dref path is the culprit.
			static const int s_nocmp = getenv("XR_P5_NOCMPSAMP") ? atoi(getenv("XR_P5_NOCMPSAMP")) : 0;
			if (!s_nocmp)
				d.compareFunc = (int)MtlMapCompare(S.CompareFunc);
		}
		return d;
	}

	MetalDevice::SamplerDesc DefaultSamplerDesc(float globalBias)
	{
		MetalDevice::SamplerDesc d;
		d.addressU = d.addressV = d.addressW = 0; // clamp
		d.minFilter = d.magFilter = d.mipFilter = 1; // linear
		d.lodBias = globalBias;
		return d;
	}
} // namespace

// =============================================================================
// contract implementation
// =============================================================================
void MtlRuntimeAttach(xray::metal::MetalDevice& device, xray::metal::MetalStateCache& pipelines)
{
	MtlPassManager& pm = PM();
	pm.dev = &device;
	pm.cache = &pipelines;
	if (!pm.ring)
		// p6 (debug-layer find): MSL _Globals can be padded PAST the
		// DXBC-derived cb size (SPIRV-Cross rounds trailing vectors), and
		// Metal validates argument LENGTH against the whole buffer — a slot
		// ending within ~1 KB of the 64 MB boundary was silently rejected
		// (vanishing draws; abort under MTL_DEBUG_LAYER). Fixed by the 64 KB
		// allocation slack at NewBuffer below: wrap still happens at
		// kRingSize, so argument overshoot always lands inside the buffer.
		pm.ring = (__bridge id<MTLBuffer>)device.NewBuffer(kRingSize + 65536);
	pm.initBuiltins();
}

void* MtlSharedDevice() { return PM().dev ? PM().dev->Device() : nullptr; }
void* MtlSharedQueue() { return PM().dev ? PM().dev->Queue() : nullptr; }
void* MtlCurrentCommandBuffer() { return PM().cb ? (__bridge void*)PM().cb : nullptr; }
void* MtlArenaRetain(void* obj) { return obj; } // substrate arena covers factory-created objects
void MtlArenaRelease(void*) { }

void* MtlCurrentPassColor0() { return PM().rt[0]; }
void MtlSetLastDrawable(void* tex) { PM().lastDrawable = (__bridge id<MTLTexture>)tex; }
void* MtlLastDrawable() { return PM().lastDrawable ? (__bridge void*)PM().lastDrawable : nullptr; }

// --- frame -------------------------------------------------------------------
void MtlFrameBegin()
{
	MtlPassManager& pm = PM();
	if (!pm.dev || !pm.dev->Queue())
		return;
	pm.endEncoder();
	id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)pm.dev->Queue();
	pm.cb = [q commandBuffer];
	pm.touched.clear();
	// launch302: the CB ring is now MONOTONIC (wrap only on exhaustion at
	// the upload site). Resetting ringOff per frame let frame N+1's CPU
	// writes land on frame N's slots while frame N's CB was still in
	// flight (up to cap CBs) — constant buffers read garbage → transforms
	// clip everything → black world. 64MB / ~2MB per frame = ~30-frame
	// reuse period, far beyond the bounded CB backlog.
	// pm.ringOff = 0;
	++g_mtlStreamFrameGen; // dynamic stream orphaning gen (mtlBufferUtils)
	pm.identityDirty = true;
}

void MtlFrameEnd()
{
	PM().endEncoder();
	// p6 band-hunt: XR_METAL_RTSIZES=1 — periodic census of every RT bound
	// this frame: name + dims. The x=2304 band should match a sub-width
	// surface somewhere in the chain.
	{
		static int s_census = 0;
		if (getenv("XR_METAL_RTSIZES") && (s_census++ % 600) == 0 && PM().dev)
		{
			if (std::vector<void*>* rts = MtlDbgRTs())
			{
				std::set<void*> seen;
				for (void* t : *rts)
				{
					if (!t || !seen.insert(t).second)
						continue;
					uint32_t tw = 0, th = 0;
					PM().dev->TextureDims(t, &tw, &th);
					const char* rn = MtlDbgRTGetName(t);
					Log("- p6 rtsizes: %s %ux%u%s", rn ? rn : "?", tw, th,
					    (tw != PM().dev->Width()) ? "  <-SUBWIDTH" : "");
				}
			}
		}
	}
}

// Block until the current (committed) frame command buffer completes. Used by
// the screenshot path: ReadbackSlice runs on a dedicated CB and would
// otherwise race the frame's uncommitted work.
void MtlWaitCurrentCB()
{
	if (PM().cb)
		[PM().cb waitUntilCompleted];
}

void MtlInvalidatePass()
{
	MtlPassManager& pm = PM();
	pm.endEncoder();
	pm.identityDirty = true;
}

// --- targets -----------------------------------------------------------------
// p5 diag: distinct color RTs bound since the last clear (draw-landing hunt).
static std::vector<void*>* g_mtlDbgRTs = nullptr;

// p5 launch221: dangling-handle guard. The engine recreates every RT on world
// load (menu 3024x1662 → in-game 3024x1658) and releases the old textures into
// the device arena, while MtlPassManager stores NON-RETAINED void* handles.
// ensureEncoder materializes strong id<MTLTexture> (objc_retain) from them —
// launch219/220 font-draw SIGSEGV symbolicated to mtlRuntime.mm:3792 (the
// inlined ensureEncoder). Purge every slot that references a released object.
static void MtlInvalidateReleased(void* obj)
{
	if (!obj)
		return;
	MtlPassManager& pm = PM();
	for (int i = 0; i < 4; i++)
		if (pm.rt[i] == obj)
		{
			pm.rt[i] = nullptr;
			pm.identityDirty = true; // encoder references a dead attachment
		}
	if (pm.zb == obj)
	{
		pm.zb = nullptr;
		pm.identityDirty = true;
	}
	for (uint32_t i = 0; i < kMaxStage; i++)
		if (pm.stageTex[i] == obj)
			pm.stageTex[i] = nullptr;
	if (pm.pendingPostGeom == obj)
		pm.pendingPostGeom = nullptr;
	if (pm.pendingPostGeomAlb == obj)
		pm.pendingPostGeomAlb = nullptr;
	if (pm.pendingAccum == obj)
		pm.pendingAccum = nullptr;
	if (pm.pendingDefferTex == obj)
		pm.pendingDefferTex = nullptr;
	if (pm.pendingMatTex == obj)
		pm.pendingMatTex = nullptr;
	if (pm.pendingSmapTex == obj)
		pm.pendingSmapTex = nullptr;
	if (g_mtlDbgRTs)
		g_mtlDbgRTs->erase(std::remove(g_mtlDbgRTs->begin(), g_mtlDbgRTs->end(), obj),
		                   g_mtlDbgRTs->end());
	g_mtlRtNames.erase(obj);
}

namespace
{
	struct MtlReleaseHookReg
	{
		MtlReleaseHookReg() { xray::metal::g_texReleaseHook = &MtlInvalidateReleased; }
	};
	MtlReleaseHookReg s_relHookReg; // static-init at dylib load
} // namespace

void MtlTargetsChanged(void* const* rts, const void* zb)
{
	MtlPassManager& pm = PM();
	bool same = pm.zb == zb;
	if (same)
		for (int i = 0; i < 4; i++)
			if (pm.rt[i] != (i < 4 && rts ? rts[i] : nullptr))
			{
				same = false;
				break;
			}
	if (same)
		return;
	// p5 DIAG (launch102): stash the position RT of the pass that is about to
	// end (rt[] is overwritten below before the encoder actually closes).
	{
		const char* on0 = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
		if (pm.enc && on0 && strstr(on0, "accum"))
			pm.pendingAccum = pm.rt[0];
		if (pm.enc && on0 && strstr(on0, "position"))
		{
			pm.pendingPostGeom = pm.rt[0];
			// p5 launch188: a clear (endEncoder, no draw) between two stashes
			// means the fetch (next draw) only sees the LAST stash — the alb
			// pair was being clobbered by a later null-alb switch. Keep the
			// albedo pointer across switches until it is consumed.
			// p5 launch227: the gbuffer MRT is (position, normal, albedo) —
			// albedo is rt[2], not rt[1]; scan all slots by name.
			for (int si = 0; si < 4; si++)
				if (pm.rt[si])
				{
					const char* an = MtlDbgRTGetName(pm.rt[si]);
					if (an && strstr(an, "albedo"))
					{
						pm.pendingPostGeomAlb = pm.rt[si];
						break;
					}
				}
			static int s_psN = 0;
			if (g_dbgDrawOK > 60000 && s_psN++ < 40)
				Log("- p5 pstash: alb=%p name=%s rt2=%p", pm.pendingPostGeomAlb,
				    pm.pendingPostGeomAlb ? MtlDbgRTGetName(pm.pendingPostGeomAlb) : "-",
				    pm.rt[2]);
		}
	}
	for (int i = 0; i < 4; i++)
		pm.rt[i] = rts ? rts[i] : nullptr;
	pm.zb = (void*)zb;
	pm.identityDirty = true;
	g_dbgRtSwitches++;

	// p5 diag: ring of distinct color RTs bound this frame (which texture do
	// the draws actually land in?).
	{
		static std::vector<void*> s_rtRing;
		for (int i = 0; i < 4; i++)
		{
			void* t = pm.rt[i];
			if (!t)
				continue;
			if (std::find(s_rtRing.begin(), s_rtRing.end(), t) == s_rtRing.end() && s_rtRing.size() < 32)
				s_rtRing.push_back(t);
		}
		// p5 diag: depth targets are equally suspect (uncleared depth = random
		// tile coverage = the checkerboard we see); scan them too.
		if (pm.zb && std::find(s_rtRing.begin(), s_rtRing.end(), (void*)pm.zb) == s_rtRing.end() &&
		    s_rtRing.size() < 32)
			s_rtRing.push_back((void*)pm.zb);
		g_mtlDbgRTs = &s_rtRing;
	}
}

std::vector<void*>* MtlDbgRTs()
{
	return g_mtlDbgRTs;
}

void MtlDbgClearRTs()
{
	if (g_mtlDbgRTs)
		g_mtlDbgRTs->clear();
}

// p5 diag: RT texture pointer -> creation name ("$user$position" etc.), so the
// periodic content scan can attribute dead render targets to R2 phases.
// (moved above MtlPassManager, launch166.)
void MtlDbgRTName(void* tex, const char* name)
{
	if (tex && name)
		g_mtlRtNames[tex] = name;
}
// p5 launch219: canary draws (white fills into live gbuffer RTs) are now
// contamination + death suspects — opt-in only.
static bool MtlCanaryOn()
{
	static const bool v = !!getenv("XR_METAL_CANARY");
	return v;
}

// p5 launch218: current PS rewrite era (0=black 1=scene 2=gray 3=noc0 4=off,
// 99=no PP seen yet). Stamped onto rtscan bursts so base_0 colors map to the
// postprocess PS variant that produced them.
int g_ppEra = 99;
int MtlPpEra()
{
	return g_ppEra;
}

const char* MtlDbgRTGetName(void* tex)
{
	auto it = g_mtlRtNames.find(tex);
	return it != g_mtlRtNames.end() ? it->second.c_str() : "?";
}

unsigned long long MtlDbgDrawCount()
{
	return g_dbgDrawOK;
}

// p5 diag: per-shader-pair draw histogram (which passes actually draw).
static std::map<std::string, unsigned long long> g_mtlPairDraws;

// p5 diag: top-N per-pair draw histogram dump for the present window.
void MtlDbgDumpPairs()
{
	std::vector<std::pair<unsigned long long, std::string>> v;
	v.reserve(g_mtlPairDraws.size());
	for (const auto& kv : g_mtlPairDraws)
		v.push_back({kv.second, kv.first});
	std::sort(v.rbegin(), v.rend());
	int n = 0;
	for (const auto& kv : v)
	{
		if (n++ >= 15)
			break;
		Log("- p5 pairs: %8llu %s", kv.first, kv.second.c_str());
	}
}

// --- clears ------------------------------------------------------------------
// p5 DIAG (launch103): staged pass bisect on the position Lmap. launch102
// proved a dedicated-CB red clear LANDS (texture fine) while the live geom
// pass loses every write. Re-open the SAME texture under geom-pass-like
// conditions, one feature at a time:
//   A: single-attachment red Clear (reference, expected (0,60,0,0))
//   B: pos+albedo+zb Load/Store pass, no draws  (does red persist?)
//   C: geom layout, color0 Clear GREEN + builtin fullscreen fill params=
//      (1,0.5,0.5,1) → draw survived (0,60,0,63); draw lost (0,0,0,60);
//      pass destroys even the clear => other.
void MtlDbgBisectProbe(void* rt, void* rt2, void* zb)
{
	// p5 launch219: canaries paint into LIVE gbuffer RTs (white position /
	// albedo fills) — legitimate contamination + death suspects now that the
	// scene renders. Off by default; opt back in with XR_METAL_CANARY=1.
	static const bool s_canary = !!getenv("XR_METAL_CANARY");
	if (!s_canary)
		return;
	// Debug-layer runs skip this legacy probe: its synthetic PSO/formats were
	// never declared (verdict closed in launch103) and MTL_DEBUG_LAYER aborts
	// on the mismatch before marsh (launch160).
	static const int s_bisectDbgOff = getenv("MTL_DEBUG_LAYER") ? 1 : 0;
	if (s_bisectDbgOff)
		return;
	MtlPassManager& pm = PM();
	if (!pm.dev || !rt)
		return;
	id<MTLTexture> tex = (__bridge id<MTLTexture>)rt;
	id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)pm.dev->Queue();
	if (!q || !tex)
		return;
	const uint32_t w = (uint32_t)tex.width, h = (uint32_t)tex.height;
	std::vector<uint8_t> px(size_t(w) * h * 4);
	const size_t mid = (size_t(h / 2) * w + w / 2) * 4;
	auto rd = [&](const char* tag) {
		std::string err;
		if (!pm.dev->ReadbackSlice(rt, px.data(), w * 4, w, h, 0, 0, err))
			Log("! p5 bisect %s: readback failed: %s", tag, err.c_str());
		else
			Log("- p5 bisect %s: mid=(%u,%u,%u,%u)", tag, px[mid], px[mid + 1], px[mid + 2],
			    px[mid + 3]);
	};
	// A: reference red clear, single attachment.
	{
		id<MTLCommandBuffer> cb = [q commandBuffer];
		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		rpd.colorAttachments[0].texture = tex;
		rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
		rpd.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
		id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
		[e endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		rd("A_red_single");
	}
	auto geomRpd = [&]() {
		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		rpd.colorAttachments[0].texture = tex;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
		if (rt2)
		{
			rpd.colorAttachments[1].texture = (__bridge id<MTLTexture>)rt2;
			rpd.colorAttachments[1].loadAction = MTLLoadActionLoad;
			rpd.colorAttachments[1].storeAction = MTLStoreActionStore;
		}
		if (zb)
		{
			rpd.depthAttachment.texture = (__bridge id<MTLTexture>)zb;
			rpd.depthAttachment.loadAction = MTLLoadActionLoad;
			rpd.depthAttachment.storeAction = MTLStoreActionStore;
		}
		return rpd;
	};
	// B: geom attachment layout, Load/Store, zero draws.
	{
		id<MTLCommandBuffer> cb = [q commandBuffer];
		MTLRenderPassDescriptor* rpd = geomRpd();
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
		Log("- p5 bisect B: enc=%d rt2=%d zb=%d", e != nil, rt2 != nullptr, zb != nullptr);
		[e endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		rd("B_multi_load");
	}
	// C: geom layout, color0 Clear green + builtin fullscreen fill (yellowish).
	{
		id<MTLCommandBuffer> cb = [q commandBuffer];
		MTLRenderPassDescriptor* rpd = geomRpd();
		rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
		rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
		id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
		bool drew = false;
		bool havePso = false, haveBuf = false;
		if (e)
		{
			const MTLViewport vp{ 0, 0, w, h, 0, 1 };
			[e setViewport:vp];
			id<MTLRenderPipelineState> pso =
				pm.blitPipeline((MTLPixelFormat)tex.pixelFormat, true, false, pm.attDepthFmt);
			havePso = pso != nil;
			if (pso)
			{
				const float params[4] = { 1.0f, 1.0f, 0.5f, 0.0f };
				id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
				id<MTLBuffer> pb = [mdev newBufferWithBytes:params
				                                   length:sizeof(params)
				                                 options:MTLResourceStorageModeShared];
				haveBuf = pb != nil;
				if (pb)
				{
					[e setRenderPipelineState:pso];
					[e setVertexBuffer:pb offset:0 atIndex:0];
					[e setFragmentBuffer:pb offset:0 atIndex:0];
					[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					drew = true;
				}
			}
			Log("- p5 bisect C: enc=1 pso=%d buf=%d drew=%d", havePso, haveBuf, drew);
			[e endEncoding];
		}
		else
			Log("! p5 bisect C: enc=nil");
		[cb commit];
		[cb waitUntilCompleted];
		rd("C_fill_in_pass");
	}
	// D/E/F (launch104): stage C + the exact encoder state applyEncoderState puts
	// on the real geom pass (front=CW, cull=Back, DSS LessEqual+write, stencil
	// Always/REPLACE ref=1). Fill triangle is NDC-CCW; real DX9 geometry (y-down
	// matrices, no VS y-flip) ends up the same framebuffer winding in Metal — if
	// D kills the fill while E (cull off) or F (CCW front) lands, winding-cull
	// is the write-loss root cause for BOTH canaries and all geometry.
	{
		const float params[4] = { 1.0f, 1.0f, 0.5f, 0.0f };
		id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
		id<MTLBuffer> pb = [mdev newBufferWithBytes:params
		                                   length:sizeof(params)
		                                 options:MTLResourceStorageModeShared];
		id<MTLRenderPipelineState> pso =
			pm.blitPipeline((MTLPixelFormat)tex.pixelFormat, true, false, pm.attDepthFmt);
		struct Stage
		{
			MTLWinding win;
			MTLCullMode cull;
			bool dss;
			const char* tag;
		};
		const Stage stages[] = {
			{ MTLWindingClockwise, MTLCullModeBack, true, "D_real_state" },
			{ MTLWindingClockwise, MTLCullModeNone, true, "E_culloff" },
			{ MTLWindingCounterClockwise, MTLCullModeBack, true, "F_ccw" },
		};
		for (const Stage& st : stages)
		{
			if (!pb || !pso)
			{
				Log("! p5 bisect %s: missing pso/buf", st.tag);
				continue;
			}
			id<MTLCommandBuffer> cb = [q commandBuffer];
			MTLRenderPassDescriptor* rpd = geomRpd();
			rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
			id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
			if (e)
			{
				const MTLViewport vp{ 0, 0, w, h, 0, 1 };
				[e setViewport:vp];
				if (st.dss)
				{
					// Mirrors phase_scene_begin: set_Z(TRUE, write, LESS_EQUAL) +
					// set_Stencil(TRUE, ALWAYS, 1, 0xff, 0x7f, KEEP, REPLACE, KEEP).
					DepthStencilDesc ds;
					ds.depthEnable = 1;
					ds.depthFunc = 4; // emulated D3DCMP_LESS_EQUAL
					ds.depthWrite = 1;
					ds.stencilEnable = 1;
					ds.func = 8; // emulated D3DCMP_ALWAYS
					ds.failOp = 1;  // KEEP
					ds.passOp = 3;  // REPLACE
					ds.zFailOp = 1; // KEEP
					ds.readMask = 0xff;
					ds.writeMask = 0x7f;
					id<MTLDepthStencilState> dss =
						(__bridge id<MTLDepthStencilState>)pm.cache->DepthStateFull(pm.dev->Device(), ds);
					if (dss)
						[e setDepthStencilState:dss];
					[e setStencilReferenceValue:1];
				}
				[e setFrontFacingWinding:st.win];
				[e setCullMode:st.cull];
				[e setTriangleFillMode:MTLTriangleFillModeFill];
				[e setRenderPipelineState:pso];
				[e setVertexBuffer:pb offset:0 atIndex:0];
				[e setFragmentBuffer:pb offset:0 atIndex:0];
				[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[e endEncoding];
			}
			[cb commit];
			[cb waitUntilCompleted];
			rd(st.tag);
		}
	}
}

void MtlClearColor(void* rt, float r, float g, float b, float a)
{
	MtlPassManager& pm = PM();
	// p5 DIAG (launch102): clear-order trace for the Lmap trio (bounded).
	if (rt)
	{
		const char* cn = MtlDbgRTGetName(rt);
		if (cn && (strstr(cn, "position") || strstr(cn, "albedo") || strstr(cn, "accum") ||
		          strstr(cn, "base_0")))
		{
			static std::map<std::string, int> s_ccN;
			if (s_ccN[cn]++ < 40)
				Log("- p5 clearcolor: %s (%g,%g,%g,%g) draws=%llu pg=%d", cn, r, g, b, a,
				    (unsigned long long)g_dbgDrawOK, g_pgGate);
		}
	}
	if (!pm.cb || !rt)
		return;
	pm.endEncoder();
	MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
	rpd.colorAttachments[0].texture = (__bridge id<MTLTexture>)rt;
	rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
	id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
	[e endEncoding];
	pm.touched.insert(rt);
	pm.identityDirty = true;
}

void MtlClearDepth(void* zb, float depth, int stencil)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !zb)
		return;
	// p5 DIAG (launch152): depth-surface clear values reaching Metal.
	{
		static int s_zbClearDiag = 0;
		if (s_zbClearDiag < 16)
		{
			Log("- p5 DIAG zbclear: zb=%p d=%.4f st=%d", zb, depth, stencil);
			s_zbClearDiag++;
		}
	}
	pm.endEncoder();
	MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
	id<MTLTexture> tex = (__bridge id<MTLTexture>)zb;
	rpd.depthAttachment.texture = tex;
	rpd.depthAttachment.loadAction = MTLLoadActionClear;
	rpd.depthAttachment.storeAction = MTLStoreActionStore;
	rpd.depthAttachment.clearDepth = depth;
	if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
	{
		rpd.stencilAttachment.texture = tex;
		rpd.stencilAttachment.loadAction = MTLLoadActionClear;
		rpd.stencilAttachment.storeAction = MTLStoreActionStore;
		rpd.stencilAttachment.clearStencil = stencil < 0 ? 0 : (NSUInteger)stencil;
	}
	id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
	[e endEncoding];
	pm.touched.insert(zb);
	pm.identityDirty = true;
}

bool MtlClearColorRect(void* rt, float r, float g, float b, float a, uint32_t numRects, const int32_t* rects)
{
	MtlPassManager& pm = PM();
	// p5 launch189: name the rect-clear culprit if it touches the g-buffer.
	{
		const char* cn = rt ? MtlDbgRTGetName(rt) : nullptr;
		if (cn && (strstr(cn, "position") || strstr(cn, "albedo") || strstr(cn, "accum") ||
		          strstr(cn, "base_0")))
		{
			static int s_crcN = 0;
			if (g_dbgDrawOK > 60000 && s_crcN++ < 24)
				Log("- p9 clearrect: %s (%g,%g,%g,%g) nrect=%u draws=%llu", cn, r, g, b, a,
				    numRects, (unsigned long long)g_dbgDrawOK);
		}
	}
	if (!pm.cb || !rt || !pm.blitVs)
		return false;
	pm.endEncoder();
	const uint32_t fmt = (uint32_t)pm.dev->TextureFormat(rt);
	id<MTLRenderPipelineState> pso = pm.blitPipeline((MTLPixelFormat)fmt, true, false);
	if (!pso)
		return false;
	for (uint32_t i = 0; i < numRects; i++)
	{
		const int32_t l = rects[i * 4 + 0], t = rects[i * 4 + 1], rr = rects[i * 4 + 2], bb = rects[i * 4 + 3];
		if (rr <= l || bb <= t)
			continue;
		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		rpd.colorAttachments[0].texture = (__bridge id<MTLTexture>)rt;
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
		const MTLScissorRect sr{ (NSUInteger)l, (NSUInteger)t, (NSUInteger)(rr - l), (NSUInteger)(bb - t) };
		[e setScissorRect:sr];
		[e setRenderPipelineState:pso];
		[e setCullMode:MTLCullModeNone];
		[e setFrontFacingWinding:MTLWindingClockwise];
		const Float4 params{ 1.f, 1.f, 0.f, 0.f };
		[e setVertexBytes:&params length:sizeof(params) atIndex:0];
		const Float4 color{ r, g, b, a };
		[e setFragmentBytes:&color length:sizeof(color) atIndex:0];
		[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[e endEncoding];
	}
	pm.touched.insert(rt);
	pm.identityDirty = true;
	return true;
}

bool MtlClearDepthRect(void* zb, float depth, uint32_t numRects, const int32_t* rects)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !zb || !pm.blitVs)
		return false;
	pm.endEncoder();
	const uint32_t fmt = (uint32_t)pm.dev->TextureFormat(zb);
	id<MTLRenderPipelineState> pso = pm.blitPipeline((MTLPixelFormat)fmt, true, true);
	if (!pso)
		return false;
	for (uint32_t i = 0; i < numRects; i++)
	{
		const int32_t l = rects[i * 4 + 0], t = rects[i * 4 + 1], rr = rects[i * 4 + 2], bb = rects[i * 4 + 3];
		if (rr <= l || bb <= t)
			continue;
		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		rpd.depthAttachment.texture = (__bridge id<MTLTexture>)zb;
		rpd.depthAttachment.loadAction = MTLLoadActionLoad;
		rpd.depthAttachment.storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
		const MTLScissorRect sr{ (NSUInteger)l, (NSUInteger)t, (NSUInteger)(rr - l), (NSUInteger)(bb - t) };
		[e setScissorRect:sr];
		[e setRenderPipelineState:pso];
		[e setCullMode:MTLCullModeNone];
		[e setFrontFacingWinding:MTLWindingClockwise];
		DepthStencilDesc ds;
		ds.depthEnable = false; // Always
		ds.depthWrite = true;
		id<MTLDepthStencilState> dss =
			(__bridge id<MTLDepthStencilState>)pm.cache->DepthStateFull(pm.dev->Device(), ds);
		[e setDepthStencilState:dss];
		const Float4 params{ 1.f, 1.f, depth, 0.f };
		[e setVertexBytes:&params length:sizeof(params) atIndex:0];
		const Float4 color{ depth, 0, 0, 1 };
		[e setFragmentBytes:&color length:sizeof(color) atIndex:0];
		[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[e endEncoding];
	}
	pm.touched.insert(zb);
	pm.identityDirty = true;
	return true;
}

void MtlBlit(void* srcTex, void* dstTex)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !srcTex || !dstTex)
		return;
	pm.endEncoder();
	pm.dev->BlitTexture((__bridge void*)pm.cb, srcTex, dstTex);
	pm.touched.insert(dstTex);
	pm.identityDirty = true;
}

// p5 launch199: format-converting copy (e.g. RGBA16F rt_Color → BGRA8
// generic0). Blit encoders require identical pixel formats; this uses the
// FS-triangle blit pipeline (like MtlBlitFromBackBuffer) instead.
void MtlBlitConvert(void* srcTex, void* dstTex)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !srcTex || !dstTex)
		return;
	pm.endEncoder();
	id<MTLTexture> src = (__bridge id<MTLTexture>)srcTex;
	id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;
	const uint32_t fmt = (uint32_t)dst.pixelFormat;
	id<MTLRenderPipelineState> pso = pm.blitPipeline((MTLPixelFormat)fmt, false, false);
	if (!pso)
		return;
	MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
	rpd.colorAttachments[0].texture = dst;
	rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
	const uint32_t w = src.width < dst.width ? (uint32_t)src.width : (uint32_t)dst.width;
	const uint32_t h = src.height < dst.height ? (uint32_t)src.height : (uint32_t)dst.height;
	const MTLViewport vp{ 0, 0, w, h, 0, 1 };
	[e setViewport:vp];
	[e setRenderPipelineState:pso];
	[e setCullMode:MTLCullModeNone];
	[e setFrontFacingWinding:MTLWindingClockwise];
	const Float4 params{ 1.f, 1.f, 0.f, 0.f };
	[e setVertexBytes:&params length:sizeof(params) atIndex:0];
	[e setFragmentTexture:src atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	pm.touched.insert(dstTex);
	pm.identityDirty = true;
}

void MtlBlitFromBackBuffer(void* dstTex, uint32_t width, uint32_t height)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !dstTex)
		return;
	id<MTLTexture> src = pm.lastDrawable;
	if (!src)
		return;
	pm.endEncoder();
	id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;
	const uint32_t fmt = (uint32_t)dst.pixelFormat;
	id<MTLRenderPipelineState> pso = pm.blitPipeline((MTLPixelFormat)fmt, false, false);
	if (!pso)
		return;
	MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
	rpd.colorAttachments[0].texture = dst;
	rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
	const MTLViewport vp{ 0, 0, dst.width, dst.height, 0, 1 };
	[e setViewport:vp];
	[e setRenderPipelineState:pso];
	[e setCullMode:MTLCullModeNone];
	[e setFrontFacingWinding:MTLWindingClockwise];
	const Float4 params{ 1.f, 1.f, 0.f, 0.f };
	[e setVertexBytes:&params length:sizeof(params) atIndex:0];
	[e setFragmentTexture:src atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	pm.touched.insert(dstTex);
	pm.identityDirty = true;
	(void)width;
	(void)height;
}

void MtlBlitToDrawable(void* srcTex, void* dstTex, uint32_t srcW, uint32_t srcH, uint32_t dstW, uint32_t dstH)
{
	MtlPassManager& pm = PM();
	if (!pm.cb || !srcTex || !dstTex)
		return;
	pm.endEncoder();
	id<MTLTexture> src = (__bridge id<MTLTexture>)srcTex;
	id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;
	// p6 band-hunt: periodic audit of declared vs ACTUAL texture extents
	// (a mismatch means the present blit lands a sub-rect, top-left).
	{
		static int s_blitDbgN = 0;
		const bool mismatch = src.width != srcW || src.height != srcH || dst.width != dstW ||
		                      dst.height != dstH;
		if (s_blitDbgN < 6 || mismatch || s_blitDbgN % 900 == 0)
			Log("- p6 blitdbg #%d: src actual=%ux%u declared=%ux%u | dst actual=%ux%u declared=%ux%u | fmt %d->%d",
			    s_blitDbgN, (unsigned)src.width, (unsigned)src.height, srcW, srcH,
			    (unsigned)dst.width, (unsigned)dst.height, dstW, dstH,
			    (int)src.pixelFormat, (int)dst.pixelFormat);
		s_blitDbgN++;
	}
	// Fast path: exact size + format -> blit encoder.
	if (srcW == dstW && srcH == dstH && src.pixelFormat == dst.pixelFormat)
	{
		pm.dev->BlitTexture((__bridge void*)pm.cb, srcTex, dstTex);
		return;
	}
	// t4: MetalFX spatial scaler for present-time upscaling (macOS 14+).
	// Fires only when sizes differ (XR_METAL_SCALE < 1); scaler creation is
	// cached per (sizes+formats) and a nil result permanently falls back to
	// the plain FS-triangle path below.
	if (__builtin_available(macOS 14.0, *))
	{
		static std::unordered_map<std::string, id<MTLFXSpatialScaler>> s_scalers;
		std::string skey = std::to_string(srcW) + ":" + std::to_string(srcH) + ":" +
		                   std::to_string(dstW) + ":" + std::to_string(dstH) + ":" +
		                   std::to_string((int)src.pixelFormat) + ":" +
		                   std::to_string((int)dst.pixelFormat);
		auto itS = s_scalers.find(skey);
		if (itS == s_scalers.end())
		{
			MTLFXSpatialScalerDescriptor* d = [[MTLFXSpatialScalerDescriptor alloc] init];
			d.inputWidth = srcW;
			d.inputHeight = srcH;
			d.outputWidth = dstW;
			d.outputHeight = dstH;
			d.colorTextureFormat = src.pixelFormat;
			d.outputTextureFormat = dst.pixelFormat;
			d.colorProcessingMode = src.pixelFormat == MTLPixelFormatRGBA16Float ||
			                                src.pixelFormat == MTLPixelFormatRGBA16Unorm ||
			                                src.pixelFormat == MTLPixelFormatRGB9E5Float ||
			                                src.pixelFormat == MTLPixelFormatBGRA10_XR
			                            ? MTLFXSpatialScalerColorProcessingModeLinear
			                            : MTLFXSpatialScalerColorProcessingModePerceptual;
			id<MTLFXSpatialScaler> sc = [d newSpatialScalerWithDevice:(__bridge id<MTLDevice>)pm.dev->Device()];
			Log("- xrRenderMetal: MetalFX spatial scaler %ux%u->%ux%u fmt %d->%d: %s", srcW, srcH,
			    dstW, dstH, (int)src.pixelFormat, (int)dst.pixelFormat, sc ? "ready" : "nil");
			itS = s_scalers.emplace(std::move(skey), sc).first;
		}
		if (itS->second)
		{
			itS->second.colorTexture = src;
			itS->second.outputTexture = dst;
			[itS->second encodeToCommandBuffer:pm.cb];
			return;
		}
	}
	id<MTLRenderPipelineState> pso = pm.blitPipeline(dst.pixelFormat, false, false);
	if (!pso)
		return;
	MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
	rpd.colorAttachments[0].texture = dst;
	rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [pm.cb renderCommandEncoderWithDescriptor:rpd];
	const MTLViewport vp{ 0, 0, dstW, dstH, 0, 1 };
	[e setViewport:vp];
	[e setRenderPipelineState:pso];
	[e setCullMode:MTLCullModeNone];
	[e setFrontFacingWinding:MTLWindingClockwise];
	const Float4 params{ 1.f, 1.f, 0.f, 0.f };
	[e setVertexBytes:&params length:sizeof(params) atIndex:0];
	[e setFragmentTexture:src atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	(void)srcW;
	(void)srcH;
}

// --- viewport / scissor --------------------------------------------------------
// p6 band-hunt: the engine can drive SetViewport/SetScissor straight to the
// live encoder, bypassing applyEncoderState's rectdbg. Log every UNIQUE rect
// applied while a screen-sized RT is bound, tagged with the pass name.
static void mtlRectBypassLog(MtlPassManager& pm, const char* kind)
{
	static const bool s_rben = !!getenv("XR_METAL_RECTBYPASS");
	if (!s_rben || !pm.rt[0] || !pm.dev)
		return;
	uint32_t rw = 0, rh = 0;
	pm.dev->TextureDims(pm.rt[0], &rw, &rh);
	if (rw < 1600 || rh < 800)
		return;
	char sig[160];
	snprintf(sig, sizeof sig, "%s|%.0f|%.0f|%.0f|%.0f|%d|%d|%d|%d|%d", kind, pm.vpX, pm.vpY,
	         pm.vpW, pm.vpH, (int)pm.scissorEn, pm.scL, pm.scT, pm.scR, pm.scB);
	static std::set<std::string> s_seen;
	if (s_seen.size() < 64 && s_seen.insert(sig).second)
	{
		const char* rn = MtlDbgRTGetName(pm.rt[0]);
		Log("- p6 rectbp: %s rt=%s %ux%u vp=(%.0f,%.0f,%.0fx%.0f) sc=%d(%d,%d,%d,%d)", kind,
		    rn ? rn : "?", rw, rh, pm.vpX, pm.vpY, pm.vpW, pm.vpH, (int)pm.scissorEn, pm.scL,
		    pm.scT, pm.scR, pm.scB);
	}
}

void MtlSetViewport(float x, float y, float w, float h, float minD, float maxD)
{
	MtlPassManager& pm = PM();
	pm.vpX = x;
	pm.vpY = y;
	pm.vpW = w;
	pm.vpH = h;
	pm.vpMin = minD;
	pm.vpMax = maxD;
	if (w > pm.screenW)
		pm.screenW = w; // p5 launch196: screen_res fallback source
	if (h > pm.screenH)
		pm.screenH = h;
	if (pm.enc)
	{
		const MTLViewport vp{ x, y, w, h, minD, maxD };
		[pm.enc setViewport:vp];
	}
	mtlRectBypassLog(pm, "vp");
}

void MtlSetScissor(bool enabled, int32_t l, int32_t t, int32_t r, int32_t b)
{
	MtlPassManager& pm = PM();
	pm.scissorEn = enabled;
	pm.scL = l;
	pm.scT = t;
	pm.scR = r;
	pm.scB = b;
	if (pm.enc)
	{
		if (enabled)
		{
			const MTLScissorRect rect{ (NSUInteger)l, (NSUInteger)t, (NSUInteger)(r - l), (NSUInteger)(b - t) };
			[pm.enc setScissorRect:rect];
		}
		else
		{
			const MTLScissorRect full{ 0, 0, (NSUInteger)std::max(pm.vpW, 1.0), (NSUInteger)std::max(pm.vpH, 1.0) };
			[pm.enc setScissorRect:full];
		}
	}
	mtlRectBypassLog(pm, "sc");
}

// --- state ---------------------------------------------------------------------
void MtlSetGlobalMipBias(float bias) { PM().globalBias = bias; }

void MtlApplyRecordedState(const mtlState* state)
{
	MtlPassManager& pm = PM();
	if (!state)
		return;
	const auto& ds = state->DepthStencil();
	pm.depthEn = ds.DepthEnable != 0;
	pm.depthFunc = (int)ds.DepthFunc;
	pm.depthWrite = ds.DepthWriteMask != 0;
	pm.stencilEn = ds.StencilEnable != 0;
	pm.stMask = ds.StencilMask;
	pm.stWMask = ds.StencilWriteMask;
	pm.stFail = (int)ds.StencilFailOp;
	pm.stPass = (int)ds.StencilPassOp;
	pm.stZFail = (int)ds.StencilDepthFailOp;
	pm.stFunc = (int)ds.StencilFunc;
	pm.stRef = ds.StencilRef;
	const auto& bs = state->Blend();
	pm.blend.enabled = bs.BlendEnable != 0;
	pm.blend.src = (int)bs.SrcBlend;
	pm.blend.dst = (int)bs.DestBlend;
	pm.blend.op = (int)bs.BlendOp;
	pm.blend.srcA = (int)bs.SrcBlendAlpha;
	pm.blend.dstA = (int)bs.DestBlendAlpha;
	pm.blend.opA = (int)bs.BlendOpAlpha;
	pm.blend.writeMask = bs.ColorMask & 0xF;
	pm.cull = (int)state->Cull();
	pm.recorded = state;
	if (pm.enc)
		pm.applyEncoderState();
}

void MtlSetCull(uint32_t d3dCullMode)
{
	MtlPassManager& pm = PM();
	pm.cull = (int)d3dCullMode;
	if (pm.enc)
		[pm.enc setCullMode:(MTLCullMode)MtlMapCull(pm.cull)];
}

void MtlSetDepth(uint32_t enable, uint32_t func, uint32_t writeMask)
{
	MtlPassManager& pm = PM();
	pm.depthEn = enable != 0;
	pm.depthFunc = (int)func;
	if (writeMask != 0xFFFFFFFFu)
		pm.depthWrite = writeMask != 0;
	if (pm.enc)
		pm.applyEncoderState();
}

void MtlSetStencil(uint32_t enable, uint32_t func, uint32_t ref, uint32_t mask, uint32_t writeMask,
                   uint32_t fail, uint32_t pass, uint32_t zfail)
{
	MtlPassManager& pm = PM();
	pm.stencilEn = enable != 0;
	pm.stFunc = (int)func;
	pm.stRef = ref;
	pm.stMask = mask;
	pm.stWMask = writeMask;
	pm.stFail = (int)fail;
	pm.stPass = (int)pass;
	pm.stZFail = (int)zfail;
	if (pm.enc)
		pm.applyEncoderState();
}

void MtlSetBlend(uint32_t enable, uint32_t src, uint32_t dst, uint32_t srcAlpha, uint32_t dstAlpha,
                 uint32_t op, uint32_t opAlpha, uint32_t colorMask)
{
	MtlPassManager& pm = PM();
	if (enable == 0xFFFFFFFFu)
		pm.blend.writeMask = colorMask & 0xF; // color-write-only update
	else
	{
		pm.blend.enabled = enable != 0;
		pm.blend.src = (int)src;
		pm.blend.dst = (int)dst;
		pm.blend.op = (int)op;
		pm.blend.srcA = (int)srcAlpha;
		pm.blend.dstA = (int)dstAlpha;
		pm.blend.opA = (int)opAlpha;
		pm.blend.writeMask = colorMask & 0xF;
	}
	// blend lives in the PSO; next draw re-resolves it through the cache.
}

void MtlSetFillMode(uint32_t mode)
{
	MtlPassManager& pm = PM();
	pm.fill = (int)mode;
	if (pm.enc)
		[pm.enc setTriangleFillMode:(MTLTriangleFillMode)MtlMapFillMode(pm.fill)];
}

void MtlSetAlphaRef(uint32_t) { } // shader-side clip (DX9->SM6 shim)

// --- constants -------------------------------------------------------------------
void MtlConstBegin(uint32_t vsSize, uint32_t psSize)
{
	MtlPassManager& pm = PM();
	pm.vsSize = vsSize;
	pm.psSize = psSize;
	pm.psBase = Align16(vsSize);
	const size_t total = pm.psBase + Align16(psSize);
	if (pm.staging.size() != total)
		pm.staging.assign(total, 0);
	else
		std::memset(pm.staging.data(), 0, total);
	// p5 diag: every staging wipe deep in marsh (finds unexpected re-wipes
	// between xform reemit and the draw that reads the matrices back).
	static int s_cbLogged = 0;
	if (g_dbgDrawOK > 500000 && s_cbLogged < 24)
	{
		s_cbLogged++;
		Log("* p5 constbegin#%d: vsSize=%u psSize=%u draws=%llu", s_cbLogged, vsSize, psSize,
		    (unsigned long long)g_dbgDrawOK);
	}
}

void MtlConstWrite(uint32_t stage, uint32_t offset, uint32_t size, const void* data, uint32_t bytes)
{
	MtlPassManager& pm = PM();
	uint32_t base;
	switch (stage)
	{
	case 0: base = 0; break; // vs
	case 1: base = pm.psBase; break; // ps
	case 3: // pp: write both images
		if (offset + bytes <= pm.staging.size())
		{
			std::memcpy(pm.staging.data() + offset, data, bytes);
			base = pm.psBase;
			offset = 0;
		}
		else
			return;
		break;
	default: return; // gs unused on Metal
	}
	if (base + offset + bytes <= pm.staging.size())
		std::memcpy(pm.staging.data() + base + offset, data, bytes);
	else
	{
		// p5 launch230: the silent truncation killer — m_shadow@976+64 needs
		// 1040 but DXBC cbSize says 1024; the whole write used to vanish.
		static int s_cbDrop = 0;
		if (s_cbDrop++ < 32)
			Log("! p5 cbdrop: stage=%u off=%u bytes=%u sz=%u staging=%zu base=%u draws=%llu",
			    stage, offset, bytes, size, pm.staging.size(), base,
			    (unsigned long long)g_dbgDrawOK);
	}
	(void)size;
}

// --- texture stages ---------------------------------------------------------------
void MtlRecordTextureStage(uint32_t stage, void* texture)
{
	// p5 launch203: who writes stage 0? (PP s_base0 stale-albedo hunt)
	if (stage == 0)
	{
		const char* n0 = texture ? MtlDbgRTGetName(texture) : nullptr;
		std::string key = texture
		    ? std::string(n0 ? n0 : "unnamed") + "@" + std::to_string((size_t)(uintptr_t)texture % 1048576)
		    : std::string("null");
		static std::map<std::string, int> s_s0;
		if (s_s0[key]++ < 6)
			Log("* p5 s0rec: %s (%s)", key.c_str(), texture ? "tex" : "NULL");
	}
	if (stage < kMaxStage)
		PM().stageTex[stage] = texture;
}

void MtlClearTextureStages()
{
	std::memset(PM().stageTex, 0, sizeof(PM().stageTex));
}

// --- vertex layout -----------------------------------------------------------------
void MtlSetVertexLayout(const void* elements, uint32_t count)
{
	MtlPassManager& pm = PM();
	pm.declElems = (const D3DVERTEXELEMENT9*)elements;
	pm.declCount = count;
}

// --- draws --------------------------------------------------------------------------
namespace
{
	// Resolve the PSO for a draw: pair + layout + pass formats + blend.

	// RC#5: PSO depth/stencil formats MUST match the live encoder's actual
	// rpd attachment — pm.rt[]/pm.zb can diverge from a stale encoder when
	// the engine switches RT/depth mid-pass; PSOs built from the registry
	// then mismatch the framebuffer and Metal SILENTLY DISCARDS EVERY DRAW
	// (launch111 debug-layer assert: pipeline stencil Invalid vs D32S8
	// framebuffer). Combined Depth32Float_Stencil8 needs BOTH formats set.
	static void MtlPdDepthFromEncoder(MtlPassManager& pm, PipelineDesc& pd)
	{
		int zf = pm.enc ? pm.attDepthFmt : 0;
		if (!zf && pm.zb)
			zf = pm.dev->TextureFormat(pm.zb);
		if (!zf)
			return;
		pd.depthFormat = zf;
		// REAL Metal enums (verified on this runtime): Depth32Float=252,
		// Stencil8=253, Depth32Float_Stencil8=260. The combined format is
		// 260 — NOT 253 (stale-note bug that kept stencil undeclared).
		if (zf == (int)MTLPixelFormatDepth32Float_Stencil8)
			pd.stencilFormat = zf;
	}

	id<MTLRenderPipelineState> ResolvePipeline(MtlPassManager& pm, const MtlStageRefl& vsRefl,
	                                          const MtlStageRefl& psRefl, uint32_t stride,
	                                          const MtlShaderPair* pairName)
	{
		PipelineDesc pd;
		pd.vs = vsRefl.function;
		pd.ps = psRefl.function;
		pd.depthOnly = pairName && pairName->depthOnly && !psRefl.function;
		pd.stride = stride;
		pd.vbSlot = 1; // cbuffer image occupies buffer(0)

		// Vertex attributes: VS inputs (declaration order == attribute order)
		// matched against the DX9 decl.
		DeclCursor cur{ pm.declElems, pm.declCount, {} };
		for (uint32_t i = 0; i < 16; i++)
			cur.next[i] = 0;
		bool unmatchedAny = false;
		int lastMatch = -1;
		std::string lastSem;
		for (const auto& in : vsRefl.inputs)
		{
			uint32_t usage = 0, index = 0;
			ParseSemantic(in.semantic, usage, index);
			int e = -1;
			if (in.isMatrixRow && !vsRefl.inputs.empty() && in.semantic == lastSem && lastMatch >= 0)
			{
				// matrix row: consecutive decl element (same usage, next slot)
				if ((uint32_t)(lastMatch + 1) < pm.declCount)
					e = lastMatch + 1;
			}
			else
				e = cur.find(usage, index);
			if (e < 0)
			{
				unmatchedAny = true;
				continue;
			}
			lastMatch = e;
			lastSem = in.semantic;
			VertexAttr a;
			a.index = in.attribute;
			a.offset = pm.declElems[e].Offset;
			a.format = MapDeclFormat(pm.declElems[e].Type);
			pd.attrs.push_back(a);
		}
		if (unmatchedAny && pm.declElems && pm.declCount)
		{
			// DX9 tolerated shader inputs missing from the geometry decl (GL
			// left the slot unbound). Bind them to the first element so the
			// PSO validates; values are garbage, same as GL.
			for (const auto& in : vsRefl.inputs)
			{
				bool found = false;
				for (const auto& a : pd.attrs)
					if (a.index == in.attribute)
					{
						found = true;
						break;
					}
				if (!found)
				{
					VertexAttr a;
					a.index = in.attribute;
					a.offset = pm.declElems[0].Offset;
					a.format = MapDeclFormat(pm.declElems[0].Type);
					pd.attrs.push_back(a);
				}
			}
		}

		// p5 launch217: PP-draw vertex layout dump — NaN hunt (COLOR0/1
		// read as float32 would reinterpret 0xFF7F7F7F as NaN bits).
		if (pairName && strstr(pairName->name.c_str(), "postprocess"))
		{
			static int s_vlN = 0;
			if (s_vlN++ < 3)
			{
				std::string vsi, dl, at;
				for (const auto& in : vsRefl.inputs)
					vsi += in.semantic + "@" + std::to_string(in.attribute) + " ";
				for (uint32_t i = 0; i < pm.declCount && i < 8; i++)
					dl += std::to_string(pm.declElems[i].Usage) + ":" +
					      std::to_string(pm.declElems[i].UsageIndex) + ":t" +
					      std::to_string(pm.declElems[i].Type) + ":o" +
					      std::to_string(pm.declElems[i].Offset) + " ";
				for (const auto& a : pd.attrs)
					at += "loc" + std::to_string(a.index) + "/o" + std::to_string(a.offset) +
					      "/f" + std::to_string((int)a.format) + " ";
				Log("* p5 ppVL: stride=%u vsin=[%s] decl=[%s] attrs=[%s]", stride, vsi.c_str(),
				    dl.c_str(), at.c_str());
			}
		}

		// launch129: GL-parity — raw-int packed attrs (SHORT2/SHORT4/UBYTE4)
		// deliver raw*0.5 to float VS inputs on Metal but RAW on GL/D3D9
		// (vfprobe.m + glBufferUtils GL_SHORT/GL_FALSE). Resolve to a compiled
		// VS variant whose affected inputs are x2-corrected (mask preserves
		// D3D9 pad defaults). Compiled once per (VS, attr-formats) signature.
		{
			static std::map<std::string, id<MTLFunction>> s_rix;
			bool anyRaw = false;
			for (const auto& a : pd.attrs)
				if (MtlFmtRawInt(a.format))
					anyRaw = true;
			if (anyRaw && vsRefl.function && !vsRefl.msl.empty())
			{
				std::string key = vsRefl.name;
				for (const auto& a : pd.attrs)
				{
					key += ";";
					key += std::to_string(a.index);
					key += ":";
					key += std::to_string(a.format);
				}
				const auto itR = s_rix.find(key);
				if (itR == s_rix.end())
				{
					std::string errR;
					id<MTLFunction> fR =
					    MtlRawIntScaledVS((__bridge id<MTLDevice>)pm.dev->Device(), vsRefl.msl,
					                      pd.attrs, errR);
					s_rix[key] = fR; // cache nil too: never retry a failed patch
					if (fR)
						Log("- xrRenderMetal: raw-int x2 VS variant for %s", vsRefl.name.c_str());
					else if (!errR.empty())
						Log("! xrRenderMetal: raw-int x2 patch failed %s: %s", vsRefl.name.c_str(),
						    errR.c_str());
				}
				if (s_rix[key])
					pd.vs = (__bridge void*)s_rix[key];
			}
		}

		// Pass attachment formats — RC#5: read the LIVE encoder's rpd
		// snapshot so the PSO always matches the framebuffer its draws land
		// in (registry divergence from stale encoders silently discarded
		// every draw).
		if (pm.enc)
		{
			for (int i = 0; i < pm.attColorCount && i < 4; i++)
				pd.colorFormats.push_back(pm.attColorFmt[i]);
		}
		else
		{
			for (int i = 0; i < 4; i++)
				if (pm.rt[i])
					pd.colorFormats.push_back(pm.dev->TextureFormat(pm.rt[i]));
		}
		if (pd.colorFormats.empty())
			pd.colorFormat = -1; // depth-only pass
		MtlPdDepthFromEncoder(pm, pd);
		pd.blend = pm.blend;

		// A draw without geometry (stride 0) aborts Metal's descriptor
		// validation hard (no NSError) — skip such draws like null-shader
		// ones instead. (GL silently ignored them; caller audit in t3.)
		if (stride == 0)
		{
			static int s_s0_logged = 0;
			if (s_s0_logged++ < 6)
				Log("! xrRenderMetal: draw skipped (stride 0, no geometry): vs=%s ps=%s",
				    vsRefl.name.c_str(), psRefl.name.c_str());
			return nil;
		}

		// p5 diag: dump the PSO descriptor for the first resolves — when a
		// Metal validation ABORT kills the process, the last line names the
		// exact failing pipeline (no NSError survives the abort).
		{
			static int s_pd_logged = 0;
			static std::set<std::string> s_pd_seen;
			const std::string key = vsRefl.name + "|" + psRefl.name;
			if (s_pd_seen.insert(key).second && s_pd_logged++ < 150)
			{
				std::string attrDump;
				for (const auto& a : pd.attrs)
					attrDump += std::to_string(a.index) + ":" + std::to_string(a.format) + "@" +
					            std::to_string(a.offset) + " ";
				std::string cf;
				for (int f : pd.colorFormats)
					cf += std::to_string(f) + ",";
				std::string ins;
				for (const auto& in : vsRefl.inputs)
					ins += in.semantic + "#" + std::to_string(in.attribute) + " ";
				Log("- p5 pso#%d: vs=%s ps=%s stride=%u attrs=[%s] cf=[%s] df=%d sf=%d vsIn=[%s]",
				    s_pd_logged, vsRefl.name.c_str(), psRefl.name.c_str(), stride, attrDump.c_str(),
				    cf.c_str(), pd.depthFormat, pd.stencilFormat, ins.c_str());
			}
		}

		std::string error;
		id<MTLRenderPipelineState> pso =
			(__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(pm.dev->Device(), pd, error);
		if (!pso)
		{
			static std::set<std::string> s_failedLogged;
			if (s_failedLogged.size() < 64 &&
			    s_failedLogged.insert(vsRefl.name + "|" + psRefl.name).second)
				Log("! xrRenderMetal: PSO failed (vs=%s ps=%s): %s", vsRefl.name.c_str(),
				    psRefl.name.c_str(), error.c_str());
		}
		return pso;
	}

	// Bind cbuffer snapshot + stage resources for both stages.
	// launch117 (t5 sky fix): declared texture kinds per slot, parsed from the
	// stage MSL signature ("texturecube<float> s_sky0 [[texture(0)]]"). Metal
	// DISCARDS any draw whose bound texture type differs from the declared
	// one (debug-layer assert "incorrect type of texture ... expect Cube");
	// the engine's built-in 2D default lands on cube slots for sky shaders,
	// silently killing every sky draw in release. Substitute type-matched
	// 1x1 dummies on mismatch so the draw survives (GL parity: GL drew with
	// undefined sampling instead of discarding).
	enum MtlTexKind { kTex2D = 0, kTexCube, kTex1D, kTex2DArray, kTex3D };
	static std::array<uint8_t, 8> ParseMslTexKinds(const MtlStageRefl& refl)
	{
		static std::map<const void*, std::array<uint8_t, 8>> s_cache;
		const auto it = s_cache.find(refl.function);
		if (it != s_cache.end())
			return it->second;
		std::array<uint8_t, 8> kinds{}; // zero-init: all 2D
		const std::string& m = refl.msl;
		size_t i = 0;
		while ((i = m.find("texture", i)) != std::string::npos)
		{
			if (i > 0 && (isalnum(m[i - 1]) || m[i - 1] == '_'))
			{
				i += 7;
				continue;
			}
			uint8_t kind = kTex2D;
			size_t j = i + 7;
			if (m.compare(j, 4, "cube") == 0)
			{
				kind = kTexCube;
				j += 4;
				if (m.compare(j, 6, "_array") == 0)
					kind = kTex2DArray; // cubearray rare; array fallback matches better
			}
			else if (m.compare(j, 2, "1d") == 0)
			{
				kind = kTex1D;
				j += 2;
			}
			else if (m.compare(j, 2, "2d") == 0)
			{
				kind = kTex2D;
				j += 2;
				if (m.compare(j, 6, "_array") == 0)
					kind = kTex2DArray;
			}
			else if (m.compare(j, 2, "3d") == 0)
			{
				kind = kTex3D;
				j += 2;
			}
			else
			{
				i += 7;
				continue; // "texture" not a type token (e.g. in a comment)
			}
			const size_t tb = m.find("[[texture(", j);
			if (tb != std::string::npos && tb - j < 160)
			{
				int slot = 0;
				size_t d = tb + 10;
				while (d < m.size() && isdigit(m[d]))
					slot = slot * 10 + (m[d++] - '0');
				if (slot < 8)
					kinds[slot] = kind;
				i = d;
			}
			else
				i = j;
		}
		s_cache[refl.function] = kinds;
		return kinds;
	}

	static id<MTLTexture> MtlKindDummy(id<MTLDevice> dev, uint8_t kind)
	{
		static id<MTLTexture> s_dummy[5] = { nil, nil, nil, nil, nil };
		if (kind >= 5)
			return nil;
		if (s_dummy[kind])
			return s_dummy[kind];
		MTLTextureDescriptor* td = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			                             width:1
			                            height:1
			                         mipmapped:NO];
		switch (kind)
		{
		case kTexCube: td.textureType = MTLTextureTypeCube; break;
		case kTex1D: td.textureType = MTLTextureType1D; break;
		case kTex2DArray: td.textureType = MTLTextureType2DArray; td.arrayLength = 1; break;
		case kTex3D:
			td.textureType = MTLTextureType3D;
			td.depth = 1;
			break;
		default: break;
		}
		s_dummy[kind] = [dev newTextureWithDescriptor:td]; // Metal zero-fills
		return s_dummy[kind];
	}

	void BindDraw(MtlPassManager& pm, id<MTLRenderCommandEncoder> e, const MtlStageRefl& vsRefl,
	              const MtlStageRefl& psRefl, uint64_t slotOff)
	{
		if (pm.ring)
		{
			[e setVertexBuffer:pm.ring offset:slotOff atIndex:0];
			// p5 launch223: the PS must read its OWN region of the ring slot.
			// Real pairs only worked by accident: DXC emits the same full
			// type_Globals layout for both stages, so reading the VS copy at
			// slotOff aliased identical offsets. The synthesized ffp VS declares
			// just screen_res (16B) → the PP PS read every constant shifted
			// −16B; c_brightness@960 landed on J_spot[5] garbage → NaN →
			// solid-yellow screen (launch196-222 chase).
			[e setFragmentBuffer:pm.ring offset:slotOff + pm.psBase atIndex:0];
		}
		auto bindStage = [&](bool fragment, const MtlStageRefl& refl) {
			const std::array<uint8_t, 8> kinds = ParseMslTexKinds(refl);
			for (const auto& r : refl.resources)
			{
				if (r.isSamplerOnly)
					continue;
				const uint32_t slot = r.textureSlot;
				void* tex = slot < kMaxStage ? pm.stageTex[slot] : nullptr;
				if (tex)
				{
					id<MTLTexture> t = (__bridge id<MTLTexture>)tex;
					// p5 launch191: same-target sample → pre-pass scratch copy.
					if (fragment)
					{
						auto fit = pm.fbRemap.find((__bridge void*)t);
						if (fit != pm.fbRemap.end())
							t = (__bridge id<MTLTexture>)fit->second;
						// p5 launch193: the luminance-adaptation chain feeds
						// combine_1's tonemap multiplier (tm_scale). Its source
						// (bloom1<-generic1 threshold) is legitimately black at
						// night with stubbed sun, so adaptation sits at 0 and
						// multiplies the entire scene to black. Until the
						// luminance chain gets real inputs (t5), sample 1.0
						// instead: tm_scale = neutral.
						auto nit = g_mtlRtNames.find((__bridge void*)t);
						if (nit != g_mtlRtNames.end() &&
						    (strstr(nit->second.c_str(), "luminance_cur") ||
						     strstr(nit->second.c_str(), "luminance_src")))
						{
							static id<MTLTexture> s_tmWhite = nil;
							if (!s_tmWhite)
							{
								MTLTextureDescriptor* td = [MTLTextureDescriptor
								    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
																 width:1
																height:1
															 mipmapped:NO];
								td.usage = MTLTextureUsageShaderRead;
								s_tmWhite = [(__bridge id<MTLDevice>)pm.dev->Device()
								    newTextureWithDescriptor:td];
								const float one[4] = { 1.f, 1.f, 1.f, 1.f };
								[s_tmWhite replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
											   mipmapLevel:0
												 withBytes:one
											   bytesPerRow:16];
							}
							if (s_tmWhite)
								t = s_tmWhite;
						}
					}
					const uint8_t kind = slot < 8 ? kinds[slot] : kTex2D;
					bool mismatch = false;
					switch (kind)
					{
					case kTexCube: mismatch = t.textureType != MTLTextureTypeCube; break;
					case kTex1D: mismatch = t.textureType != MTLTextureType1D; break;
					case kTex2DArray: mismatch = t.textureType != MTLTextureType2DArray; break;
					case kTex3D: mismatch = t.textureType != MTLTextureType3D; break;
					default: mismatch = t.textureType == MTLTextureTypeCube ||
					                 t.textureType == MTLTextureType1D ||
					                 t.textureType == MTLTextureType2DArray;
					}
					if (mismatch)
					{
						id<MTLTexture> d = MtlKindDummy((__bridge id<MTLDevice>)pm.dev->Device(),
						                                kind);
						if (d)
							t = d;
					}
					if (fragment)
						[e setFragmentTexture:t atIndex:slot];
					else
						[e setVertexTexture:t atIndex:slot];
				}
				else if (fragment)
				{
					// p5 launch196: Metal drops the ENTIRE draw when a PS
					// sample slot is unbound (combine_1's s_normal on a gbuffer
					// variant with no normal RT) — silently, no error without
					// the debug layer. Bind the zero-filled kind dummy so the
					// draw survives; the missing input reads black.
					id<MTLTexture> d = MtlKindDummy((__bridge id<MTLDevice>)pm.dev->Device(),
					                                slot < 8 ? kinds[slot] : kTex2D);
					if (d)
						[e setFragmentTexture:d atIndex:slot];
				}
				uint32_t ss = r.samplerSlot;
				if (ss == UINT32_MAX)
					ss = slot; // translator mirrors sampler to the texture slot
				if (ss >= kMaxStage)
					ss = 0;
				// Sampler state: recorded per-stage state if the last applied
				// mtlState has it, else the linear-clamp default.
				const MetalDevice::SamplerDesc* sd = nullptr;
				MetalDevice::SamplerDesc desc;
				if (pm.recorded)
				{
					const auto& sst = pm.recorded->SamplerState(ss);
					if (sst.valid)
					{
						desc = MakeSamplerDesc(sst, pm.globalBias);
						sd = &desc;
					}
				}
				if (!sd)
				{
					desc = DefaultSamplerDesc(pm.globalBias);
					sd = &desc;
				}
				id<MTLSamplerState> samp =
					(__bridge id<MTLSamplerState>)pm.dev->SamplerFull(*sd);
				if (samp)
				{
					if (fragment)
						[e setFragmentSamplerState:samp atIndex:ss];
					else
						[e setVertexSamplerState:samp atIndex:ss];
				}
			}
		};
		bindStage(false, vsRefl);
		bindStage(true, psRefl);
	}

	bool EmitDraw(MtlPassManager& pm, MtlDrawState ds, uint32_t topology, uint32_t primCount,
	              uint32_t startI, uint32_t baseV, uint32_t startV, bool indexed)
	{
		g_dbgDrawEnter++;
		// launch302: vb/ib may be a dynamic stream's BASE handle (baked into
		// geom records at startup); resolve to the slot this frame's Lock()
		// wrote. Static/staging buffers pass through untouched.
		ds.vb = MtlStreamBufferCurrent(ds.vb);
		ds.ib = MtlStreamBufferCurrent(ds.ib);
		if (topology < 8)
			g_dbgTopoEnter[topology]++;
		if (!pm.dev || !pm.cb)
		{
			g_dbgDrawNoCb++;
			return false;
		}
		// Resolve shader pair
		const MtlStageRefl* vsR = nullptr;
		const MtlStageRefl* psR = nullptr;
		const MtlShaderPair* pair = (const MtlShaderPair*)ds.pp;
		if (pair)
		{
			vsR = &pair->vs;
			psR = &pair->ps;
		}
		else
		{
			vsR = (const MtlStageRefl*)ds.vs;
			psR = (const MtlStageRefl*)ds.ps;
		}
		// p6 band-hunt: XR_METAL_STOPAFTER=<substr> halts all further draws
		// within a frame once a matching shader pair has been emitted
		// (paint-order bisection). Re-arms each frame (new command buffer).
		{
			static const char* s_stop = getenv("XR_METAL_STOPAFTER");
			static bool s_stopped = false;
			static const void* s_stopCb = nullptr;
			if (s_stop)
			{
				if ((__bridge const void*)pm.cb != s_stopCb)
				{
					s_stopCb = (__bridge const void*)pm.cb;
					s_stopped = false;
				}
				if (s_stopped)
					return true;
				const char* nm = pair ? pair->name.c_str() : (psR ? psR->name.c_str() : "");
				if (nm && strstr(nm, s_stop))
				{
					s_stopped = true;
					static int s_saN = 0;
					if (s_saN++ < 3)
						Log("- p6 stopafter: halted frame draws after pair '%s'", nm);
				}
			}
		}
		if (!vsR || !psR || !vsR->function || (!psR->function && !(pair && pair->depthOnly)))
		{
			g_dbgDrawNoShader++;
			static int s_ns_logged = 0;
			if (s_ns_logged++ < 12)
				Log("! xrRenderMetal: draw skipped (null shader): vs=%s ps=%s",
				    vsR ? vsR->name.c_str() : (pair ? pair->name.c_str() : "?"),
				    psR ? psR->name.c_str() : (pair ? pair->name.c_str() : "?"));
			return false;
		}
		// p5 launch215: is the pipeline's PS really postprocess? BEFORE the
		// killswitch (which returns early and hid this probe in 214).
		if (pair && strstr(pair->name.c_str(), "postprocess"))
		{
			static int s_ppPso = 0;
			if (s_ppPso++ < 6)
			{
				const void* psf = psR ? psR->function : nullptr;
				const void* vsf = vsR ? vsR->function : nullptr;
				const char* psn = psR ? psR->name.c_str() : "?";
				const char* vsn = vsR ? vsR->name.c_str() : "?";
				Log("* p5 ppPSO2: pair=%s vs=%s@%p ps=%s@%p", pair->name.c_str(), vsn, vsf, psn,
				    psf);
			}
		}
		// p5 launch219: PS term-bisect era — WALL-CLOCK eras anchored to the
		// first PP draw (world entry): pre-gate (t<65s) uses the original PS,
		// then 30s eras black/scene/gray/noc0/off. Draw-count eras were
		// consumed entirely by the ~200s paused era before the MCP gate.
		static const bool s_rw = !!getenv("XR_METAL_PS_REWRITE");
		MtlStageRefl psRw;
		if (s_rw && pair && psR && strstr(pair->name.c_str(), "postprocess"))
		{
			// p5 launch222: build variants from the BOUND MSL text — postprocess.ps
			// compiles in multiple macro configs; compile-time builds could patch a
			// different config than this pair carries (idempotent once filled).
			if (!psR->msl.empty())
				MtlBuildPpVariants(psR->msl, psR->entry.c_str());
			static time_t s_ppT0 = 0;
			static int s_lastEra = -2;
			// p5 launch222: the era math is provably impossible with the
			// DUMPED MSL (black mix × finite C0 ≠ yellow) — dump the MSL text
			// actually BOUND to the live PP pair (disk-cache/macro-config
			// divergence suspect) + the full RT set of a PP draw (stale
			// ping-pong RT handle suspect).
			static bool s_boundDumped = false;
			if (!s_boundDumped)
			{
				s_boundDumped = true;
				if (FILE* fb = fopen("/tmp/bound_pp_ps.msl", "w"))
				{
					fwrite(psR->msl.data(), 1, psR->msl.size(), fb);
					fclose(fb);
				}
				std::string rts;
				for (int ri = 0; ri < 4; ri++)
				{
					const char* rn = pm.rt[ri] ? MtlDbgRTGetName(pm.rt[ri]) : nullptr;
					rts += std::to_string(ri) + ":" + (rn ? rn : (pm.rt[ri] ? "?" : "null")) +
					       " ";
				}
				Log("* p5 ppRts: [%s] zb=%s", rts.c_str(),
				    pm.zb ? (MtlDbgRTGetName(pm.zb) ? MtlDbgRTGetName(pm.zb) : "?") : "null");
			}
			const time_t nowT = time(nullptr);
			if (!s_ppT0)
				s_ppT0 = nowT;
			const long el = (long)(nowT - s_ppT0) - 65;
			const int era = el < 0 ? -1 : (el / 30 > 6 ? 6 : (int)(el / 30));
			if (era != s_lastEra)
			{
				static const char* const kNm[] = {"black", "scene", "gray", "noc0", "c0view",
				                                  "constc0", "cbview"};
				Log("* p5 eraSwitch: mode=%s t=%lds", era < 0 ? "pre" : kNm[era],
				    (long)(nowT - s_ppT0));
				// launch220: dump the PP quad's raw vertex bytes — the CPU-side
				// truth for COLOR0/COLOR1 feeding the FFP VS.
				if (ds.vb && ds.vbStride >= 24)
				{
					id<MTLBuffer> vbB = (__bridge id<MTLBuffer>)ds.vb;
					const uint8_t* v0 =
						(const uint8_t*)[vbB contents] + (size_t)baseV * ds.vbStride;
					const float* f0 = (const float*)v0;
					Log("* p5 ppVB: stride=%u baseV=%u c0=%08X c1=%08X pos=(%.1f,%.1f,%.4g,%.4g)",
					    ds.vbStride, baseV, ((const uint32_t*)(v0 + 16))[0],
					    ((const uint32_t*)(v0 + 20))[0], f0[0], f0[1], f0[2], f0[3]);
				}
				s_lastEra = era;
				g_ppEra = era;
			}
			if (era >= 0 && era < 7)
			{
				void* vf = MtlPpVariantFn(era);
				if (vf)
				{
					psRw = *psR;
					psRw.function = vf;
					psR = &psRw;
				}
				else
					Log("! p5 eraSwitch: variant %d missing", era);
			}
		}
		// p5 launch200: env kill-switches for color-chain bisection (yellow
		// seed hunt on base ping-pong). Temporary diagnostics.
		{
			static const bool s_skipDistort = !!getenv("XR_METAL_SKIP_DISTORT");
			static const bool s_skipPP = !!getenv("XR_METAL_SKIP_PP");
			if (pair && (s_skipDistort || s_skipPP))
			{
				const char* nm = pair->name.c_str();
				if ((s_skipDistort && strstr(nm, "distort")) ||
				    (s_skipPP && strstr(nm, "postprocess")))
				{
					static int s_ks = 0;
					if (s_ks++ < 3)
						Log("* p5 killswitch: dropped pair=%s", nm);
					return false;
				}
			}
		}

		pm.ensureEncoder();
		if (!pm.enc)
		{
			g_dbgDrawNoEnc++;
			static int s_ne_logged = 0;
			if (s_ne_logged++ < 8)
				Log("! xrRenderMetal: draw dropped (no encoder): rt0=%p stride=%u",
				    pm.rt[0], ds.vbStride);
			return false;
		}

		id<MTLRenderPipelineState> pso = ResolvePipeline(pm, *vsR, *psR, ds.vbStride, pair);
		if (!pso)
		{
			g_dbgDrawNoPso++;
			return false;
		}
		[pm.enc setRenderPipelineState:pso];

		// p6 drawZ truth: the ACTUAL DSS + depth attachment of the live
		// encoder at draw time (Metal readonly state). If dss here differs
		// from the zW=1 state applyEncoderState created (dssgPtr), or
		// rpdZb differs from the texture the dprobe reads, that is the
		// disconnect that leaves zb unwritten.
		{
			static int s_dzLog = 0;
			const char* rnZ2 = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			if (s_dzLog < 8 && rnZ2 && strstr(rnZ2, "position"))
			{
				s_dzLog++;
				Log("- p6 drawZ: pair=%s enc=%p lastDss=%p pmZb=%p attFmt=%d",
				    pair ? pair->name.c_str() : "?",
				    (__bridge void*)pm.enc, pm.dbgLastDss, pm.zb,
				    pm.attDepthFmt);
			}
		}

		// Constants snapshot
		uint64_t slotOff = 0;
		size_t imgSize = 0;
		if (pm.ring && (pm.vsSize || pm.psSize))
		{
			const uint32_t psBase = Align16(pm.vsSize);
			const size_t copySize = psBase + Align16(pm.psSize);
			// p6 (debug-layer find): SPIRV-Cross pads _Globals past the
			// DXBC-derived cb size (observed 960 vs 896); Metal validates the
			// argument LENGTH against the whole ring buffer, so a slot ending
			// within ~1 KB of the 64 MB boundary was silently rejected
			// (vanishing draws; abort under MTL_DEBUG_LAYER). The real fix is
			// the +64 KB allocation slack (NewBuffer above): wrap still happens
			// at kRingSize, so any argument overshoot lands inside the buffer.
			// The +512 slot margin additionally stops one slot's overshoot
			// from reading the NEXT slot's live CB image.
			imgSize = copySize + 512;
			if (pm.ringOff + imgSize > kRingSize)
				pm.ringOff = 0; // launch302: wrap only here — reuse period ~30 frames ≫ CB backlog
			slotOff = pm.ringOff;
			g_lastSlotOff = slotOff; // p5 accgpu: readable from the canary block
			uint8_t* dst = (uint8_t*)[pm.ring contents] + slotOff;
			std::memcpy(dst, pm.staging.data(), copySize);
			// p5 launch217: c_brightness canary for the PP pair — if the
			// screen turns RED the GPU-side CB layout is correct and the
			// yellow must be NaN (interpolants/noise); if still YELLOW
			// the shader reads c_brightness from a different offset.
			static const bool s_cbrTest = !!getenv("XR_METAL_CBR_TEST");
			if (s_cbrTest && pair && psR && strstr(pair->name.c_str(), "postprocess"))
				for (const auto& u : psR->uniforms)
					if (u.name == "c_brightness" && u.offset + 16 <= pm.psSize)
					{
						const float v[4] = { 0.25f, 0.f, 0.f, 1.f };
						std::memcpy(dst + psBase + u.offset, v, 16);
						static int s_ct = 0;
						if (s_ct++ < 2)
							Log("* p5 cbrTest: forced (0.25,0,0,1) at off=%u", u.offset);
					}
			// p5 launch196: pixel-space quad VSes (postprocess stub) declare
			// screen_res but the pass ctable never supplies it (read as junk
			// at offset 0 → projection to a degenerate point → every PP/bloom
			// quad vanishes). Only fill when clearly bogus (x<=0 or z<=0) so
			// ctable-supplied values (bloom: 3024x1666) are left untouched.
			if (vsR && !vsR->uniforms.empty() && pm.vsSize)
				for (const auto& u : vsR->uniforms)
					if (u.name == "screen_res" && u.offset + 16 <= pm.vsSize)
					{
						float cur[4];
						std::memcpy(cur, dst + u.offset, 16);
						if (!(cur[0] > 0.f) || !(cur[2] > 0.f))
						{
							const float w = pm.screenW ? pm.screenW : 1.f;
							const float h = pm.screenH ? pm.screenH : 1.f;
							const float v4[4] = { w, h, 1.f / w, 1.f / h };
							std::memcpy(dst + u.offset, v4, 16);
						}
					}
			pm.ringOff = slotOff + Align256(imgSize);
		}

		// Vertex stream
		if (ds.vb && ds.vbStride)
			[pm.enc setVertexBuffer:(__bridge id<MTLBuffer>)ds.vb offset:0 atIndex:1];

		// p5 DIAG (launch99): for real marsh draws targeting $user$position —
		// CPU clip sim of the first 3 vertices with the exact staging bytes the
		// GPU reads, plus the resolved PSO's vertex-descriptor readback (catches
		// any descriptor/cache mismatch) and viewport z-range.
		{
			static int s_posClip = 0;
			const char* pnD = pair ? pair->name.c_str() : "?";
			const char* rtN = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			if (s_posClip < 4 && indexed && ds.vb && ds.ib && rtN && strstr(rtN, "position") &&
			    g_dbgDrawOK > 1500000ull * (unsigned)(s_posClip + 1))
			{
				s_posClip++;
				id<MTLBuffer> vbB = (__bridge id<MTLBuffer>)ds.vb;
				id<MTLBuffer> ibB = (__bridge id<MTLBuffer>)ds.ib;
				const uint16_t* i = (const uint16_t*)[ibB contents];
				Log("- p5 posclip#%d: pair=%s vbLen=%lu stride=%u ibLen=%lu startI=%u baseV=%u "
				    "primCnt=%u idx=[%u %u %u %u %u %u] vpZ=(%.3f %.3f) vsSize=%u",
				    s_posClip, pnD, (unsigned long)[vbB length], ds.vbStride,
				    (unsigned long)[ibB length], startI, baseV, primCount,
				    i[startI], i[startI + 1], i[startI + 2], i[startI + 3], i[startI + 4],
				    i[startI + 5], pm.vpMin, pm.vpMax, pm.vsSize);
				const float* mwvpC = nullptr;
				for (const auto& u : vsR->uniforms)
					if (u.name == "m_WVP" && u.offset + 64 <= pm.vsSize)
					{
						mwvpC = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
						Log("- p5 posclip#%d: reflOff=%u mWVP3=(%.2f %.2f %.2f %.2f)", s_posClip,
						    u.offset, mwvpC[12], mwvpC[13], mwvpC[14], mwvpC[15]);
						break;
					}
				// launch127: probe m_WV staging bytes (suspect zero block in merged
				// CB) + raw VB decl-attr bytes (suspect VB texcoord mapping).
				for (const auto& u : vsR->uniforms)
					if (u.name == "m_WV" && u.offset + 48 <= pm.vsSize)
					{
						const float* mwvC =
							reinterpret_cast<const float*>(pm.staging.data() + u.offset);
						Log("- p5 posclip#%d: mWVoff=%u mWV=(%.2f %.2f %.2f | %.2f %.2f %.2f | "
						    "%.2f %.2f %.2f)",
						    s_posClip, u.offset, mwvC[0], mwvC[1], mwvC[2], mwvC[4], mwvC[5],
						    mwvC[6], mwvC[8], mwvC[9], mwvC[10]);
						break;
					}
				{
					const uint8_t* vb0 = (const uint8_t*)[vbB contents];
					for (uint32_t de = 0; de < pm.declCount && de < 5; de++)
					{
						const uint8_t* a = vb0 + pm.declElems[de].Offset +
						                   (NSUInteger)baseV * ds.vbStride;
						const float* af = reinterpret_cast<const float*>(a);
						Log("- p5 posclip#%d: decl[%u] type=%u off=%u b=[%u %u %u %u %u %u %u "
						    "%u] f=(%.3f %.3f %.3f)",
						    s_posClip, de, (unsigned)pm.declElems[de].Type,
						    (unsigned)pm.declElems[de].Offset, a[0], a[1], a[2], a[3], a[4], a[5],
						    a[6], a[7], af[0], af[1], af[2]);
					}
				}
				if (mwvpC)
				{
					const uint8_t* vbase = (const uint8_t*)[vbB contents];
					for (uint32_t k = 0; k < 3; k++)
					{
						const uint8_t* vp = vbase + (NSUInteger)(baseV + i[startI + k]) * ds.vbStride;
						const float* p = reinterpret_cast<const float*>(vp);
						float vx = p[0], vy = p[1], vz = p[2];
						float cx = vx * mwvpC[0] + vy * mwvpC[4] + vz * mwvpC[8] + mwvpC[12];
						float cy = vx * mwvpC[1] + vy * mwvpC[5] + vz * mwvpC[9] + mwvpC[13];
						float cz = vx * mwvpC[2] + vy * mwvpC[6] + vz * mwvpC[10] + mwvpC[14];
						float cw = vx * mwvpC[3] + vy * mwvpC[7] + vz * mwvpC[11] + mwvpC[15];
						bool inside = cw > 0 && fabsf(cx) <= fabsf(cw) && fabsf(cy) <= fabsf(cw) &&
						              cz >= 0 && cz <= cw;
						Log("- p5 posclip#%d: i%u v=(%.2f %.2f %.2f) clip=(%.2f %.2f %.2f %.2f) %s",
						    s_posClip, k, vx, vy, vz, cx, cy, cz, cw, inside ? "INSIDE" : "out");
					}
				}
				else
					Log("- p5 posclip#%d: m_WVP not in staging", s_posClip);
			}
		}

		// p6 band-hunt: XR_METAL_CLIPSTAT — NDC-x distribution of vertices in
		// live scene draws (CPU clip math over the exact staging bytes).
		// Tris landing in the band (ndc 0.524..1.0) exist => raster drops
		// them; none => CPU culling never submitted them.
		{
			static const bool s_cstat = !!getenv("XR_METAL_CLIPSTAT");
			static uint64_t s_csNext = 0;
			static int s_csWin = 0;
			static unsigned s_csNB = 0, s_csNL = 0, s_csNBand = 0, s_csNX = 0;
			static int s_csDraws = 0;
			static const time_t s_csT0 = time(nullptr);
			static float s_csMaxNdc = -9.f;
			if (s_cstat && s_csWin < 6 && indexed && ds.vb && ds.ib && !pm.staging.empty() &&
			    g_dbgDrawOK >= s_csNext && (time(nullptr) - s_csT0) > 235)
			{
				const char* rtN2 = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				if (rtN2 && strstr(rtN2, "position"))
				{
					const float* mW = nullptr;
					for (const auto& u : vsR->uniforms)
						if (u.name == "m_WVP" && u.offset + 64 <= pm.vsSize)
						{
							mW = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
							break;
						}
					if (mW)
					{
						if (s_csDraws == 0)
							for (const auto& u : vsR->uniforms)
								if ((u.name == "m_P" || u.name == "m_VP") &&
								    u.offset + 64 <= pm.vsSize)
								{
									const float* q = reinterpret_cast<const float*>(
									    pm.staging.data() + u.offset);
									Log("- p6 %s#%d: [%.4f %.4f %.4f %.4f | %.4f %.4f %.4f %.4f | "
									    "%.4f %.4f %.4f %.4f | %.4f %.4f %.4f %.4f]",
									    u.name.c_str(), s_csWin, q[0], q[1], q[2], q[3], q[4],
									    q[5], q[6], q[7], q[8], q[9], q[10], q[11], q[12], q[13],
									    q[14], q[15]);
								}
						id<MTLBuffer> vbB = (__bridge id<MTLBuffer>)ds.vb;
						id<MTLBuffer> ibB = (__bridge id<MTLBuffer>)ds.ib;
						const uint16_t* i = (const uint16_t*)[ibB contents];
						const uint8_t* vbase = (const uint8_t*)[vbB contents];
						const uint32_t tn = primCount < 48 ? primCount : 48;
						for (uint32_t t = 0; t < tn; t++)
						{
							const uint8_t* vp =
							    vbase + (NSUInteger)(baseV + i[startI + t]) * ds.vbStride;
							const float* p = reinterpret_cast<const float*>(vp);
							const float vx = p[0], vy = p[1], vz = p[2];
							const float cx = vx * mW[0] + vy * mW[4] + vz * mW[8] + mW[12];
							const float cw = vx * mW[3] + vy * mW[7] + vz * mW[11] + mW[15];
							if (!(cw > 0.f))
							{
								s_csNB++;
								continue;
							}
							const float ndx = cx / cw;
							if (ndx > 1.f || ndx < -1.f)
								s_csNX++;
							else if (ndx > 0.524f)
								s_csNBand++;
							else
								s_csNL++;
							if (ndx < 4.f && ndx > s_csMaxNdc)
								s_csMaxNdc = ndx;
						}
						if (++s_csDraws >= 400)
						{
							Log("- p6 clipstat#%d: draws=400 behind=%u left=%u band=%u out=%u "
							    "maxndc=%.3f (px %.0f)",
							    s_csWin, s_csNB, s_csNL, s_csNBand, s_csNX, s_csMaxNdc,
							    s_csMaxNdc * 1512.f + 1512.f);
							s_csWin++;
							s_csDraws = 0;
							s_csNext = g_dbgDrawOK + 30000;
							s_csNB = s_csNL = s_csNBand = s_csNX = 0;
							s_csMaxNdc = -9.f;
						}
					}
				}
			}
 		}
 
		// p6 band-hunt: XR_METAL_DRAWBBOX — full-vertex NDC-x bbox of draws
		// in the gbuffer pass. Draws whose bbox REACHES the band yet store
		// nothing prove a per-fragment kill; zero such draws => the CPU
		// culling boundary itself is the tilted line.
		{
			static const bool s_bb = !!getenv("XR_METAL_DRAWBBOX");
			static int s_bbN = 0, s_bbLogged = 0;
			static uint64_t s_bbNext = 0;
			static const time_t s_bbT0 = time(nullptr);
			if (s_bb && s_bbLogged < 120 && indexed && ds.vb && ds.ib &&
			    !pm.staging.empty() && g_dbgDrawOK >= s_bbNext &&
			    (time(nullptr) - s_bbT0) > 235)
			{
				const char* rtN3 = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				if (rtN3 && strstr(rtN3, "position"))
				{
					const float* mW3 = nullptr;
					for (const auto& u : vsR->uniforms)
						if (u.name == "m_WVP" && u.offset + 64 <= pm.vsSize)
						{
							mW3 = reinterpret_cast<const float*>(
							    pm.staging.data() + u.offset);
							break;
						}
					if (mW3)
					{
						if (s_bbN++ == 0)
							s_bbNext = g_dbgDrawOK + 4000; // let the gate settle
						id<MTLBuffer> vbB3 = (__bridge id<MTLBuffer>)ds.vb;
						id<MTLBuffer> ibB3 = (__bridge id<MTLBuffer>)ds.ib;
						const uint16_t* i3 = (const uint16_t*)[ibB3 contents];
						const uint8_t* v3 = (const uint8_t*)[vbB3 contents];
						const uint32_t nv = primCount * 3 < 4096 ? primCount * 3
						                                         : 4096;
						float xmn = 9.f, xmx = -9.f;
						for (uint32_t k = 0; k < nv; k++)
						{
							const uint8_t* vp = v3 +
							                    (NSUInteger)(baseV + i3[startI + k]) *
							                        ds.vbStride;
							const float* p = reinterpret_cast<const float*>(vp);
							const float cx = p[0] * mW3[0] + p[1] * mW3[4] +
							                 p[2] * mW3[8] + mW3[12];
							const float cw = p[0] * mW3[3] + p[1] * mW3[7] +
							                 p[2] * mW3[11] + mW3[15];
							if (!(cw > 0.f))
								continue;
							const float nd = cx / cw;
							if (nd < xmn)
								xmn = nd;
							if (nd > xmx)
								xmx = nd;
						}
						if (xmx > 0.52f)
						{
							s_bbLogged++;
							Log("- p6 drawbbox: pair=%s prim=%u ndc=[%.2f..%.2f] "
								"px[%.0f..%.0f]",
								pair ? pair->name.c_str() : "?", primCount, xmn, xmx,
								xmn * 1512.f + 1512.f, xmx * 1512.f + 1512.f);
						}
					}
				}
			}
		}

		BindDraw(pm, pm.enc, *vsR, *psR, slotOff);

		// p5 diag: dump the first draws (which shader, what geometry, which RT).
		{
			static int s_ed_logged = 0;
			if (s_ed_logged++ < 14)
			{
				uint32_t rw = 0, rh = 0;
				pm.dev->TextureDims(pm.rt[0], &rw, &rh);
				const uint8_t* base = pm.staging.data();
				float sr[4] = {-9.f, -9.f, -9.f, -9.f};
				for (const auto& u : vsR->uniforms)
					if (u.name == "screen_res" && u.offset + 16 <= pm.vsSize)
					{
						std::memcpy(sr, base + u.offset, 16);
						break;
					}
				id<MTLBuffer> vbObj = ds.vb ? (__bridge id<MTLBuffer>)ds.vb : nil;
				const float* v0 = vbObj ? (const float*)[vbObj contents] : nullptr;
				Log("* xrRenderMetal draw#%d: pair=%s pt=%u n=%u idx=%d vbStride=%u rt=%p %ux%u "
				    "vp=(%.0f,%.0f,%.0fx%.0f) sc=%d(%d,%d,%d,%d) sr=(%.1f %.1f) zE=%d zF=%d bl=%d "
				    "v0=(%.1f %.1f %.4f %.1f)",
				    s_ed_logged, pair ? pair->name.c_str() : "stage", topology, primCount, indexed,
				    ds.vbStride, pm.rt[0], rw, rh, pm.vpX, pm.vpY, pm.vpW, pm.vpH, pm.scissorEn, pm.scL,
				    pm.scT, pm.scR, pm.scB, sr[0], sr[1], pm.depthEn, pm.depthFunc, (int)pm.blend.enabled,
				    v0 ? v0[0] : 0.f, v0 ? v0[1] : 0.f, v0 ? v0[2] : 0.f, v0 ? v0[3] : 0.f);
			}
		}

		// p5: TranslateTopology emits the pass-manager encoding
		// (0=point,1=linelist,2=linestrip,3=trilist,4=tristrip,5=trifan) —
		// NOT MTLPrimitiveType (whose 3 is TRIANGLESTRIP). Map explicitly.
		MTLPrimitiveType pt;
		switch (topology)
		{
		case 0: pt = MTLPrimitiveTypePoint; break;
		case 1: pt = MTLPrimitiveTypeLine; break;
		case 2: pt = MTLPrimitiveTypeLineStrip; break;
		case 3: pt = MTLPrimitiveTypeTriangle; break;
		case 4: pt = MTLPrimitiveTypeTriangleStrip; break;
		case 5: // D3DPT_TRIANGLEFAN -> triangle-list expansion (no Metal fan)
		{
			const uint32_t fanVerts = primCount; // fan vertex count (faces+2)
			if (fanVerts < 3)
			{
				g_dbgFanDrop++;
				static int s_fd_logged = 0;
				if (s_fd_logged++ < 8)
					Log("! xrRenderMetal: degenerate fan dropped: primCount=%u idx=%d pair=%s "
					    "vb=%p stride=%u",
					    primCount, indexed, pair ? pair->name.c_str() : "stage", ds.vb,
					    ds.vbStride);
				return false;
			}
			const uint32_t faces = fanVerts - 2;
			const uint32_t idxCount = faces * 3;
			if (indexed)
			{
				if (!ds.ib)
				{
					g_dbgDrawNoIb++;
					return false;
				}
				const uint16_t* s =
				    (const uint16_t*)[(id<MTLBuffer>)(__bridge id<MTLBuffer>)ds.ib contents];
				s += startI;
				static id<MTLBuffer> fanScratch = nil;
				const NSUInteger need = idxCount * sizeof(uint16_t);
				if (!fanScratch || [fanScratch length] < need)
					fanScratch = [(id<MTLDevice>)(__bridge id<MTLDevice>)pm.dev->Device()
						newBufferWithLength:(need < 262144 ? (NSUInteger)262144 : need * 2)
						            options:MTLResourceStorageModeShared];
				uint16_t* d = (uint16_t*)[fanScratch contents];
				for (uint32_t f = 0; f < faces; f++)
				{
					d[f * 3 + 0] = s[0];
					d[f * 3 + 1] = s[f + 1];
					d[f * 3 + 2] = s[f + 2];
				}
				[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
				                   indexCount:idxCount
				                    indexType:MTLIndexTypeUInt16
				                  indexBuffer:fanScratch
				            indexBufferOffset:0
				                instanceCount:1
				                   baseVertex:(NSInteger)baseV
				                 baseInstance:0];
				g_dbgDrawOK++;
				g_dbgFanOK++;
				return true;
			}
			// Unindexed: identity fan pattern (0, f+1, f+2), built once/cap.
			static id<MTLBuffer> fanIB = nil;
			static uint32_t fanCap = 0; // faces capacity
			if (!fanIB || faces > fanCap)
			{
				const uint32_t cap = faces > 21844 ? faces + 1024 : 21844;
				fanIB = [(id<MTLDevice>)(__bridge id<MTLDevice>)pm.dev->Device()
					newBufferWithLength:(NSUInteger)cap * 3 * sizeof(uint16_t)
					            options:MTLResourceStorageModeShared];
				uint16_t* d = (uint16_t*)[fanIB contents];
				for (uint32_t f = 0; f < cap; f++)
				{
					d[f * 3 + 0] = 0;
					d[f * 3 + 1] = (uint16_t)(f + 1);
					d[f * 3 + 2] = (uint16_t)(f + 2);
				}
				fanCap = cap;
			}
			[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
			                   indexCount:idxCount
			                    indexType:MTLIndexTypeUInt16
			                  indexBuffer:fanIB
			            indexBufferOffset:0
			                instanceCount:1
			                   baseVertex:(NSInteger)startV
			                 baseInstance:0];
			g_dbgDrawOK++;
			g_dbgFanOK++;
			return true;
		}
		default:
			static int s_fan_logged = 0;
			if (s_fan_logged++ < 4)
				Log("! xrRenderMetal: unknown topology %u in draw", topology);
			return false;
		}
		// p5 launch244: does the sun accum cuboid/mask reach the encoder?
		if (pair && strstr(pair->name.c_str(), "accum_sun"))
		{
			// launch273: re-arm the pass-end readback AFTER the sun draws —
			// the set_RT capture could fire its 1-in-120 read during the
			// emissive pass, before any sun fragment (269's "2M px" was very
			// likely emissive content, not sun).
			pm.pendingAccum = pm.rt[0];
			static int s_adN = 0;
			s_adN++;
			if (s_adN <= 12 || s_adN == 241)
			{
				const char* rn = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				Log("- p5 accdraw: n=%d pair=%s idx=%d pc=%u rt0=%s/%p zb=%p bl=%d mask=%X zE=%d zF=%d "
				    "vp=(%.0f,%.0f,%.0fx%.0f) z=(%.2f %.2f) pt=%u cull=%d scE=%d sc=(%u,%u,%u,%u)",
				    s_adN, pair->name.c_str(), (int)indexed, primCount, rn ? rn : "?", pm.rt[0],
				    pm.zb,
				    (int)pm.blend.enabled, (unsigned)pm.blend.writeMask, (int)pm.depthEn,
				    pm.depthFunc, pm.vpX, pm.vpY, pm.vpW, pm.vpH, pm.vpMin, pm.vpMax,
				    (unsigned)topology, pm.cull, (int)pm.scissorEn,
				    (unsigned)pm.scL, (unsigned)pm.scT, (unsigned)pm.scR, (unsigned)pm.scB);
				// launch245: what CB floats does the sun PS actually read?
				if (psR && pm.psSize && !pm.staging.empty())
				{
					for (const auto& u : psR->uniforms)
						if (u.name != "m_shadow" && u.name != "m_sunmask" && u.name != "m_texgen" &&
						    u.name != "view_shadow_proj" && u.offset + 16 <= pm.psSize)
						{
							const float* q = reinterpret_cast<const float*>(
							    pm.staging.data() + Align16(pm.vsSize) + u.offset);
							Log("- p5 acccb: %s off=%u (%.4g %.4g %.4g %.4g)", u.name.c_str(),
							    u.offset, q[0], q[1], q[2], q[3]);
						}
				}
				// launch250: VS-side CB + raw vertex bytes — the cuboid VS is
				// hpos=mul(m_WVP,P); a never-written VS-side m_WVP means
				// hpos=0, w=0, nothing rasterizes while every state is correct.
				if (vsR && pm.vsSize && !pm.staging.empty())
				{
					for (const auto& u : vsR->uniforms)
						if ((u.name == "m_WVP" || u.name == "m_P" || u.name == "m_V" ||
						     u.name == "m_W" || u.name == "m_texgen") &&
						    u.offset + 64 <= pm.vsSize)
						{
							const float* q = reinterpret_cast<const float*>(
							    pm.staging.data() + u.offset);
							Log("- p5 accvs: %s off=%u r0=(%.4g %.4g %.4g %.4g) r1=(%.4g %.4g %.4g %.4g) "
							    "r2=(%.4g %.4g %.4g %.4g) r3=(%.4g %.4g %.4g %.4g)",
							    u.name.c_str(), u.offset, q[0], q[1], q[2], q[3], q[4], q[5], q[6],
							    q[7], q[8], q[9], q[10], q[11], q[12], q[13], q[14], q[15]);
						}
				}
				// launch262: per-resource resolution — which stageTex entry
				// and which recorded sampler state each MSL PS resource gets.
				// Decides the DX-register vs compacted-MSL-slot theory.
				if (psR)
					for (const auto& r : psR->resources)
					{
						uint32_t ss = r.samplerSlot;
						if (ss == UINT32_MAX)
							ss = r.textureSlot;
						void* tx = r.textureSlot < kMaxStage ? pm.stageTex[r.textureSlot] : nullptr;
						const char* tnx = tx ? MtlDbgRTGetName(tx) : nullptr;
						mtlState::sSamplerState sst{};
						if (pm.recorded && ss < 36)
							sst = pm.recorded->SamplerState(ss);
						Log("- p5 accres: %s tex=%u/%p/%s samp=%u valid=%d cmpEn=%u cmpFn=%u "
						    "flt=%X",
						    r.name.c_str(), r.textureSlot, tx, tnx ? tnx : "?", ss, (int)sst.valid,
						    (unsigned)sst.CompareEnable, (unsigned)sst.CompareFunc,
						    (unsigned)sst.Filter);
					}
				if (ds.vb && ds.vbStride && ds.ib)
				{
					id<MTLBuffer> vbB2 = (__bridge id<MTLBuffer>)ds.vb;
					id<MTLBuffer> ibB2 = (__bridge id<MTLBuffer>)ds.ib;
					const uint8_t* vbP = (const uint8_t*)[vbB2 contents];
					const uint16_t* ii = (const uint16_t*)[ibB2 contents];
					const uint32_t i0 = startI + baseV, i1 = startI + baseV + 1,
					               i2 = startI + baseV + 2;
					const float* v0 = (const float*)(vbP + (size_t)i0 * ds.vbStride);
					const float* v1 = (const float*)(vbP + (size_t)i1 * ds.vbStride);
					const float* v2 = (const float*)(vbP + (size_t)i2 * ds.vbStride);
					Log("- p5 accvb: n=%d vbLen=%lu stride=%u ibLen=%lu startI=%u baseV=%u pc=%u "
					    "idx=[%u %u %u] v0=(%.3g %.3g %.3g %.3g) v1=(%.3g %.3g %.3g %.3g) "
					    "v2=(%.3g %.3g %.3g %.3g)",
					    s_adN, (unsigned long)[vbB2 length], ds.vbStride,
					    (unsigned long)[ibB2 length], startI, baseV, primCount, i0, i1, i2,
					    v0[0], v0[1], v0[2], v0[3], v1[0], v1[1], v1[2], v1[3], v2[0], v2[1],
					    v2[2], v2[3]);
				}
			}
			// launch246: accum DSV identity check. Stencil-plane readback was
			// attempted here (247-248) but Stencil8 views of Depth32Float_Stencil8
			// abort on this GPU (texture-view validation assert) — and 246's
			// NOSTENCIL+NODEPTH bypass already exonerated both state tests.
			if (s_adN == 3 || s_adN == 241)
			{
				id<MTLTexture> zt = pm.zb ? (__bridge id<MTLTexture>)pm.zb : nil;
				Log("- p5 strb: n=%d zb=%p fmt=%ld", s_adN, pm.zb,
				    zt ? (long)zt.pixelFormat : -1L);
			}
		}
		if (indexed)
		{
			if (!ds.ib)
			{
				g_dbgDrawNoIb++;
				return false;
			}
			// p5 DIAG (launch107): PS-input override probes on the first real
			// draw of a live position pass. tick==2: fragment texture slots 0..3
			// overridden with a solid-white dummy (unbound/black-sample killer);
			// tick==3: PS constants f(0) overridden with all-1.0 (PS $Globals
			// poison killer: a_ref/material/sun all sane). Same-tick postgeom
			// reads the verdict.
			{
				const char* rtNcH = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				const int tickH = (g_pgGate + 1) % 240;
				// launch110 FIX: separate guards — the shared s_lastH starved
				// tick==3 forever (tick3 pass follows tick2 one frame later,
				// ~440 draws < 50K), so H3 never fired in launch107/109.
				static uint64_t s_lastH2 = 0, s_lastH3 = 0;
				if (rtNcH && MtlCanaryOn() && strstr(rtNcH, "position") &&
				    ((tickH == 2 && g_dbgDrawOK - s_lastH2 > 50000ull) ||
				     (tickH == 3 && g_dbgDrawOK - s_lastH3 > 50000ull)))
				{
					if (tickH == 2)
						s_lastH2 = g_dbgDrawOK;
					else
						s_lastH3 = g_dbgDrawOK;
					id<MTLDevice> mdevH = (__bridge id<MTLDevice>)pm.dev->Device();
					if (tickH == 2)
					{
						static id<MTLTexture> s_white = nil;
						if (!s_white)
						{
							MTLTextureDescriptor* tdW = [MTLTextureDescriptor
								texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
							                                 width:4
							                                height:4
							                             mipmapped:NO];
							tdW.usage = MTLTextureUsageShaderRead;
							s_white = [mdevH newTextureWithDescriptor:tdW];
							if (s_white)
							{
								uint8_t pxW[4 * 4 * 4];
								memset(pxW, 0xff, sizeof(pxW));
								[s_white replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
								           mipmapLevel:0
										         withBytes:pxW
										       bytesPerRow:16];
							}
						}
						if (s_white)
							for (int sl = 0; sl < 4; sl++)
								[pm.enc setFragmentTexture:s_white atIndex:sl];
						Log("- p5 canaryH2: white-tex slots0-3 draw#%llu tex=%d", g_dbgDrawOK,
						    s_white != nil);
					}
					else
					{
						static id<MTLBuffer> s_ones = nil;
						if (!s_ones)
						{
							float ones[1024];
							for (int i = 0; i < 1024; i++)
								ones[i] = 1.0f;
							s_ones = [mdevH newBufferWithBytes:ones
							                            length:sizeof(ones)
							                          options:MTLResourceStorageModeShared];
						}
						if (s_ones)
							[pm.enc setFragmentBuffer:s_ones offset:0 atIndex:0];
						Log("- p5 canaryH3: ones-const f(0) draw#%llu buf=%d", g_dbgDrawOK,
						    s_ones != nil);
					}
				}
			}
			// launch298: debug-layer catch — the engine legitimately submits
			// primCount 0 subdraws; indexed draw with indexCount 0 is a hard
			// validation failure (UB in release). Skip like stride-0.
			if (primCount)
				[pm.enc drawIndexedPrimitives:pt
				                   indexCount:primCount
				                    indexType:MTLIndexTypeUInt16
				                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
				            indexBufferOffset:(NSUInteger)startI * 2
				                  instanceCount:1
				                     baseVertex:(NSInteger)baseV
				                   baseInstance:0];
		}
		else if (primCount)
			[pm.enc drawPrimitives:pt vertexStart:startV vertexCount:primCount];
		// p5 launch256: combine-draw binding probe — is the accum RT actually
		// bound to the combine PS, and to which slot? (postaccum proved writes
		// survive to combine entry; the black screenshot says combine drops them.)
		if (pair && strstr(pair->name.c_str(), "combine"))
		{
			static int s_cbN = 0;
			static std::map<std::string, int> s_cbCnt;
			s_cbCnt[pair->name]++;
			if (s_cbN++ < 6 || (s_cbN % 4800) == 0)
			{
				std::string dump;
				for (const auto& kv : s_cbCnt)
				{
					dump += " ";
					dump += kv.first.substr(0, 34);
					dump += "=";
					dump += std::to_string(kv.second);
				}
				Log("- p5 cbcnt: n=%d%s", s_cbN, dump.c_str());
			}
			if (s_cbN < 40)
			{
				const char* rnC = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				std::string texs;
				for (uint32_t i = 0; i < kMaxStage && i < 8; i++)
				{
					if (!pm.stageTex[i])
						continue;
					const char* tn = MtlDbgRTGetName(pm.stageTex[i]);
					char buf[96];
					snprintf(buf, sizeof(buf), " %u:%p/%s", i, pm.stageTex[i], tn ? tn : "?");
					texs += buf;
				}
				Log("- p5 cmbdraw: n=%d pair=%s rt0=%s/%p zb=%p vp=%.0fx%.0f bl=%d mask=%X texs=%s",
				    s_cbN, pair->name.c_str(), rnC ? rnC : "?", pm.rt[0], pm.zb, pm.vpW, pm.vpH,
				    (int)pm.blend.enabled, (unsigned)pm.blend.writeMask, texs.c_str());
			}
		}
		// p5 launch254: accum-pass canary, fires right after real sun draws in
		// the SAME live pass. Per-pair real VS + builtin fill PS colors the
		// geometry (mask=blue, near=red, far=green), then a builtin fullscreen
		// fill (yellow) tests pass/store persistence. rtscan mid verdict:
		// green/red => cuboid VS rasterizes (real PS/blend is the killer);
		// blue only => cuboid VS output vanishes; yellow only => pass-level
		// loss; none => encoder/attachment is a mirage.
		static const int s_fillOn = getenv("XR_P5_ACCFILL") ? atoi(getenv("XR_P5_ACCFILL")) : 0;
		if (s_fillOn && pair && strstr(pair->name.c_str(), "accum_sun") && indexed && ds.vb &&
		    ds.ib && vsR && pm.rt[0])
		{
			static uint64_t s_accN = 0;
			const uint64_t my = s_accN++;
			const bool wantBlit = (my % 240) == 5; // occasional pass-persistence probe
			// launch279b: pass-level fragment count of the PREVIOUS accum pass
			// (buffer is per-encoder; recreated each accum pass, so read the
			// pointer before this pass's encoder is replaced — value here is
			// from the last committed pass, CPU-visible after commit+wait).
			static uint64_t s_vAcc = 0;
			static id<MTLBuffer> s_prevAccBuf = nil;
			if (s_prevAccBuf != g_visAccumBuf)
			{
				if (s_prevAccBuf)
					s_vAcc = *(const uint64_t*)s_prevAccBuf.contents;
				s_prevAccBuf = g_visAccumBuf;
			}
			{
				const bool isFar = strstr(pair->name.c_str(), "far") != nullptr;
				const bool isMask = strstr(pair->name.c_str(), "mask") != nullptr;
				// launch292: far fill G=0.5 (chx[3]=56) so pure green
				// (chx[3]=60) is UNIQUE to the private non-indexed twin.
				const float col[4] = { isMask ? 0.f : (isFar ? 0.f : 1.f),
					                   isMask ? 0.f : (isFar ? 0.5f : 0.f),
					                   isMask ? 1.f : 0.f, 1.f };
				// (282: setDepthStencilState:nil is ILLEGAL — debug-layer abort.
				// NODEPTH already forces Always in the bound state; do not set.)
				pm.initBuiltins();
				bool anyB = false, anyA = false;
				// launch277: mask canary excluded — its stub_notransform VS
				// blows the quad to full-screen (RHW reinterpretation) and
				// overwrites the near/far canary verdicts before the readback
				// ever samples them (276's full-screen blue was the mask).
				if (!wantBlit && pm.fillPs && !isMask)
				{
					PipelineDesc pdB;
					pdB.vs = vsR->function;
					pdB.ps = (__bridge void*)pm.fillPs;
					pdB.stride = ds.vbStride;
					pdB.vbSlot = 1;
					DeclCursor curB{ pm.declElems, pm.declCount, {} };
					for (uint32_t i = 0; i < 16; i++)
						curB.next[i] = 0;
					for (const auto& in : vsR->inputs)
					{
						uint32_t usage = 0, index = 0;
						ParseSemantic(in.semantic, usage, index);
						int e = curB.find(usage, index);
						VertexAttr a;
						a.index = in.attribute;
						if (e < 0)
						{
							// ResolvePipeline fallback: bind missing inputs to
							// the first decl element (garbage values, valid PSO).
							if (!pm.declCount)
								continue;
							a.offset = pm.declElems[0].Offset;
							a.format = MapDeclFormat(pm.declElems[0].Type);
						}
						else
						{
							a.offset = pm.declElems[e].Offset;
							a.format = MapDeclFormat(pm.declElems[e].Type);
						}
						pdB.attrs.push_back(a);
					}
					for (int i = 0; i < pm.attColorCount && i < 4; i++)
						pdB.colorFormats.push_back(pm.attColorFmt[i]);
					MtlPdDepthFromEncoder(pm, pdB); // RC#5: match live rpd
					pdB.blend.enabled = false;
					pdB.blend.writeMask = 0xF;
					std::string errB;
					id<MTLRenderPipelineState> psoB =
					        (__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(
					            pm.dev->Device(), pdB, errB);
					if (psoB)
					{
						id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
						id<MTLBuffer> pbM = [mdev newBufferWithBytes:col
						                                     length:sizeof(col)
						                                    options:MTLResourceStorageModeShared];
						if (pbM)
						{
							// launch278: fully explicit bindings — the inherited
							// ring/VB/cull produced zero fragments in 277 even
							// with the fill PS. Rebind CB (staging copy with the
							// proven-valid m_WVP), VB slot 1, cull NONE.
							[pm.enc setRenderPipelineState:psoB];
							[pm.enc setCullMode:MTLCullModeNone];
							if (pm.vsSize || pm.psSize)
								[pm.enc setVertexBytes:pm.staging.data()
								                    length:(NSUInteger)(Align16(
						                        pm.vsSize) + Align16(pm.psSize))
						                       atIndex:0];
							[pm.enc setVertexBuffer:(__bridge id<MTLBuffer>)ds.vb
							                   offset:0 atIndex:1];
							[pm.enc setFragmentBuffer:pbM offset:0 atIndex:0];
							// launch289: GPU-side CB probe — read the ring
							// bytes the GPU actually binds for this draw
							// (vsSize block, offset 272). If m_WVP is zero on
							// the GPU side while staging is valid, the ring
							// slot was recycled/overwritten before execution.
							if (pm.ring && pm.vsSize >= 272 + 64)
							{
								static int s_gpuCbN = 0;
								if (s_gpuCbN++ < 8)
								{
									const float* rb = (const float*)
									    [pm.ring contents] + (g_lastSlotOff / 4) + 272 / 4;
									const float* st =
									    (const float*)pm.staging.data() + 272 / 4;
									Log("- p5 accgpu: ring@%llu r0=(%.4g %.4g %.4g %.4g) "
									    "r3=(%.4g %.4g %.4g %.4g) stg r0=(%.4g %.4g %.4g %.4g)",
									    (unsigned long long)g_lastSlotOff, rb[0], rb[1], rb[2],
									    rb[3], rb[12], rb[13], rb[14], rb[15], st[0], st[1], st[2],
									    st[3]);
									// Snapshot slot+value for the post-commit
									// re-read in the postaccum probe.
									g_accSlotRing = (__bridge void*)pm.ring;
									g_accSlotOff = g_lastSlotOff;
									g_accExpect0 = *(const uint32_t*)&rb[0]; // bit pattern
								}
							}
							[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
							                   indexCount:primCount
							                    indexType:MTLIndexTypeUInt16
							                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
							            indexBufferOffset:(NSUInteger)startI * 2
							                  instanceCount:1
							                     baseVertex:(NSInteger)baseV
							                   baseInstance:0];
							// launch280: cyan = same indexed draw but
							// baseVertex 0 — tests whether the DX9
							// (relative-index + baseVertex) convention is what
							// kills coverage. Plus raw index dump below.
							// launch281: red is now BAKED (idx+baseV into
							// scratch, baseVertex 0) — identical semantics to
							// the additive form. Red lands => the baseVertex
							// PARAMETER itself is broken on this runtime.
							// Cyan lands but red dies => vertices are NOT at
							// baseV*stride (lock-offset mismatch, engine side).
							{
								id<MTLDevice> mdevC2 =
								        (__bridge id<MTLDevice>)pm.dev->Device();
								id<MTLBuffer> ibB = (__bridge id<MTLBuffer>)ds.ib;
								const uint16_t* ix = ibB ? (const uint16_t*)ibB.contents : nullptr;
								static id<MTLBuffer> s_bake = nil;
								const NSUInteger need = (NSUInteger)primCount * 2;
								if (ix && (!s_bake || [s_bake length] < need))
									s_bake = [mdevC2
									            newBufferWithLength:(need < 65536 ? (NSUInteger)65536
									                                          : need * 2)
									                      options:MTLResourceStorageModeShared];
								const float colC[4] = { 0.0f, 1.0f, 1.0f, 1.0f };
								id<MTLBuffer> pbC = [mdevC2 newBufferWithBytes:colC
								                                      length:sizeof(colC)
								                                    options:MTLResourceStorageModeShared];
								if (ix && s_bake && pbC)
								{
									uint16_t* bk = (uint16_t*)[s_bake contents];
									for (NSUInteger q = 0; q < need / 2; q++)
										bk[q] = (uint16_t)(ix[startI + q] + (uint16_t)baseV);
									// NDC-shift the baked copy down (y -= 0.25)
									// so red and cyan occupy disjoint screen
									// bands — union chmax reads both verdicts.
									std::vector<uint8_t> cbShift;
									const size_t slotBytes =
									    (size_t)Align16(pm.vsSize) + Align16(pm.psSize);
									bool shifted = false;
									if (pm.vsSize >= 272 + 64)
									{
										cbShift.assign(pm.staging.begin(),
										               pm.staging.begin() +
										                   (slotBytes < pm.staging.size()
										                        ? slotBytes
										                        : pm.staging.size()));
										float* mvp = (float*)cbShift.data() + (272 / 4);
										mvp[3 * 4 + 1] -= 0.25f; // M[3][1]
										shifted = true;
									}
									if (shifted)
										[pm.enc setVertexBytes:cbShift.data()
										                  length:(NSUInteger)cbShift.size()
										                 atIndex:0];
									// (281 verdict: baked form also vanishes —
									// draw removed in 283 to free the G channel
									// for the synthetic-triangle probe.)
									[pm.enc setFragmentBuffer:pbC offset:0 atIndex:0];
									(void)pbC;
								}
								if (ix)
								{
									id<MTLBuffer> vbB = (__bridge id<MTLBuffer>)ds.vb;
									const float* vAt =
									    vbB ? (const float*)vbB.contents : nullptr;
									const float* vB =
									    vAt ? vAt + (size_t)baseV * (ds.vbStride / 4) : nullptr;
									// CPU clip-space transform with the live
									// m_WVP (row-vector form, M@272): if the
									// result is behind the camera (w<=0) or
									// outside z-range the cuboid legitimately
									// clips away — a data bug, not a Metal bug.
									// All 8 cuboid corners' clip-w: if every
									// w<=0 the slab is legitimately behind the
									// camera; mixed signs + zero fragments =>
									// GPU-side data differs from CPU contents.
									char wc[200];
									wc[0] = 0;
									if (vB && pm.staging.size() >= 272 + 64)
									{
										const float* MM =
									    (const float*)pm.staging.data() + 272 / 4;
										int wo = 0;
										for (int c = 0; c < 8; c++)
										{
											const float* cv = vB + (size_t)c * (ds.vbStride / 4);
											float cw = 0;
											for (int i = 0; i < 4; i++)
												cw += cv[i] * MM[i * 4 + 3];
											wo += snprintf(wc + wo, sizeof(wc) - wo, "%.0f ", cw);
										}
									}
									char cb2[288];
									char cb3[640];
									cb3[0] = 0;
									if (vB && pm.vsSize >= 272 + 64 &&
									    pm.staging.size() >= 272 + 64)
									{
										const float* M = (const float*)pm.staging.data() + 272 / 4;
										float o[4] = { 0, 0, 0, 0 };
										for (int j = 0; j < 4; j++)
											for (int i = 0; i < 4; i++)
												o[j] += vB[i] * M[i * 4 + j];
										snprintf(cb2, sizeof(cb2),
										         " clip=(%.1f %.1f %.1f w=%.1f) WVP[r0=(%.2f %.2f "
										         "%.2f %.2f) r3=(%.2f %.2f %.2f %.2f)]",
										         o[0], o[1], o[2], o[3], M[0], M[1], M[2], M[3],
										         M[12], M[13], M[14], M[15]);
										const float* Pv = (const float*)pm.staging.data() + 96 / 4;
										const float* Vv = (const float*)pm.staging.data() + 48 / 4;
										snprintf(cb3, sizeof(cb3),
										         " P=[%.4g %.4g %.4g %.4g|%.4g %.4g %.4g %.4g|%.4g %.4g "
										         "%.4g %.4g|%.4g %.4g %.4g %.4g]"
										         " V=[%.4g %.4g %.4g %.4g|%.4g %.4g %.4g %.4g|%.4g %.4g "
										         "%.4g %.4g|%.4g %.4g %.4g %.4g]"
										         " WVP=[%.4g %.4g %.4g %.4g|%.4g %.4g %.4g %.4g|%.4g %.4g "
										         "%.4g %.4g|%.4g %.4g %.4g %.4g]",
										         Pv[0], Pv[1], Pv[2], Pv[3], Pv[4], Pv[5], Pv[6], Pv[7],
										         Pv[8], Pv[9], Pv[10], Pv[11], Pv[12], Pv[13], Pv[14],
										         Pv[15], Vv[0], Vv[1], Vv[2], Vv[3], Vv[4], Vv[5], Vv[6],
										         Vv[7], Vv[8], Vv[9], Vv[10], Vv[11], Vv[12], Vv[13],
										         Vv[14], Vv[15], M[0], M[1], M[2], M[3], M[4], M[5], M[6],
										         M[7], M[8], M[9], M[10], M[11], M[12], M[13], M[14],
										         M[15]);
									}
									else
										cb2[0] = 0;
									char xb[192];
									int xo = 0;
									xo += snprintf(xb + xo, sizeof(xb) - xo,
									               "v@bV=(%.1f %.1f %.1f %.1f)",
									               vB ? vB[0] : 0.f, vB ? vB[1] : 0.f,
									               vB ? vB[2] : 0.f, vB ? vB[3] : 0.f);
									snprintf(xb + xo, sizeof(xb) - xo, " v@0=(%.1f %.1f %.1f %.1f)",
									         vAt ? vAt[0] : 0.f, vAt ? vAt[1] : 0.f,
									         vAt ? vAt[2] : 0.f, vAt ? vAt[3] : 0.f);
									Log("- p5 accix: ib=%p len=%llu startI=%u baseV=%u pc=%u "
									    "idx=[%u %u %u %u] %s%s w8=(%s)%s",
									    (void*)ds.ib, (unsigned long long)[ibB length],
									    (unsigned)startI, (unsigned)baseV, (unsigned)primCount,
									    ix[startI], ix[startI + 1], ix[startI + 2], ix[startI + 3],
									    xb, cb2, wc, cb3);
								}
							}
							// launch290: FULLY-PRIVATE cuboid canary — private
							// VB (copy of primCount verts at baseV), private IB
							// (raw indices: verts copied region-relative start
							// at 0), private CB (setVertexBytes staging copy),
							// fill PS MAGENTA. Zero dependency on dynamic-buffer
							// lifetimes. Magenta lands (chx[5]=60 is unique to
							// it) => shared ds.vb/ds.ib/ring contents differ at
							// GPU exec time (aliasing/recycling). Vanishes even
							// fully private => defect is PSO/vertex-descriptor
							// level for this pair. (Replaces 283 synthetic: its
							// hand-rolled inverse was row/col transposed — the
							// "vanished" verdict was not evidence.)
							{
								static id<MTLBuffer> s_pVB = nil, s_pIB = nil;
								static id<MTLBuffer> s_sVB = nil, s_sIB = nil;
								// mask pair (stub VS, RHW quad) would land the
								// green twin unconditionally — contaminate the
								// cuboid verdict. Gate to NEAR pair only
								// (292: far fill recolored to G=0.5, so
								// green-60 = private non-indexed, magenta
								// chx[5]=60 = private indexed, both near-only).
								const bool privOK =
								    strstr(pair->name.c_str(), "near") !=
								    nullptr;
								id<MTLBuffer> vbB2 = (__bridge id<MTLBuffer>)ds.vb;
								id<MTLBuffer> ibB2 = (__bridge id<MTLBuffer>)ds.ib;
								const uint8_t* vsrc =
								    vbB2 ? (const uint8_t*)[vbB2 contents] : nullptr;
								const uint16_t* isrc =
								    ibB2 ? (const uint16_t*)[ibB2 contents] : nullptr;
								const size_t vbBytes = (size_t)primCount * ds.vbStride;
								const size_t slotBytes =
								    (size_t)Align16(pm.vsSize) + Align16(pm.psSize);
								if (privOK && vsrc && isrc && pm.vsSize &&
								    pm.psSize && pm.staging.size() >= slotBytes &&
								    (size_t)baseV * ds.vbStride + vbBytes <=
								        [vbB2 length] &&
								    ((size_t)startI + primCount) * 2 <= [ibB2 length])
								{
									id<MTLDevice> dv =
									    (__bridge id<MTLDevice>)pm.dev->Device();									if (!s_pVB || [s_pVB length] < vbBytes)
										s_pVB = [dv newBufferWithLength:
										             (vbBytes < 65536 ? (NSUInteger)65536
										                              : vbBytes * 2)
										                       options:
										                           MTLResourceStorageModeShared];
									if (!s_pIB || [s_pIB length] < primCount * 2)
										s_pIB = [dv newBufferWithLength:65536
										                        options:
										                            MTLResourceStorageModeShared];
									if (s_pVB && s_pIB)
									{
										memcpy([s_pVB contents],
										       vsrc + (size_t)baseV * ds.vbStride, vbBytes);
										memcpy([s_pIB contents], isrc + startI,
										       primCount * 2);
										const float colP[4] = { 1.0f, 0.0f, 1.0f, 1.0f };
										id<MTLBuffer> pbP =
										    [dv newBufferWithBytes:colP
										                    length:sizeof(colP)
										                  options:
										                      MTLResourceStorageModeShared];
										if (pbP)
										{
											[pm.enc setVertexBytes:pm.staging.data()
											                length:(NSUInteger)slotBytes
											               atIndex:0];
											[pm.enc setVertexBuffer:s_pVB
											                   offset:0 atIndex:1];
											[pm.enc setFragmentBuffer:pbP
											                     offset:0 atIndex:0];
											[pm.enc drawIndexedPrimitives:
											    MTLPrimitiveTypeTriangle
											                   indexCount:primCount
											                    indexType:
											                        MTLIndexTypeUInt16
											                  indexBuffer:s_pIB
											            indexBufferOffset:0
											                instanceCount:1
											                   baseVertex:0
											                 baseInstance:0];
											// launch291: private NON-indexed twin
											// (the 279-proven form, private bytes,
											// GREEN = chx[3] unique). Indexed dies
											// + green lands => index-path defect
											// survives total privatization.
											{
												id<MTLDevice> dv2 =
												    (__bridge id<MTLDevice>)pm.dev->Device();
												const float colG2[4] = {
													0.0f, 1.0f, 0.0f, 1.0f
												};
												id<MTLBuffer> pbG2 =
												    [dv2 newBufferWithBytes:colG2
												                     length:sizeof(colG2)
												                   options:
												                       MTLResourceStorageModeShared];
												if (pbG2)
												{
													[pm.enc setFragmentBuffer:pbG2
													                     offset:0
													                    atIndex:0];
													[pm.enc drawPrimitives:
													    MTLPrimitiveTypeTriangle
													              vertexStart:0
													              vertexCount:primCount];
												}
											}
											// launch293: synthetic INDEXED
											// triangle at a KNOWN centered
											// screen position. Solves w·WVP=ndc
											// for w (row-vector convention,
											// Gaussian elimination — no inverse
											// transpose trap). chx[1]=60 (with
											// red proven dead 15 launches) =>
											// indexed path ALIVE and cuboid
											// coverage was legitimately zero
											// (sun off-screen). chx[1]=0 with
											// green alive => indexed path dead
											// in this pass, mechanism unknown.
											{
												const float* M = nullptr;
												if (pm.vsSize >= 272 + 64 &&
												    pm.staging.size() >= 272 + 64)
													M = (const float*)
									                            pm.staging.data() +
									                                272 / 4;
												float verts[12];
												bool ok = M != nullptr;
												const float ndc[3][4] = {
													{ -0.5f, -0.5f, 0.3f, 1.f },
													{ 0.5f, -0.5f, 0.3f, 1.f },
													{ 0.f, 0.5f, 0.3f, 1.f }
												};
												for (int v = 0; ok && v < 3; ++v)
												{
													float A[4][5];
													for (int j = 0; j < 4; ++j)
													{
														for (int i = 0; i < 4; ++i)
															A[j][i] =
															    M[i * 4 + j];
														A[j][4] = ndc[v][j];
													}
													for (int col = 0;
													     col < 4 && ok; ++col)
													{
														int piv = col;
														float best =
														    fabsf(A[col][col]);
														for (int r = col + 1;
														     r < 4; ++r)
															if (fabsf(A[r][col]) >
															    best)
															{
																best =
																    fabsf(
																        A[r][col]);
																piv = r;
															}
														if (best < 1e-9f)
														{
															ok = false;
															break;
														}
														if (piv != col)
															for (int k = col;
															     k < 5; ++k)
															{
																float t =
																    A[col][k];
																A[col][k] =
																    A[piv][k];
																A[piv][k] = t;
															}
														for (int r = 0; r < 4; ++r)
														{
															if (r == col)
																continue;
															const float f =
															    A[r][col] /
															    A[col][col];
															for (int k = col;
															     k < 5; ++k)
																A[r][k] -=
																    f *
																    A[col][k];
														}
													}
													if (!ok)
														break;
													for (int i = 0; i < 4; ++i)
														verts[v * 4 + i] =
														    A[i][4] / A[i][i];
												}
												if (ok)
												{
													id<MTLDevice> dv3 =
													    (__bridge
													         id<MTLDevice>)
													        pm.dev->Device();
													if (!s_sVB)
														s_sVB = [dv3
													            newBufferWithLength:256
													                        options:
													                            MTLResourceStorageModeShared];
													if (!s_sIB)
													{
														const uint16_t tri[3] = {
															0, 1, 2
														};
														s_sIB = [dv3
													            newBufferWithBytes:tri
													                        length:
													                            sizeof(tri)
													                      options:
													                          MTLResourceStorageModeShared];
													}
													if (s_sVB && s_sIB)
													{
														memcpy([s_sVB contents],
														       verts,
														       sizeof(verts));
														const float colM2[4] = {
															1.0f, 0.5f, 0.0f,
															1.0f
														};
														id<MTLBuffer> pbM2 =
														    [dv3 newBufferWithBytes:
						                                                                colM2
						                                                     length:
						                                                         sizeof(
						                                                             colM2)
						                                                   options:
						                                                       MTLResourceStorageModeShared];
														if (pbM2)
														{
															[pm.enc
															    setVertexBuffer:
															        s_sVB
																	 offset:0
																	atIndex:1];
															[pm.enc
															    setFragmentBuffer:
															        pbM2
																	 offset:0
																	atIndex:0];
															[pm.enc
															    drawIndexedPrimitives:
															        MTLPrimitiveTypeTriangle
																	   indexCount:3
																	    indexType:
																	        MTLIndexTypeUInt16
																	  indexBuffer:
																	      s_sIB
															    indexBufferOffset:0
															        instanceCount:1
															           baseVertex:0
															         baseInstance:0];
															static int s_synLog = 0;
															if (s_synLog++ < 2)
																Log("- p5 accsyn: "
																    "idx tri "
																    "w0=(%.1f "
																    "%.1f %.1f "
																    "%.3f) "
																    "w2=(%.1f "
																    "%.1f %.1f "
																    "%.3f)",
																    verts[0],
																    verts[1],
																    verts[2],
																    verts[3],
																    verts[8],
																    verts[9],
																    verts[10],
																    verts[11]);
														}
													}
												}
											}
											// restore shared VB binding for later draws
											[pm.enc setVertexBuffer:
											    (__bridge id<MTLBuffer>)ds.vb offset:0
											                atIndex:1];
											static int s_privN = 0;
											if (s_privN++ < 4)
												Log("- p5 accpriv: drew idx+nonidx "
												    "%s pc=%u vbBytes=%zu slot=%zu "
												    "enc=%p",
												    pair->name.c_str(),
												    (unsigned)primCount, vbBytes,
												    slotBytes,
												    (__bridge void*)pm.enc);
										}
									}
								}
								else if (vsrc)
								{
									static int s_privSkip = 0;
									if (s_privSkip++ < 4)
										Log("! p5 accpriv: gated out vs=%u ps=%u stg=%zu "
										    "slot=%zu vbN=%llu ibN=%llu",
										    (unsigned)pm.vsSize, (unsigned)pm.psSize,
										    pm.staging.size(), slotBytes,
										    (unsigned long long)[vbB2 length],
										    (unsigned long long)[ibB2 length]);
								}
							}
							anyB = true;
						}
					}
					else
						Log("! p5 acccanary: realVS+fillPS PSO failed: %s", errB.c_str());
				}
				if (wantBlit)
				{
					int fmtC = pm.dev->TextureFormat(pm.rt[0]);
					id<MTLRenderPipelineState> bp =
					        pm.blitPipeline((MTLPixelFormat)fmtC, true, false, pm.attDepthFmt);
					static id<MTLBuffer> s_pbY = nil;
					if (!s_pbY)
					{
						const float prm[4] = { 1.0f, 1.0f, 0.5f, 0.0f };
						id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
						s_pbY = [mdev newBufferWithBytes:prm
						                        length:sizeof(prm)
						                       options:MTLResourceStorageModeShared];
					}
					if (bp && s_pbY)
					{
						[pm.enc setRenderPipelineState:bp];
						[pm.enc setVertexBuffer:s_pbY offset:0 atIndex:0];
						[pm.enc setFragmentBuffer:s_pbY offset:0 atIndex:0];
						[pm.enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
						            vertexCount:3];
						anyA = true;
					}
				}
				if (my < 6 || wantBlit)
					Log("- p5 acccanary: pair=%s vsFill=%d blitFill=%d atts=%d fmt0=%d col=(%.0f,%.0f,%.0f) "
					    "vAcc=%llu",
					    pair->name.c_str(), (int)anyB, (int)anyA, pm.attColorCount,
					    pm.attColorCount ? pm.attColorFmt[0] : -1, col[0], col[1], col[2],
					    (unsigned long long)s_vAcc);
			}
		}
		// p5 DIAG (launch100): fill canary — once, after a real draw that
		// targeted $user$position, encode a builtin solid-color fullscreen fill
		// into the SAME live pass. If the next rtscan sees it, the pass/store
		// machinery is sound and the deffer PSOs themselves are suspect; if it
		// stays black, the pass machinery is the suspect.
		// p5 FIX (launch105): the old canary never bound buffer(0) — the blit VS
		// read the real draw's constants as params => NaN vertex position =>
		// triangle discarded by the rasterizer. Its "death" proved nothing.
		// Probe G now binds a real params buffer, fires at the START of a
		// position pass every 240th pass (same tick the postgeom readback runs),
		// so the pass-end commit+wait+readback reports whether it landed.
		{
			const char* rtNc = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			static uint64_t s_lastCanaryDraw = 0;
			if (rtNc && MtlCanaryOn() && strstr(rtNc, "position") && (g_pgGate + 1) % 240 == 0 &&
			    g_dbgDrawOK - s_lastCanaryDraw > 50000ull)
			{
				s_lastCanaryDraw = g_dbgDrawOK;
				int fmtC = pm.dev->TextureFormat(pm.rt[0]);
				id<MTLRenderPipelineState> bp =
					pm.blitPipeline((MTLPixelFormat)fmtC, true, false, pm.attDepthFmt);
				static id<MTLBuffer> s_pb = nil;
				if (!s_pb)
				{
					const float prm[4] = { 1.0f, 1.0f, 0.5f, 0.0f };
					id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
					s_pb = [mdev newBufferWithBytes:prm
					                         length:sizeof(prm)
					                        options:MTLResourceStorageModeShared];
				}
				if (bp && s_pb)
				{
					[pm.enc setRenderPipelineState:bp];
					[pm.enc setVertexBuffer:s_pb offset:0 atIndex:0];
					[pm.enc setFragmentBuffer:s_pb offset:0 atIndex:0];
					[pm.enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					Log("- p5 canaryG: fill encoded at live pospass, fmt=%d draw#%llu rt=%p", fmtC,
					    g_dbgDrawOK, pm.rt[0]);
				}
				else
					Log("! p5 canaryG: pso=%d buf=%d fmt=%d", bp != nil, s_pb != nil, fmtC);
			}
		}
		// p5 DIAG (launch101): second canary — REAL deffer VS + builtin fill PS,
		// same geometry/attributes/pass. Discriminates VS-output/raster (canary
		// fills => real PS is the killer) from PS-side losses (still black =>
		// even with a trivial PS the real VS output produces no fragments).
		// p5 FIX (launch105): bind a real params buffer at fragment(0) for the
		// fill PS (old version read the real PS's constants as color params),
		// gate one pass after canaryG's tick so postgeom reads both verdicts,
		// and re-fire periodically instead of once.
		{
			static uint64_t s_lastVsCanary = 0;
			const char* rtNc = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			if (rtNc && MtlCanaryOn() && strstr(rtNc, "position") && indexed && ds.vb && ds.ib &&
			    (g_pgGate + 1) % 240 == 1 && g_dbgDrawOK - s_lastVsCanary > 50000ull)
			{
				s_lastVsCanary = g_dbgDrawOK;
				pm.initBuiltins();
				if (pm.fillPs)
				{
					PipelineDesc pdB;
					pdB.vs = vsR->function;
					pdB.ps = (__bridge void*)pm.fillPs;
					pdB.stride = ds.vbStride;
					pdB.vbSlot = 1;
					DeclCursor curB{ pm.declElems, pm.declCount, {} };
					for (uint32_t i = 0; i < 16; i++)
						curB.next[i] = 0;
					for (const auto& in : vsR->inputs)
					{
						uint32_t usage = 0, index = 0;
						ParseSemantic(in.semantic, usage, index);
						int e = curB.find(usage, index);
						if (e < 0)
							continue;
						VertexAttr a;
						a.index = in.attribute;
						a.offset = pm.declElems[e].Offset;
						a.format = MapDeclFormat(pm.declElems[e].Type);
						pdB.attrs.push_back(a);
					}
					// launch297 fix: use the LIVE rpd attachment list (debug
					// layer caught rt[0]/rt[1]-only PSOs asserting against the
					// 3-attachment deferred pass — release silently UB'd).
					for (int iF = 0; iF < pm.attColorCount && iF < 4; iF++)
						pdB.colorFormats.push_back(pm.attColorFmt[iF]);
					MtlPdDepthFromEncoder(pm, pdB); // RC#5: match live rpd
					pdB.blend.enabled = false;
					pdB.blend.writeMask = 0xF;
					std::string errB;
					id<MTLRenderPipelineState> psoB =
						(__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(pm.dev->Device(),
						                                                        pdB, errB);
					if (psoB)
					{
						[pm.enc setRenderPipelineState:psoB];
						// fill PS reads color params from fragment buffer(0): give it
						// real values, not the real PS's constants left bound by BindDraw.
						static id<MTLBuffer> s_pbVs = nil;
						if (!s_pbVs)
						{
							const float prm[4] = { 1.0f, 0.0f, 1.0f, 1.0f }; // magenta = vscanary landed
							id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
							s_pbVs = [mdev newBufferWithBytes:prm
							                           length:sizeof(prm)
							                          options:MTLResourceStorageModeShared];
						}
						if (s_pbVs)
							[pm.enc setFragmentBuffer:s_pbVs offset:0 atIndex:0];
						[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
						                   indexCount:primCount
						                    indexType:MTLIndexTypeUInt16
						                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
						            indexBufferOffset:(NSUInteger)startI * 2
						                  instanceCount:1
						                     baseVertex:(NSInteger)baseV
						                   baseInstance:0];
						Log("- p5 vscanary: realVS+fillPS encoded pair=%s attrs=%d", rtNc,
						    (int)pdB.attrs.size());
					}
					else
						Log("! p5 vscanary: PSO failed: %s", errB.c_str());
				}
				else
					Log("! p5 vscanary: fillPs nil");
			}
		}
		// p5 DIAG (launch183): S14 SAMPLER probe — real VS + probe PS that samples
		// texture(0)@sampler(0) (the real draw's bindings, still bound in this
		// encoder) and writes BOTH geometry attachments:
		//   o0 -> position = sample*8 + 0.0625 (black sample => half 0.0625,
		//        hi byte 48 = postgeom X flag)
		//   o1 -> albedo   = sample + (0.5,0.25,0.125) (ANY sample => nonzero px)
		// Verdict: rtscan albedo nz jumps => live sampling+write OK, real PS is
		// the culprit. position X-flagged but albedo still 0 => probe drew and
		// sampled BLACK => binding/sampler is the culprit. Neither => probe died.
		{
			static uint64_t s_lastS14 = 0;
			static int s_s14Budget = 6;
			static id<MTLFunction> s_probeFn = nil;
			static bool s_probeTried = false;
			const char* rtNcP = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			const char* rtNcA = pm.rt[1] ? MtlDbgRTGetName(pm.rt[1]) : nullptr;
			if (rtNcP && strstr(rtNcP, "position") && rtNcA &&
			    strstr(rtNcA, "albedo") && indexed && ds.vb && ds.ib && vsR &&
			    g_dbgDrawOK - s_lastS14 > 20000ull && s_s14Budget > 0)
			{
				if (!s_probeTried)
				{
					s_probeTried = true;
					static const char* s14src = R"metal(
#include <metal_stdlib>
using namespace metal;
struct S14Out { float4 p [[color(0)]]; float4 a [[color(1)]]; };
fragment S14Out xrprobe_ps(float4 pos [[stage_in]],
                           texture2d<float> t0 [[texture(0)]],
                           sampler s0 [[sampler(0)]])
{
    float3 c = t0.sample(s0, float2(0.30f, 0.35f)).rgb;
    S14Out o;
    o.p = float4(c * 8.0 + 0.0625, 1.0);
    o.a = float4(c + float3(0.5f, 0.25f, 0.125f), 1.0);
    return o;
}
)metal";
					id<MTLDevice> mdev = (__bridge id<MTLDevice>)pm.dev->Device();
					NSError* e14 = nil;
					id<MTLLibrary> lib =
					    [mdev newLibraryWithSource:@(s14src) options:nil error:&e14];
					if (lib)
						s_probeFn = [lib newFunctionWithName:@"xrprobe_ps"];
					Log("- p5 S14: probe fn=%d err=%s", s_probeFn != nil,
					    e14.localizedDescription.UTF8String ?: "-");
				}
				if (s_probeFn)
				{
					s_lastS14 = g_dbgDrawOK;
					s_s14Budget--;
					PipelineDesc pdP;
					pdP.vs = vsR->function;
					pdP.ps = (__bridge void*)s_probeFn;
					pdP.stride = ds.vbStride;
					pdP.vbSlot = 1;
					DeclCursor curP{ pm.declElems, pm.declCount, {} };
					for (uint32_t i = 0; i < 16; i++)
						curP.next[i] = 0;
					for (const auto& in : vsR->inputs)
					{
						uint32_t usage = 0, index = 0;
						ParseSemantic(in.semantic, usage, index);
						int e = curP.find(usage, index);
						if (e < 0)
							continue;
						VertexAttr a;
						a.index = in.attribute;
						a.offset = pm.declElems[e].Offset;
						a.format = MapDeclFormat(pm.declElems[e].Type);
						pdP.attrs.push_back(a);
					}
					for (int iP = 0; iP < pm.attColorCount && iP < 4; iP++)
						pdP.colorFormats.push_back(pm.attColorFmt[iP]);
					MtlPdDepthFromEncoder(pm, pdP);
					pdP.blend.enabled = false;
					pdP.blend.writeMask = 0xF;
					std::string errP;
					id<MTLRenderPipelineState> psoP =
						(__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(pm.dev->Device(),
						                                                        pdP, errP);
					if (psoP)
					{
						[pm.enc setRenderPipelineState:psoP];
						[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
						                   indexCount:primCount
						                    indexType:MTLIndexTypeUInt16
						                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
						            indexBufferOffset:(NSUInteger)startI * 2
						                  instanceCount:1
						                     baseVertex:(NSInteger)baseV
						                   baseInstance:0];
						Log("- p5 S14: sampler probe drew pair=%s idx=%u",
						    pair ? pair->name.c_str() : "?", primCount);
					}
					else
						Log("! p5 S14: PSO failed: %s", errP.c_str());
				}
			}
		}
		// p5 DIAG (launch110): canaryI — REAL VS + builtin PS that RETURNS the
		// world-position interpolant (locn1 float4) as color. Directly tests
		// whether VS->PS interpolant DATA flows at draw time (vscanary only
		// proved gl_Position transforms; fillPS ignored user attributes).
		// Landing (non-zero, position-valued) => interpolants flow, PS
		// constants/inputs are the killer. Zero => interpolant flow broken.
		{
			static uint64_t s_lastI = 0;
			const char* rtNcI = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
			// launch128: one-shot c6 (skinned) decl dump — the vertex-format fix
			// needs the real TEXCOORD0/bone decl types behind the int4 MSL input.
			static bool s_dumpBump = false;
			if (!s_dumpBump && pair && strstr(pair->name.c_str(), "bump-hq|deffer_base_bump-hq"))
			{
				s_dumpBump = true;
				for (uint32_t d = 0; d < pm.declCount && d < 6; d++)
					Log("- p5 decl6: decl[%d] type=%d usage=%d idx=%d off=%d (pair=%s)", (int)d,
					    (int)pm.declElems[d].Type, (int)pm.declElems[d].Usage,
					    (int)pm.declElems[d].UsageIndex, (int)pm.declElems[d].Offset,
					    pair->name.c_str());
			}
			// launch125: capture a REAL DEFER pair only (launch124 captured a rain
			// shader whose PS has no TEXCOORD1 => passthru fell back to magenta yet
			// readback was zero — rain geometry may not cover; verdict unreliable).
			const bool defferI = psR->name.find("deffer") != std::string::npos &&
			                     psR->msl.find("in_var_TEXCOORD1") != std::string::npos &&
			                     vsR->msl.find("m_WVP") != std::string::npos;
			if (!defferI && ((g_pgGate + 1) % 240 == 5 || (g_pgGate + 1) % 240 == 6) && rtNcI &&
			    strstr(rtNcI, "position"))
			{
				static int s_skipI = 0;
				if (s_skipI++ < 40)
					Log("- p5 canaryI: skip ps=%s vsMslLen=%d psMslLen=%d", psR->name.c_str(),
					    (int)vsR->msl.size(), (int)psR->msl.size());
			}
			// launch127: window 5 (ODD parity = MAIN model position pass;
			// windows 0/2/4 are the rain position pass — launch124/125 captured
			// rain because tick-4 was rain-pass parity. vscanary w=1 proved odd=main.)
			// launch129: capture up to 8 deffer draws per window (a single small
			// off-screen mesh rasterizes nothing => false zero), and REUSE the
			// compiled passthrough fn per PS (launch128 recompiled per capture:
			// ~420MB/capture pipeline-cache growth => 45GB RSS, user-reported).
			if (defferI && rtNcI && strstr(rtNcI, "position") && indexed && ds.vb && ds.ib &&
			    ((g_pgGate + 1) % 240 == 5 || (g_pgGate + 1) % 240 == 6) &&
			    (int)s_appQ.size() < 8)
			{
				s_lastI = g_dbgDrawOK;
				// launch111 FIX: build the passthru PS from the LIVE pair's
				// ALIGNED main0_in struct (hardcoded struct mismatched the live
				// VS: "Fragment input(s) user(locn1..3) mismatching").
				id<MTLFunction> fnI = nil;
				static std::map<std::string, id<MTLFunction>> s_pthFn; // leak fix (launch129)
				const auto itF = s_pthFn.find(psR->name);
				if (itF != s_pthFn.end())
					fnI = itF->second;
				else
				{
					const std::string psSrcI = psR->msl;
					const size_t sI = psSrcI.find("struct main0_in");
					const size_t bI =
						sI == std::string::npos ? std::string::npos : psSrcI.find('{', sI);
					const size_t eI =
						bI == std::string::npos ? std::string::npos : psSrcI.find("};", bI);
					if (eI != std::string::npos)
					{
						const std::string body = psSrcI.substr(bI, eI - bI);
						std::string retExpr = "float4(1.0, 0.0, 1.0, 1.0)";
						std::string fldType = "none";
						const size_t fI = body.find("in_var_TEXCOORD1");
						const size_t f0I = body.find("in_var_TEXCOORD0");
						if (fI != std::string::npos && f0I != std::string::npos)
						{
							// launch125 discriminator: R = TEXCOORD0 nonzero (VB
							// packed-texcoord family), G = TEXCOORD1 nonzero (world
							// pos = skinnedPos*m_WV family). mid bytes read as
							// (0,60,0,60)=both live, (0,60,0,0)=VB-only (m_WV dead),
							// (0,0,0,60)=VB texcoords dead, (0,0,0,0)=all dead.
							fldType = "tc0|tc1";
							// launch129 layout: R=0.5 ALWAYS (landing proof),
							// G=1 if any TEXCOORD0 != 0, B=1 if any TEXCOORD1 != 0.
							retExpr =
								"float4(0.5, "
								"any(in.in_var_TEXCOORD0.xy != float2(0.0)) ? 1.0 : 0.0, "
								"any(in.in_var_TEXCOORD1 != float4(0.0)) ? 1.0 : 0.0, 1.0)";
						}
						else if (fI != std::string::npos)
						{
							size_t lsI = body.rfind('\n', fI);
							lsI = lsI == std::string::npos ? 0 : lsI + 1;
							const std::string line = body.substr(lsI, body.find(';', fI) - lsI);
							const size_t spI = line.find(' ');
							const std::string type = line.substr(0, spI);
							const size_t nsI = line.find_first_not_of(" \t", spI);
							const size_t neI = line.find_first_of(" \t[", nsI);
							const std::string name = line.substr(nsI, neI - nsI);
							fldType = type;
							if (type == "float4")
								retExpr = "float4(in." + name + ".xyz, 1.0)";
							else if (type == "float3")
								retExpr = "float4(in." + name + ", 1.0)";
							else if (type == "float2")
								retExpr = "float4(in." + name + ", 0.0, 1.0)";
						}
						const std::string srcI = psSrcI.substr(0, eI + 2) +
						                         "\nfragment float4 xrip_ps(main0_in in "
						                         "[[stage_in]]) { return " +
						                         retExpr + "; }\n";
						id<MTLDevice> mdevI = (__bridge id<MTLDevice>)pm.dev->Device();
						NSError* errI = nil;
						id<MTLLibrary> libI = [mdevI newLibraryWithSource:
						                                      [NSString stringWithUTF8String:srcI.c_str()]
						                                                options:nil
						                                                  error:&errI];
						fnI = libI ? [libI newFunctionWithName:@"xrip_ps"] : nil;
						s_pthFn[psR->name] = fnI; // cache nil too: never recompile
						if (!fnI)
							Log("! p5 canaryI: passthru compile failed (%s): %s", fldType.c_str(),
							    errI ? [[errI localizedDescription] UTF8String] : "?");
						else
							Log("- p5 canaryI: passthru built ps=%s field=%s", psR->name.c_str(),
							    fldType.c_str());
					}
					else
						Log("! p5 canaryI: no main0_in in ps msl (len=%d)", (int)psSrcI.size());
				}
				if (fnI)
				{
					PipelineDesc pdI;
					pdI.vs = vsR->function;
					pdI.ps = (__bridge void*)fnI;
					pdI.stride = ds.vbStride;
					pdI.vbSlot = 1;
					DeclCursor curI{ pm.declElems, pm.declCount, {} };
					for (uint32_t i = 0; i < 16; i++)
						curI.next[i] = 0;
					for (const auto& in : vsR->inputs)
					{
						uint32_t usage = 0, index = 0;
						ParseSemantic(in.semantic, usage, index);
						int e = curI.find(usage, index);
						if (e < 0)
							continue;
						VertexAttr a;
						a.index = in.attribute;
						a.offset = pm.declElems[e].Offset;
						a.format = MapDeclFormat(pm.declElems[e].Type);
						pdI.attrs.push_back(a);
					}
					for (int iI = 0; iI < pm.attColorCount && iI < 4; iI++)
						pdI.colorFormats.push_back(pm.attColorFmt[iI]);
					// launch158: match the live rpd's depth/stencil formats.
					// Release tolerates the mismatch (draw just lands), but
					// MTL_DEBUG_LAYER hard-asserts at setRenderPipelineState
					// (launch157/158 died before marsh on exactly this).
					pdI.depthFormat = pm.attDepthFmt;
					if (pm.attDepthFmt == 260)
						pdI.stencilFormat = pm.attDepthFmt;
					pdI.blend.enabled = false;
					pdI.blend.writeMask = 0xF;
					std::string errI;
					id<MTLRenderPipelineState> psoI =
						(__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(pm.dev->Device(),
						                                                        pdI, errI);
					if (psoI)
					{
						[pm.enc setRenderPipelineState:psoI];
						[pm.enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
						                   indexCount:primCount
						                    indexType:MTLIndexTypeUInt16
						                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
						            indexBufferOffset:(NSUInteger)startI * 2
						                  instanceCount:1
						                     baseVertex:(NSInteger)baseV
						                   baseInstance:0];
						Log("- p5 canaryI: realVS+passthruPS encoded attrs=%d idx=%d",
						    (int)pdI.attrs.size(), (int)primCount);
						// launch129: queue for PASS-END re-encode (un-overwritten).
						MtlAppendCanary ap;
						ap.pso = psoI;
						ap.ring = pm.ring;
						ap.ringOff = (NSUInteger)slotOff;
						// launch130: snapshot the CB bytes — the ring slot is
						// overwritten by every later draw, so by pass-end it is
						// another pair's constants (=> wrong m_WVP, off-screen).
						if (pm.ring)
						{
							id<MTLDevice> mdevCB = (__bridge id<MTLDevice>)pm.dev->Device();
							const NSUInteger cbLen = 8192;
							ap.cb = [mdevCB newBufferWithLength:cbLen
							                            options:MTLResourceStorageModeShared];
							if (ap.cb)
								memcpy(ap.cb.contents,
								       (const uint8_t*)pm.ring.contents + slotOff, cbLen);
						}
						// launch133: snapshot the VS-stage textures + samplers
						// exactly as BindDraw just bound them (pair VSes sample
						// lightmaps etc.; a missing VS binding feeds the VS
						// garbage => NaN verts => zero fragments).
						{
							const std::array<uint8_t, 8> kindsK = ParseMslTexKinds(*vsR);
							for (const auto& r : vsR->resources)
							{
								if (r.isSamplerOnly)
									continue;
								const uint32_t slot = r.textureSlot;
								void* tex = slot < kMaxStage ? pm.stageTex[slot] : nullptr;
								if (tex && slot < 8)
								{
									id<MTLTexture> t = (__bridge id<MTLTexture>)tex;
									const uint8_t kind = slot < 8 ? kindsK[slot] : kTex2D;
									bool mismatch = false;
									switch (kind)
									{
									case kTexCube:
										mismatch = t.textureType != MTLTextureTypeCube;
										break;
									case kTex1D:
										mismatch = t.textureType != MTLTextureType1D;
										break;
									case kTex2DArray:
										mismatch = t.textureType != MTLTextureType2DArray;
										break;
									case kTex3D:
										mismatch = t.textureType != MTLTextureType3D;
										break;
									default:
										mismatch = t.textureType == MTLTextureTypeCube ||
										           t.textureType == MTLTextureType1D ||
										           t.textureType == MTLTextureType2DArray;
									}
									if (mismatch)
									{
										id<MTLTexture> d =
										    MtlKindDummy((__bridge id<MTLDevice>)pm.dev->Device(),
										                 kind);
										if (d)
											t = d;
									}
									ap.vtex[slot] = t;
								}
								uint32_t ss = r.samplerSlot;
								if (ss == UINT32_MAX)
									ss = slot;
								if (ss >= kMaxStage)
									ss = 0;
								MetalDevice::SamplerDesc desc;
								if (pm.recorded)
								{
									const auto& sst = pm.recorded->SamplerState(ss);
									if (sst.valid)
										desc = MakeSamplerDesc(sst, pm.globalBias);
									else
										desc = DefaultSamplerDesc(pm.globalBias);
								}
								else
									desc = DefaultSamplerDesc(pm.globalBias);
								id<MTLSamplerState> samp =
								    (__bridge id<MTLSamplerState>)pm.dev->SamplerFull(desc);
								if (samp && ss < 8)
									ap.vsamp[ss] = samp;
							}
						}
						// launch155: PS-stage snapshot too — the terrain VS
						// samples nothing, so a VS-only snapshot left the S13
						// live PS sampling UNBOUND textures (NaN out => BGRA8
						// reads back 0 => verdict ambiguous).
						if (psR)
						{
							const std::array<uint8_t, 8> kindsP = ParseMslTexKinds(*psR);
							for (const auto& r : psR->resources)
							{
								if (r.isSamplerOnly)
									continue;
								const uint32_t slot = r.textureSlot;
								void* tex = slot < kMaxStage ? pm.stageTex[slot] : nullptr;
								if (tex && slot < 8)
								{
									id<MTLTexture> t = (__bridge id<MTLTexture>)tex;
									const uint8_t kind = kindsP[slot];
									bool mismatch = false;
									switch (kind)
									{
									case kTexCube:
										mismatch = t.textureType != MTLTextureTypeCube;
										break;
									case kTex1D:
										mismatch = t.textureType != MTLTextureType1D;
										break;
									case kTex2DArray:
										mismatch = t.textureType != MTLTextureType2DArray;
										break;
									case kTex3D:
										mismatch = t.textureType != MTLTextureType3D;
										break;
									default:
										mismatch = t.textureType == MTLTextureTypeCube ||
										           t.textureType == MTLTextureType1D ||
										           t.textureType == MTLTextureType2DArray;
									}
									if (mismatch)
									{
										id<MTLTexture> d =
										    MtlKindDummy((__bridge id<MTLDevice>)
										                     pm.dev->Device(),
										                 kind);
										if (d)
											t = d;
									}
									ap.ptex[slot] = t;
								}
								uint32_t ss = r.samplerSlot;
								if (ss == UINT32_MAX)
									ss = slot;
								if (ss >= kMaxStage)
									ss = 0;
								MetalDevice::SamplerDesc sdP;
								if (pm.recorded)
								{
									const auto& sst = pm.recorded->SamplerState(ss);
									if (sst.valid)
										sdP = MakeSamplerDesc(sst, pm.globalBias);
									else
										sdP = DefaultSamplerDesc(pm.globalBias);
								}
								else
									sdP = DefaultSamplerDesc(pm.globalBias);
								id<MTLSamplerState> sampP =
								    (__bridge id<MTLSamplerState>)pm.dev->SamplerFull(sdP);
								if (sampP && ss < 8)
									ap.psamp[ss] = sampP;
							}
						}
						// launch138: S-draw — the pair VS UNMODIFIED + a
						// constant-white PS rendering into a clean 1024²
						// scratch RT (cleared black, no depth). Vertex
						// functions cannot write buffers in MSL (the
						// launch137 P-probe was illegal), so the VS output
						// is measured through rasterization instead: hit
						// count + bbox say WHERE the draw projects when
						// nothing else can interfere.
						{
							static id<MTLFunction> s_whiteFn = nil;
							static bool s_wTried = false;
							if (!s_wTried)
							{
								s_wTried = true;
								id<MTLDevice> devW = (__bridge id<MTLDevice>)pm.dev->Device();
								NSError* eW = nil;
								id<MTLLibrary> libW =
								    [devW newLibraryWithSource:@"#include <metal_stdlib>\n"
								                             "using namespace metal;\n"
								                             "fragment float4 wps() { return "
								                             "float4(1.0, 1.0, 1.0, 1.0); }\n"
													   options:nil
													     error:&eW];
								if (libW)
								{
									id<MTLFunction> fW =
									    [libW newFunctionWithName:@"wps"];
									s_whiteFn = fW;
								}
								else
									Log("! p5 canaryI: wps lib failed: %s",
									    [[eW localizedDescription] UTF8String]);
							}
							if (s_whiteFn && s_appQ.size() < 8)
							{
								PipelineDesc pdS = pdI;
								pdS.depthFormat = 0; // scratch pass: depthless
								pdS.stencilFormat = 0;
								pdS.ps = (__bridge void*)s_whiteFn;
								pdS.colorFormats.clear();
								pdS.colorFormats.push_back(80); // BGRA8 scratch
								std::string errS;
								id<MTLRenderPipelineState> sp =
								    (__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(
								        pm.dev->Device(), pdS, errS);
								if (sp)
								{
									ap.sPso = sp;
									ap.sSlot = (int)s_appQ.size();
								}
								else
									Log("! p5 canaryI: Sdraw PSO failed (%s): %s",
									    vsR->name.c_str(), errS.c_str());
							}
						}
						// launch144: S2-draw — CLIPPER hypothesis. launch127
						// posclip computed a clip position z≈w≈-170: NEGATIVE w
						// => Metal clips every primitive (the trivial probe VSes
						// all emitted w=+1, which is why they landed while every
						// engine-VS draw stayed zero). Patch the live VS MSL:
						// force w=|w| and z=0.5w before every 'return out;'.
						// S2 (green) landing while S (white) is zero == the
						// clipper is the killer.
						{
							static std::map<std::string, id<MTLFunction>> s_wabsFn;
							id<MTLFunction> fnW2 = nil;
							const auto itW = s_wabsFn.find(vsR->name);
							if (itW != s_wabsFn.end())
								fnW2 = itW->second;
							else
							{
								std::string srcW = vsR->msl;
								const std::string patW = "return out;";
								const std::string repW =
								    "out.gl_Position.w = fabs(out.gl_Position.w) + "
								    "0.0001;\n    out.gl_Position.z = "
								    "out.gl_Position.w * 0.5;\n    return out;";
								size_t pW = 0, nWp = 0;
								while ((pW = srcW.find(patW, pW)) != std::string::npos)
								{
									srcW.replace(pW, patW.size(), repW);
									pW += repW.size();
									nWp++;
								}
								if (nWp)
								{
									id<MTLDevice> devW3 =
									    (__bridge id<MTLDevice>)pm.dev->Device();
									NSError* eW3 = nil;
									id<MTLLibrary> libW3 =
									    [devW3 newLibraryWithSource:
									           [NSString stringWithUTF8String:srcW.c_str()]
									                       options:nil
									                         error:&eW3];
									fnW2 = libW3 ? [libW3 newFunctionWithName:@"main0"] : nil;
									if (!fnW2)
										Log("! p5 canaryI: S2 vs compile failed: %s",
										    eW3 ? [[eW3 localizedDescription] UTF8String]
										            : "?");
								}
								else
									Log("! p5 canaryI: S2 patch: no 'return out;' in %s",
									    vsR->name.c_str());
								s_wabsFn[vsR->name] = fnW2;
							}
							if (fnW2)
							{
								static id<MTLFunction> s_greenFn = nil;
								static bool s_gTried = false;
								if (!s_gTried)
								{
									s_gTried = true;
									id<MTLDevice> devG =
									    (__bridge id<MTLDevice>)pm.dev->Device();
									NSError* eG = nil;
									id<MTLLibrary> libG =
									    [devG newLibraryWithSource:
									           @"#include <metal_stdlib>\n"
									           "using namespace metal;\n"
									           "fragment float4 gps() { return "
									           "float4(0.0, 1.0, 0.0, 1.0); }\n"
									                                     options:nil
									                                       error:&eG];
									if (libG)
										s_greenFn = [libG newFunctionWithName:@"gps"];
									else
										Log("! p5 canaryI: gps lib failed: %s",
										    [[eG localizedDescription] UTF8String]);
								}
								if (s_greenFn)
								{
									PipelineDesc pdW3 = pdI;
									pdW3.depthFormat = 0; // scratch pass: depthless
									pdW3.stencilFormat = 0;
									pdW3.vs = (__bridge void*)fnW2;
									pdW3.ps = (__bridge void*)s_greenFn;
									pdW3.colorFormats.clear();
									pdW3.colorFormats.push_back(80);
									std::string errW3;
									id<MTLRenderPipelineState> sp2 =
									    (__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(
									        pm.dev->Device(), pdW3, errW3);
									if (sp2)
										ap.s2Pso = sp2;
									else
										Log("! p5 canaryI: S2 PSO failed: %s",
										    errW3.c_str());
								}
							}
						}
						// launch145: S4/S5/S6 — launch144 verdict (S=0, S2 full
						// screen 135k hits) proved the CLIPPER kills every
						// engine-VS fragment while x/y/w stay sane (geometry
						// projected correctly once z/w forced inside). S4
						// forwards raw clip coords through a locn30 interpolant
						// so a PS reports sign(w) + z/w; S5 patches ONLY
						// z=0.5w; S6 ONLY w=-w. Which of S5/S6 lands names the
						// killer clip plane exactly.
						{
							id<MTLDevice> devP = (__bridge id<MTLDevice>)pm.dev->Device();
							static std::map<std::string, id<MTLFunction>> s_p4, s_p5, s_p6;
							static std::map<std::string, id<MTLFunction>> s_p7, s_p8, s_p9;
							id<MTLFunction> f5 = MtlPatchVsFn(
							    devP, vsR->msl, nullptr,
							    "out.gl_Position.z = out.gl_Position.w * 0.5", "S5",
							    vsR->name, s_p5);
							id<MTLFunction> f6 =
							    MtlPatchVsFn(devP, vsR->msl, nullptr,
							                 "out.gl_Position.w = -out.gl_Position.w", "S6",
							                 vsR->name, s_p6);
							// launch147: S7 = clipdbg readout + z FORCED inside
							// (so fragments survive to the PS and the true z/w
							// histogram gets sampled). S8/S9 = the two candidate
							// production remaps as landing booleans.
							id<MTLFunction> f7 = MtlPatchVsFn(
							    devP, vsR->msl, "float4 clipdbg [[user(locn30)]]",
							    "out.clipdbg = out.gl_Position; out.gl_Position.z = "
							    "out.gl_Position.w * 0.5",
							    "S7", vsR->name, s_p7);
							id<MTLFunction> f8 = MtlPatchVsFn(
							    devP, vsR->msl, nullptr,
							    "out.gl_Position.z = out.gl_Position.z * 0.5 + "
							    "out.gl_Position.w * 0.5",
							    "S8", vsR->name, s_p8);
							id<MTLFunction> f9 = MtlPatchVsFn(
							    devP, vsR->msl, nullptr,
							    "out.gl_Position.z = out.gl_Position.z * 0.5 + "
							    "out.gl_Position.w",
							    "S9", vsR->name, s_p9);
							// launch149: S11 z'=z-0.5w (lands iff z/w in [0.5,1.5]);
							// S12 z'=clamp(z,1e-4w,0.9999w) — order-preserving
							// guaranteed-landing candidate production fix.
							static std::map<std::string, id<MTLFunction>> s_p11, s_p12;
							id<MTLFunction> f11 = MtlPatchVsFn(
							    devP, vsR->msl, nullptr,
							    "out.gl_Position.z = out.gl_Position.z - "
							    "out.gl_Position.w * 0.5",
							    "S11", vsR->name, s_p11);
							id<MTLFunction> f12 = MtlPatchVsFn(
							    devP, vsR->msl, nullptr,
							    "out.gl_Position.z = clamp(out.gl_Position.z, "
							    "out.gl_Position.w * 0.0001, out.gl_Position.w * 0.9999)",
							    "S12", vsR->name, s_p12);
							static id<MTLFunction> s_clipFn, s_cyanFn, s_redFn, s_mgnFn, s_ylwFn;
							static id<MTLFunction> s_limeFn, s_orngFn;
							static bool s_psTried = false;
							if (!s_psTried)
							{
								s_psTried = true;
								NSError* e1 = nil;
								id<MTLLibrary> l1 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "struct PIN { float4 pos "
								                       "[[position]]; float4 clip "
								                       "[[user(locn30)]]; };\n"
								                       "fragment float4 clipps(PIN in "
								                       "[[stage_in]]) {\n"
								                       "  float w = in.clip.w;\n"
								                       "  float zw = in.clip.z / "
								                       "((fabs(w) > 1e-6) ? w : 1e-6);\n"
								                       "  return float4(w < 0.0 ? 0.25 : "
								                       "0.5, clamp((zw - 1.0) * 2.0 + "
								                       "0.5, 0.0, 1.0), 0.5, 1.0);\n"
								                       "}\n"
								                         options:nil
								                           error:&e1];
								if (l1)
									s_clipFn = [l1 newFunctionWithName:@"clipps"];
								else
									Log("! p5 canaryI: clipps lib failed: %s",
									    [[e1 localizedDescription] UTF8String]);
								NSError* e2 = nil;
								id<MTLLibrary> l2 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 cyps() { return "
								                       "float4(0.0, 1.0, 1.0, 1.0); }\n"
								                         options:nil
								                           error:&e2];
								if (l2)
									s_cyanFn = [l2 newFunctionWithName:@"cyps"];
								else
									Log("! p5 canaryI: cyps lib failed: %s",
									    [[e2 localizedDescription] UTF8String]);
								NSError* e3 = nil;
								id<MTLLibrary> l3 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 rdsps() { return "
								                       "float4(1.0, 0.0, 0.0, 1.0); }\n"
								                         options:nil
								                           error:&e3];
								if (l3)
									s_redFn = [l3 newFunctionWithName:@"rdsps"];
								else
									Log("! p5 canaryI: rdsps lib failed: %s",
									    [[e3 localizedDescription] UTF8String]);
								// launch147: S8 magenta, S9 yellow.
								NSError* e4 = nil;
								id<MTLLibrary> l4 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 mgnps() { return "
								                       "float4(1.0, 0.0, 1.0, 1.0); }\n"
								                         options:nil
								                           error:&e4];
								if (l4)
									s_mgnFn = [l4 newFunctionWithName:@"mgnps"];
								else
									Log("! p5 canaryI: mgnps lib failed: %s",
									    [[e4 localizedDescription] UTF8String]);
								NSError* e5 = nil;
								id<MTLLibrary> l5 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 ylwps() { return "
								                       "float4(1.0, 1.0, 0.0, 1.0); }\n"
								                         options:nil
								                           error:&e5];
								if (l5)
									s_ylwFn = [l5 newFunctionWithName:@"ylwps"];
								else
									Log("! p5 canaryI: ylwps lib failed: %s",
									    [[e5 localizedDescription] UTF8String]);
								// launch149: S11 lime (0.5,1,0), S12 orange (1,0.5,0).
								NSError* e6 = nil;
								id<MTLLibrary> l6 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 lmsps() { return "
								                       "float4(0.5, 1.0, 0.0, 1.0); }\n"
								                         options:nil
								                           error:&e6];
								if (l6)
									s_limeFn = [l6 newFunctionWithName:@"lmsps"];
								else
									Log("! p5 canaryI: lmsps lib failed: %s",
									    [[e6 localizedDescription] UTF8String]);
								NSError* e7 = nil;
								id<MTLLibrary> l7 = [devP
								    newLibraryWithSource:@"#include <metal_stdlib>\n"
								                       "using namespace metal;\n"
								                       "fragment float4 orgps() { return "
								                       "float4(1.0, 0.5, 0.0, 1.0); }\n"
								                         options:nil
								                           error:&e7];
								if (l7)
									s_orngFn = [l7 newFunctionWithName:@"orgps"];
								else
									Log("! p5 canaryI: orgps lib failed: %s",
									    [[e7 localizedDescription] UTF8String]);
							}
							if (f7 && s_clipFn)
							{
								PipelineDesc pd7 = pdI;
								pd7.depthFormat = 0; // scratch pass: depthless
								pd7.stencilFormat = 0;
								pd7.vs = (__bridge void*)f7;
								pd7.ps = (__bridge void*)s_clipFn;
								pd7.colorFormats.clear();
								pd7.colorFormats.push_back(80);
								std::string err7;
								ap.s7Pso = (__bridge id<MTLRenderPipelineState>)
								               pm.cache->Pipeline(pm.dev->Device(), pd7, err7);
								if (!ap.s7Pso)
									Log("! p5 canaryI: S7 PSO failed: %s", err7.c_str());
							}
							if (f8 && s_mgnFn)
							{
								PipelineDesc pd8 = pdI;
								pd8.depthFormat = 0; // scratch pass: depthless
								pd8.stencilFormat = 0;
								pd8.vs = (__bridge void*)f8;
								pd8.ps = (__bridge void*)s_mgnFn;
								pd8.colorFormats.clear();
								pd8.colorFormats.push_back(80);
								std::string err8;
								ap.s8Pso = (__bridge id<MTLRenderPipelineState>)
								               pm.cache->Pipeline(pm.dev->Device(), pd8, err8);
								if (!ap.s8Pso)
									Log("! p5 canaryI: S8 PSO failed: %s", err8.c_str());
							}
							if (f9 && s_ylwFn)
							{
								PipelineDesc pd9 = pdI;
								pd9.depthFormat = 0; // scratch pass: depthless
								pd9.stencilFormat = 0;
								pd9.vs = (__bridge void*)f9;
								pd9.ps = (__bridge void*)s_ylwFn;
								pd9.colorFormats.clear();
								pd9.colorFormats.push_back(80);
								std::string err9;
								ap.s9Pso = (__bridge id<MTLRenderPipelineState>)
								               pm.cache->Pipeline(pm.dev->Device(), pd9, err9);
								if (!ap.s9Pso)
									Log("! p5 canaryI: S9 PSO failed: %s", err9.c_str());
							}
							if (f11 && s_limeFn)
							{
								PipelineDesc pd11 = pdI;
								pd11.depthFormat = 0; // scratch pass: depthless
								pd11.stencilFormat = 0;
								pd11.vs = (__bridge void*)f11;
								pd11.ps = (__bridge void*)s_limeFn;
								pd11.colorFormats.clear();
								pd11.colorFormats.push_back(80);
								std::string err11;
								ap.s11Pso = (__bridge id<MTLRenderPipelineState>)
								                pm.cache->Pipeline(pm.dev->Device(), pd11, err11);
								if (!ap.s11Pso)
									Log("! p5 canaryI: S11 PSO failed: %s", err11.c_str());
							}
							if (f12 && s_orngFn)
							{
								PipelineDesc pd12 = pdI;
								pd12.depthFormat = 0; // scratch pass: depthless
								pd12.stencilFormat = 0;
								pd12.vs = (__bridge void*)f12;
								pd12.ps = (__bridge void*)s_orngFn;
								pd12.colorFormats.clear();
								pd12.colorFormats.push_back(80);
								std::string err12;
								ap.s12Pso = (__bridge id<MTLRenderPipelineState>)
								                pm.cache->Pipeline(pm.dev->Device(), pd12, err12);
								if (!ap.s12Pso)
									Log("! p5 canaryI: S12 PSO failed: %s", err12.c_str());
							}
							// launch154 S13: live VS + LIVE PS (the one component
							// every probe so far replaced with a trivial PS). If the
							// live PS discards/zeroes real geometry fragments, S13
							// dies while S12 lands.
							if (psR && psR->function)
							{
								PipelineDesc pd13 = pdI;
								pd13.depthFormat = 0; // scratch pass: depthless
								pd13.stencilFormat = 0;
								pd13.ps = psR->function;
								pd13.colorFormats.clear();
								for (int i13 = 0; i13 < 4; i13++)
									pd13.colorFormats.push_back(
									    (int)MTLPixelFormatRGBA32Float);
								std::string err13;
								ap.s13Pso = (__bridge id<MTLRenderPipelineState>)
								                pm.cache->Pipeline(pm.dev->Device(), pd13, err13);
								if (!ap.s13Pso)
									Log("! p5 canaryI: S13 PSO failed: %s", err13.c_str());
							}
							else
								Log("! p5 canaryI: S13 build skipped psR=%d fn=%d",
								    psR != nullptr, psR ? psR->function != nullptr : 0);
							if (f5 && s_cyanFn)
							{
								PipelineDesc pd5 = pdI;
								pd5.depthFormat = 0; // scratch pass: depthless
								pd5.stencilFormat = 0;
								pd5.vs = (__bridge void*)f5;
								pd5.ps = (__bridge void*)s_cyanFn;
								pd5.colorFormats.clear();
								pd5.colorFormats.push_back(80);
								std::string err5;
								ap.s5Pso = (__bridge id<MTLRenderPipelineState>)
								               pm.cache->Pipeline(pm.dev->Device(), pd5, err5);
								if (!ap.s5Pso)
									Log("! p5 canaryI: S5 PSO failed: %s", err5.c_str());
							}
							if (f6 && s_redFn)
							{
								PipelineDesc pd6 = pdI;
								pd6.depthFormat = 0; // scratch pass: depthless
								pd6.stencilFormat = 0;
								pd6.vs = (__bridge void*)f6;
								pd6.ps = (__bridge void*)s_redFn;
								pd6.colorFormats.clear();
								pd6.colorFormats.push_back(80);
								std::string err6;
								ap.s6Pso = (__bridge id<MTLRenderPipelineState>)
								               pm.cache->Pipeline(pm.dev->Device(), pd6, err6);
								if (!ap.s6Pso)
									Log("! p5 canaryI: S6 PSO failed: %s", err6.c_str());
							}
						}
						ap.vb = (__bridge id<MTLBuffer>)ds.vb;
						ap.ib = (__bridge id<MTLBuffer>)ds.ib;
						ap.ibOff = (NSUInteger)startI * 2;
						ap.idxCount = primCount;
						ap.baseV = baseV;
						ap.stride = ds.vbStride; // launch134: V-draw
						ap.name = pair ? pair->name : "stage"; // launch166 dump
						ap.valid = true;
						s_appQ.push_back(ap);
					}
					else
						Log("! p5 canaryI: PSO failed: %s", errI.c_str());
				}
			}
		}
		// p5 diag: per-pair histogram + full encoder state for the first draws
		// landing on NAMED scene RTs ($user$position etc.): mask/blend/depth at
		// the exact draw that should paint the g-buffer.
		{
			const char* pn = pair ? pair->name.c_str() : "stage";
			g_mtlPairDraws[pn]++;
			const char* n0 = nullptr;
			for (int i = 0; i < 4; i++)
				if (pm.rt[i] && g_mtlRtNames.count(pm.rt[i]))
				{
					n0 = g_mtlRtNames[pm.rt[i]].c_str();
					break;
				}
			if (!n0 && pm.zb && g_mtlRtNames.count(pm.zb)) // zfill (depth-only) draws too
				n0 = g_mtlRtNames[pm.zb].c_str();
			// p5 launch231: who rasterizes the SUN shadow map? (accum_sun
			// multiplies by avg4(smap taps) — an untouched smap_depth = black
			// sun = black accum.) Budget-free so smap_rain draws can't hide it.
			if (n0 && strstr(n0, "smap_depth"))
			{
				static std::map<std::string, unsigned long long> s_smapW;
				const std::string sk = pn ? pn : "?";
				const unsigned long long sc = ++s_smapW[sk];
				if (sc <= 3 || sc % 600 == 0)
					Log("* p5 smapw: pair=%s n=%llu", sk.c_str(), sc);
			}
			static std::map<std::string, int> s_scLogged;
			// p5 launch216: postprocess bypasses the 6-draw budget
			// periodically — old budget-3 sampling only saw the first
			// post-load (still-black pop-in) frames, never steady state.
			static int s_ppPass = 0;
			const bool ppPeriodic =
			    pn && (strstr(pn, "postprocess") || strstr(pn, "combine_1")) &&
			    (s_ppPass++ % 240) < 1;
			// p6: load-phase samples (first 6/pair) proved unreliable for
			// in-game matrices; re-arm a second budget once we are safely
			// in-game (present-count stair, same gate style as dprobe).
			static std::map<std::string, int> s_scIngameN;
			// Periodic in-game sampling: must see m_V rotate when state
			// yaw= moves. Frozen m_V => render cam static => band is the
			// map-edge void under the stubbed black sky, not a clip bug.
			const bool scPresTick = (g_mtlPresentCount % 600) == 0;
			const bool scIngame =
			    g_mtlPresentCount > 12200 && s_scIngameN[pn]++ < 40 && scPresTick;
			if (n0 && (s_scLogged[pn]++ < 6 || ppPeriodic || scIngame))
			{
				// p5 launch194: what screen_res do the pixel-space quad VSes
				// actually receive? (0 => VS projects to a degenerate point.)
				bool srFound = false;
				for (const auto& u : vsR->uniforms)
				{
					if (u.name == "screen_res" && u.offset + 16 <= pm.vsSize)
					{
						float srq[4];
						std::memcpy(srq, pm.staging.data() + u.offset, 16);
						Log("* p5 scres: pair=%s off=%u sr=(%.2f %.2f %.6f %.6f)", pn,
						    u.offset, srq[0], srq[1], srq[2], srq[3]);
						srFound = true;
						break;
					}
				}
				if (!srFound)
				{
					std::string un;
					for (size_t ui = 0; ui < vsR->uniforms.size() && ui < 12; ui++)
					{
						un += vsR->uniforms[ui].name;
						un += ",";
					}
					Log("* p5 scres: pair=%s NO screen_res uniforms=[%s]", pn, un.c_str());
				}
				// p5 launch199: is set_c("c_brightness") landing in the PS CB?
				// (PP paints solid yellow when this offset holds junk.)
				for (const auto& u : psR->uniforms)
				{
					if (u.name == "c_brightness" && u.offset + 16 <= pm.psSize)
					{
						float cbq[4];
						std::memcpy(cbq, pm.staging.data() + Align16(pm.vsSize) + u.offset, 16);
						Log("* p5 cbr: pair=%s off=%u val=(%.3f %.3f %.3f %.3f)", pn, u.offset,
						    cbq[0], cbq[1], cbq[2], cbq[3]);
						break;
					}
				}
				// p5 launch201: PP paints yellow — dump which TEXTURE each
				// fragment stage slot actually resolves to for this draw.
				// p5 launch226: + the two black-output suspects (albedo MRT
				// writer + sun accumulation) and their PS constants.
				if (strstr(pn, "postprocess") || strstr(pn, "combine_1") ||
				    strstr(pn, "deffer_base_flat") || strstr(pn, "accum_sun"))
				{
					std::string sl;
					for (int si = 0; si < 8; si++)
					{
						if (!pm.stageTex[si])
						{
							sl += std::to_string(si) + ":null ";
							continue;
						}
						const char* tn = MtlDbgRTGetName(pm.stageTex[si]);
						id<MTLTexture> tt = (__bridge id<MTLTexture>)pm.stageTex[si];
						// p5 launch227: type/depth/mips — texture3d material arg
						// vs 2D-created texture silently kills accum_sun+combine.
						sl += std::to_string(si) + ":" + (tn ? tn : "?") +
						      " " + std::to_string(tt.width) + "x" + std::to_string(tt.height) +
						      " f" + std::to_string((int)tt.pixelFormat) +
						      " t" + std::to_string((int)tt.textureType) +
						      " z" + std::to_string((int)tt.depth) +
						      " m" + std::to_string((int)tt.mipmapLevelCount) +
						      " @" + std::to_string((size_t)(uintptr_t)tt) + " ";
					}
					Log("* p5 ppslots: pair=%s [%s]", pn, sl.c_str());					// p5 launch209: yellow = real (1,1,0) values — dump raw
					// p5 launch226: PS constants for the black-output suspects.
					if (strstr(pn, "deffer_base_flat") || strstr(pn, "accum_sun"))
					{
						// p5 launch230: region sizes + FULL member bytes —
						// m_shadow@976 needs 64B; the old 16B probe hid whether
						// rows 1-3 landed, and the size line exposes cbSize
						// truncation (1024 vs 1040) directly.
						static std::map<std::string, int> s_t5sz;
						if (s_t5sz[pn]++ < 2)
							Log("* p5 t5sz: pair=%s vsSize=%u psSize=%u psBase=%u staging=%zu",
							    pn, pm.vsSize, pm.psSize, pm.psBase, pm.staging.size());
						int unc = 0;
						const size_t ps0 = Align16(pm.vsSize);
						for (const auto& u : psR->uniforms)
						{
							if (ps0 + u.offset >= pm.staging.size())
							{
								Log("* p5 t5cb: %s %s off=%u OOB ps=%zu", pn, u.name.c_str(),
								    u.offset, pm.staging.size() - ps0);
								if (++unc >= 32)
									break;
								continue;
							}
							uint32_t nb = u.size > 64 ? 16u : (u.size < 16u ? 16u : u.size);
							if (u.offset + nb > pm.staging.size() - ps0)
								nb = (uint32_t)(pm.staging.size() - ps0 - u.offset);
							std::string vq;
							for (uint32_t b = 0; b + 4 <= nb; b += 4)
							{
								float q;
								std::memcpy(&q, pm.staging.data() + ps0 + u.offset + b, 4);
								char tmp[32];
								snprintf(tmp, sizeof tmp, " %.4g", q);
								vq += tmp;
							}
							Log("* p5 t5cb: %s %s off=%u/%u%s", pn, u.name.c_str(), u.offset,
							    u.size, vq.c_str());
							if (++unc >= 32)
								break;
						}
						// p5 launch227: stash the diffuse bound to a gbuffer draw —
						// read back at present to split "texture content dead" vs
						// "sampling/write dead".
						if (strstr(pn, "deffer_base_flat") && pm.stageTex[0])
							pm.pendingDefferTex = pm.stageTex[0];
						// p5 launch231: sun material volume (probe showed
						// 128x256 z4 — X-Ray's is 128x256x16 BC1) — out =
						// Ldynamic_color * MAT * avg4(smap): if MAT samples
						// zero, the sun writes zero. Read its content back.
						if (strstr(pn, "accum_sun") && pm.stageTex[2])
							pm.pendingMatTex = pm.stageTex[2];
						// p5 launch232: is the SAMPLED smap_depth content
						// alive? (engine probes say whether the sun shadow
						// phase runs; this says what the taps actually read.)
						if (strstr(pn, "accum_sun") && pm.stageTex[3])
							pm.pendingSmapTex = pm.stageTex[3];
					}
					// half-float content of slot 0 + every PS CB float so the
					// Inf-scene vs junk-constant theory splits cleanly.
					static int s_ppRaw = 0;
					// p5 launch219: fires every gated pass (s_ppPass %240) —
					// launch216's inner %480 double-counter meant this NEVER
					// ran at steady state (advanced only 2/480 draws).
					if (s_ppRaw++ < 200)
					{
						// Read whichever slot holds the scene HDR RT
						// ($user$albedo): PP slot0 / combine_1 s_diffuse.
						void* rawTex = nullptr;
						for (int si = 0; si < 8; si++)
						{
							const char* sn = MtlDbgRTGetName(pm.stageTex[si]);
							if (pm.stageTex[si] && sn && !strcmp(sn, "$user$albedo"))
							{
								rawTex = pm.stageTex[si];
								break;
							}
						}
						if (rawTex)
						{
						id<MTLTexture> t0 = (__bridge id<MTLTexture>)rawTex;
						const uint32_t rw = t0.width, rh = t0.height;
						const uint32_t fmt = (uint32_t)t0.pixelFormat;
						// launch219 enum fix: 80=BGRA8 (NOT half!). Half RTs
						// are 115 (RGBA16Float) / 125 (RGBA32Float).
						const uint32_t bpp = (fmt == 115u) ? 8u : (fmt == 125u) ? 16u : 4u;
						const size_t bpr = size_t(rw) * bpp, sz = bpr * rh;
						std::vector<uint8_t> px(sz);
						id<MTLDevice> mdev = (__bridge id<MTLDevice>)MtlSharedDevice();
						id<MTLBuffer> rb = mdev ? [mdev newBufferWithLength:sz
						                                          options:MTLResourceStorageModeShared]
						                        : nil;
						id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)pm.dev->Queue();
						id<MTLCommandBuffer> cb = q ? [q commandBuffer] : nil;
						bool got = false;
						if (rb && cb)
						{
							id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
							[be copyFromTexture:t0
							          sourceSlice:0
							          sourceLevel:0
							         sourceOrigin:MTLOriginMake(0, 0, 0)
							           sourceSize:MTLSizeMake(rw, rh, 1)
							             toBuffer:rb
							      destinationOffset:0
							 destinationBytesPerRow:bpr
							destinationBytesPerImage:sz];
							[be endEncoding];
							[cb commit];
							[cb waitUntilCompleted];
							memcpy(px.data(), rb.contents, sz);
							got = true;
						}
						if (got)
						{
							size_t nanCnt = 0, infCnt = 0, bigCnt = 0, n = 0, nzCnt = 0;
							float mn = 1e30f, mx = -1e30f;
							float chMax[3] = { -1e30f, -1e30f, -1e30f };
							float midv[3] = { 0, 0, 0 };
							if (bpp == 8)
							{
								const _Float16* hp = (const _Float16*)px.data();
								for (size_t k = 0; k < size_t(rw) * rh; k += 37)
								{
									bool anynz = false;
									for (int c = 0; c < 3; c++)
									{
										float f = (float)hp[k * 4 + c];
										if (std::isnan(f))
										{
											nanCnt++;
											continue;
										}
										if (std::isinf(f))
										{
											infCnt++;
											continue;
										}
										if (std::fabs(f) > 1000.f)
											bigCnt++;
										if (f > chMax[c])
											chMax[c] = f;
										if (f < mn)
											mn = f;
										if (f > mx)
											mx = f;
										if (f != 0.f)
											anynz = true;
									}
									if (anynz)
										nzCnt++;
									n++;
								}
								size_t mp = (size_t(rh / 2) * rw + rw / 2) * 4;
								midv[0] = (float)hp[mp];
								midv[1] = (float)hp[mp + 1];
								midv[2] = (float)hp[mp + 2];
							}
							else if (bpp == 4)
							{
								const uint8_t* bp2 = px.data();
								for (size_t k = 0; k < size_t(rw) * rh; k += 37)
								{
									bool anynz = false;
									for (int c = 0; c < 3; c++)
									{
										const float f = bp2[k * 4 + c] / 255.f;
										if (f > chMax[c])
											chMax[c] = f;
										if (f < mn)
											mn = f;
										if (f > mx)
											mx = f;
										if (f != 0.f)
											anynz = true;
									}
									if (anynz)
										nzCnt++;
									n++;
								}
								size_t mp = (size_t(rh / 2) * rw + rw / 2) * 4;
								midv[0] = bp2[mp] / 255.f;
								midv[1] = bp2[mp + 1] / 255.f;
								midv[2] = bp2[mp + 2] / 255.f;
							}
							Log("* p5 ppraw: pair=%s era=%d slot0 f%u %ux%u n=%zu nz=%zu nan=%zu inf=%zu big=%zu "
							    "rng=[%.4g,%.4g] chmax=(%.4g,%.4g,%.4g) mid=(%.5g,%.5g,%.5g)",
							    pn, g_ppEra,
							    (unsigned)t0.pixelFormat, rw, rh, n, nzCnt, nanCnt, infCnt, bigCnt, mn, mx,
							    chMax[0], chMax[1], chMax[2], midv[0], midv[1], midv[2]);
						}
						else
							Log("* p5 ppraw: readback failed");
						}
						if (psR)
							for (const auto& u : psR->uniforms)
								if (u.offset + 16 <= pm.psSize)
								{
									float q[4];
									std::memcpy(q, pm.staging.data() + Align16(pm.vsSize) + u.offset,
									    16);
									Log("* p5 ppcb: %s off=%u (%.4g %.4g %.4g %.4g)", u.name.c_str(),
									    u.offset, q[0], q[1], q[2], q[3]);
								}
					}
				}
				// p5 launch212: every draw whose color attachment 0 is base_0 —
				// catch the writer of the solid-yellow backbuffer.
				if (pm.rt[0])
				{
					const char* rtn = MtlDbgRTGetName(pm.rt[0]);
					if (rtn && 0 == strcmp(rtn, "$user$base_0"))
					{
						static std::map<std::string, int> s_b0;
						std::string k = pn ? pn : "?";
						if (s_b0[k]++ < 5)
							Log("* p5 b0draw: pair=%s idx=%u n=%u", k.c_str(), 0u, 0u);
					}
				}
				int cfCount = 0;
				for (int i = 0; i < 4; i++)
					if (pm.rt[i])
						cfCount++;
				// FFP matrix values actually uploaded for this draw (DX11-arch
				// xforms arrive via m_W/m_V/m_P/m_WVP constants).
				const float* mw = nullptr;
				const float* mv = nullptr;
				const float* mp = nullptr;
				const float* mwvp = nullptr;
				int wvpOff = -2, wvpDup = 0, wvpSeen = 0;
				for (const auto& u : vsR->uniforms)
				{
					if (u.name == "m_WVP")
					{
						wvpSeen++;
						if (u.offset + 64 <= pm.vsSize)
						{
							if (!mwvp)
							{
								mwvp = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
								wvpOff = (int)u.offset;
							}
							wvpDup++;
						}
					}
					else if (u.name == "m_W" && u.offset + 64 <= pm.vsSize && !mw)
						mw = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
					else if (u.name == "m_V" && u.offset + 64 <= pm.vsSize && !mv)
						mv = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
					else if (u.name == "m_P" && u.offset + 64 <= pm.vsSize && !mp)
						mp = reinterpret_cast<const float*>(pm.staging.data() + u.offset);
				}
				uint32_t dbgRW = 0, dbgRH = 0; // p6: live RT dims (black-band hunt)
				if (pm.rt[0] && pm.dev)
					pm.dev->TextureDims(pm.rt[0], &dbgRW, &dbgRH);
				Log("* p5 scenecolor: pair=%s named=%s rt=(%p,%p,%p,%p) rtWH=%ux%u zb=%p cf=%d mask=%X bl=%d "
				    "zE=%d zF=%d vp=(%.0f,%.0f,%.0fx%.0f) sc=%d(%d,%d,%d,%d) pt=%u n=%u idx=%d "
				    "vsSize=%u wvpSeen=%d wvpIn=%d wvpOff=%d "
				    "mWVP=(%.2f %.2f %.2f %.2f|%.2f %.2f %.2f %.2f) "
				    "mWVP2=(%.2f %.2f %.2f %.2f) mWVP3=(%.2f %.2f %.2f %.2f) mW0=(%.2f %.2f %.2f %.2f) "
				    "mW3=(%.2f %.2f %.2f %.2f) "
				    "mV0=(%.2f %.2f %.2f %.2f) mP0=(%.2f %.2f %.2f %.2f) "
				    "mP1=(%.2f %.2f %.2f %.2f) mP2=(%.2f %.2f %.2f %.2f) "
				    "mP3=(%.2f %.2f %.2f %.2f) "
				    "mVh=(%.5f %.5f %.5f %.5f|%.5f %.5f %.5f %.5f) pres=%llu",
				    pn, n0, pm.rt[0], pm.rt[1], pm.rt[2], pm.rt[3], dbgRW, dbgRH, pm.zb, cfCount,
				    (unsigned)pm.blend.writeMask, (int)pm.blend.enabled, (int)pm.depthEn, pm.depthFunc,
				    pm.vpX, pm.vpY, pm.vpW, pm.vpH, pm.scissorEn, pm.scL, pm.scT, pm.scR, pm.scB,
				    topology, primCount, indexed,
				    pm.vsSize, wvpSeen, wvpDup, wvpOff,
				    mwvp ? mwvp[0] : 9e9f, mwvp ? mwvp[1] : 9e9f, mwvp ? mwvp[2] : 9e9f,
				    mwvp ? mwvp[3] : 9e9f, mwvp ? mwvp[4] : 9e9f, mwvp ? mwvp[5] : 9e9f,
				    mwvp ? mwvp[6] : 9e9f, mwvp ? mwvp[7] : 9e9f,
				    mwvp ? mwvp[8] : 9e9f, mwvp ? mwvp[9] : 9e9f, mwvp ? mwvp[10] : 9e9f,
				    mwvp ? mwvp[11] : 9e9f, mwvp ? mwvp[12] : 9e9f, mwvp ? mwvp[13] : 9e9f,
				    mwvp ? mwvp[14] : 9e9f, mwvp ? mwvp[15] : 9e9f,
				    mw ? mw[0] : 9e9f, mw ? mw[1] : 9e9f, mw ? mw[2] : 9e9f, mw ? mw[3] : 9e9f,
				    mw ? mw[12] : 9e9f, mw ? mw[13] : 9e9f, mw ? mw[14] : 9e9f,
				    mw ? mw[15] : 9e9f,
				    mv ? mv[0] : 9e9f, mv ? mv[1] : 9e9f, mv ? mv[2] : 9e9f, mv ? mv[3] : 9e9f,
				    mp ? mp[0] : 9e9f, mp ? mp[1] : 9e9f, mp ? mp[2] : 9e9f, mp ? mp[3] : 9e9f,
				    mp ? mp[4] : 9e9f, mp ? mp[5] : 9e9f, mp ? mp[6] : 9e9f, mp ? mp[7] : 9e9f,
				    mp ? mp[8] : 9e9f, mp ? mp[9] : 9e9f, mp ? mp[10] : 9e9f, mp ? mp[11] : 9e9f,
				    mp ? mp[12] : 9e9f, mp ? mp[13] : 9e9f, mp ? mp[14] : 9e9f, mp ? mp[15] : 9e9f,
				    mv ? mv[0] : 9e9f, mv ? mv[1] : 9e9f, mv ? mv[2] : 9e9f, mv ? mv[3] : 9e9f,
				    mv ? mv[4] : 9e9f, mv ? mv[5] : 9e9f, mv ? mv[6] : 9e9f, mv ? mv[7] : 9e9f,
				    (unsigned long long)g_mtlPresentCount);
			}
		}
		// p6 band-hunt: XR_METAL_REPLAY — remember the biggest position-pass
		// draw (engine VB/IB + engine WVP bytes) for the pass-end replay draw.
		// wvp14: capture only after the verified in-game gate — the old budget
		// burned all 3 replays during the load screen. wvp18: gate 6000 (MCP
		// frame == presents; load ends ~3500) — under the ~frame-9500 freeze.
		{
			static const bool s_rpen = !!getenv("XR_METAL_REPLAY");
			if (s_rpen && indexed && ds.vb && ds.ib && vsR && !pm.staging.empty() &&
			    primCount >= 200 && g_mtlPresentCount > 6000)
			{
				const char* rn = pm.rt[0] ? MtlDbgRTGetName(pm.rt[0]) : nullptr;
				if (rn && strstr(rn, "position"))
					for (const auto& u : vsR->uniforms)
						if (u.name == "m_WVP" && u.offset + 64 <= pm.vsSize)
						{
							const float* m = reinterpret_cast<const float*>(
							    pm.staging.data() + u.offset);
							// CPU front test on sampled vertices: only capture
							// draws whose geometry actually faces the camera.
							const uint16_t* i16 =
							    (const uint16_t*)[(__bridge id<MTLBuffer>)ds.ib
							                              contents] +
							    startI;
							const uint8_t* vbB = (const uint8_t*)
							    [(__bridge id<MTLBuffer>)ds.vb contents];
							unsigned nFr = 0;
							for (uint32_t k = 0; k < primCount * 3; k += 17)
							{
								const float* q = (const float*)(vbB +
								    size_t((uint32_t)i16[k] + baseV) * ds.vbStride);
								if (q[0] * m[3] + q[1] * m[7] + q[2] * m[11] +
								        m[15] >
								    0.01f)
									nFr++;
							}
							if (nFr > g_rpFront)
							{
								g_rpFront = nFr;
								std::memcpy(g_rpWvp, m, 64);
								g_rpVb = ds.vb;
								g_rpIb = ds.ib;
								g_rpStride = ds.vbStride;
								g_rpStartI = startI;
								g_rpBaseV = baseV;
								g_rpPrimCnt = primCount;
								g_rpOk = true;
							}
							break;
						}
			}
		}
		g_dbgDrawOK++;
		(void)imgSize;
		return true;
	}
} // namespace

void MtlDrawIndexed(uint32_t topology, uint32_t indexCount, uint32_t startI, uint32_t baseV,
                    const MtlDrawState& ds)
{
	EmitDraw(PM(), ds, topology, indexCount, startI, baseV, 0, true);
}

void MtlDrawArrays(uint32_t topology, uint32_t startV, uint32_t indexCount, const MtlDrawState& ds)
{
	EmitDraw(PM(), ds, topology, indexCount, 0, 0, startV, false);
}

// --- occlusion queries (v1: conservative) ------------------------------------------
namespace
{
	struct MtlQuery
	{
		uint64_t result;
	};
}

void* MtlCreateOcclusionQuery()
{
	MtlQuery* q = new MtlQuery{ 0 };
	return q;
}

void MtlReleaseOcclusionQuery(void* query)
{
	delete (MtlQuery*)query;
}

void MtlBeginOcclusionQuery(void*) { }
void MtlEndOcclusionQuery(void*) { }

int32_t MtlGetQueryDataStatus(void* query, void* data, uint32_t dataSize)
{
	// launch177 post-mortem: returning S_FALSE forever made r__occlusion's
	// GetData loop spin 500 ms per query; smapvis flushoccq issues hundreds
	// per frame -> multi-minute stall -> engine exception termination
	// (~1 min after level load, launches 175/177). Answer READY with 1
	// fragment = nothing occlusion-culled (conservative, same intent as the
	// v1 stub). Real MTLCounterSampleBuffer resolution still lands with p5 t3.
	if (!query || !data || dataSize < 4)
		return 2; // E_FAIL
	*(uint32_t*)data = 1;
	return 0; // S_OK — data ready
}
} // namespace xray::render::RENDER_NAMESPACE
