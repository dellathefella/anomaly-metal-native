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
#import <QuartzCore/CAMetalLayer.h>

#include "mtlRuntime.h"
#include "mtlShader.h"
#include "mtl_dx9_map.h"
#include "mtl_device.h"
#include "mtl_state.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
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

// p5 diag: draw-path counters (read via MtlDbgDrawStats from CHW::Present).
static uint64_t g_dbgDrawOK = 0, g_dbgDrawNoShader = 0, g_dbgDrawNoPso = 0;
// p5 diag: entry + silent-exit counters (EmitDraw returns false without these
// counters on some paths; scene-draw starvation hunt).
static uint64_t g_dbgDrawEnter = 0, g_dbgDrawNoCb = 0, g_dbgDrawNoEnc = 0, g_dbgDrawNoIb = 0;
// p5 diag: silent-exit hunt round 2 — fanVerts<3 drops + per-topology arrivals.
static uint64_t g_dbgFanDrop = 0, g_dbgFanOK = 0;
static uint64_t g_dbgEncoders = 0, g_dbgRtSwitches = 0;
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
@end

static void MtlInstallValidationGuard()
{
	if (!getenv("MTL_DEBUG_LAYER"))
		return;
	static BOOL s_done = NO;
	if (s_done)
		return;
	s_done = YES;
	MtlLogAssertionHandler* h = [MtlLogAssertionHandler new]; // process-lifetime
	NSThread* t = [NSThread currentThread];
	[[t threadDictionary] setObject:h forKey:NSAssertionHandlerKey];
	Log("- xrMetal: validation-continue assertion handler installed (render thread)");
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
)metal";

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

		// Constants
		std::vector<uint8_t> staging;
		uint32_t vsSize = 0, psSize = 0, psBase = 0;
		id<MTLBuffer> ring = nil;
		uint64_t ringOff = 0;

		// Presentation bookkeeping
		id<MTLTexture> lastDrawable = nil;

		// p5 DIAG (launch102): position RT whose pass just ended (postgeom readback)
		void* pendingPostGeom = nullptr;

		// Built-ins
		id<MTLFunction> blitVs = nil, blitPs = nil, fillPs = nil;
		std::map<uint32_t, id<MTLRenderPipelineState>> blitPso; // key: (dstFmt<<1|fill)
		std::map<uint32_t, id<MTLRenderPipelineState>> fillZPso; // depth-rect fills

		void initBuiltins();
		void endEncoder();
		void ensureEncoder();
		void applyEncoderState();
		void markTouched();
		id<MTLRenderPipelineState> blitPipeline(MTLPixelFormat fmt, bool fillMode, bool depthPass,
	                                        int dfmt = 0);
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
	}

	void MtlPassManager::endEncoder()
	{
		if (enc)
		{
			[enc endEncoding];
			enc = nil;
			markTouched();
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
		if (pendingPostGeom && cb)
		{
			void* pg = pendingPostGeom;
			pendingPostGeom = nullptr;
			// launch139: window covers TWO consecutive position pass-ends
			// (5 and 6). launch138 verdict: the frame runs the position pass
			// twice (main model + rain) and the main/rain PARITY flips with
			// weather state — launch137's single-parity window (gate 5) hit
			// the main pass, launch138's hit the rain pass for 40 windows
			// straight (skip ps=rain_apply_*), so canaryI captured nothing
			// and the append block never ran (L=0 regression was an
			// instrument artifact, not an engine change). One of gates
			// 5/6 is always the main pass; deffer draws only happen there.
			const int g5 = ++g_pgGate % 240;
			if (g5 == 5 || g5 == 6) // launch131: 1 readback window/240 (was 7 —
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
							pdF.colorFormats.push_back((int)atex.pixelFormat);
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
							[e4 setRenderPipelineState:ap.s4Pso];
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
					    "T0=%zu T1=%zu mid=(%u,%u,%u,%u) tick=%d",
					    nz, nL, nV, nW, nX, nZ, nU, nT0, nT1, px[mid], px[mid + 1], px[mid + 2],
					    px[mid + 3], g_pgGate % 240);
				}
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
						size_t wnLo = 0, wnMid = 0, wnHi = 0, wpLo = 0, wpMid = 0, wpHi = 0;
						for (size_t k = 0; k + 2 < sx3.size(); k += 4)
						{
							const uint8_t* p = sx3.data() + k;
							if (p[0] < 100 || p[0] > 180)
								continue; // not a clipps pixel (B=0.5 marker)
							bool wneg = p[2] < 100;
							size_t* slot = wneg ? (p[1] < 64 ? &wnLo
							                      : p[1] > 191 ? &wnHi
							                                   : &wnMid)
							                    : (p[1] < 64 ? &wpLo
							                      : p[1] > 191 ? &wpHi
							                                   : &wpMid);
							(*slot)++;
						}
						Log("- p5 canaryI: S4clip wNeg[z/w lo,mid,hi]=%zu,%zu,%zu "
						    "wPos[z/w lo,mid,hi]=%zu,%zu,%zu",
						    wnLo, wnMid, wnHi, wpLo, wpMid, wpHi);
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
		if (zb)
		{
			id<MTLTexture> tex = (__bridge id<MTLTexture>)zb;
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
		attColorCount = 0;
		for (int i = 0; i < 4; i++)
		{
			id<MTLTexture> t = rpd.colorAttachments[i].texture;
			attColorFmt[i] = t ? (int)t.pixelFormat : 0;
			if (t)
				attColorCount++;
		}
		attDepthFmt = rpd.depthAttachment.texture ? (int)rpd.depthAttachment.texture.pixelFormat : 0;
		MtlInstallValidationGuard(); // render-thread first encoder
		enc = [cb renderCommandEncoderWithDescriptor:rpd];
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
		if (scissorEn)
		{
			const MTLScissorRect r{ (NSUInteger)scL, (NSUInteger)scT, (NSUInteger)(scR - scL),
				                    (NSUInteger)(scB - scT) };
			[enc setScissorRect:r];
		}
		DepthStencilDesc ds;
		ds.depthEnable = depthEn;
		ds.depthFunc = depthFunc;
		ds.depthWrite = depthWrite;
		ds.stencilEnable = stencilEn;
		ds.readMask = stMask;
		ds.writeMask = stWMask;
		ds.func = stFunc;
		ds.failOp = stFail;
		ds.passOp = stPass;
		ds.zFailOp = stZFail;
		id<MTLDepthStencilState> dss = (__bridge id<MTLDepthStencilState>)cache->DepthStateFull(dev->Device(), ds);
		if (dss)
			[enc setDepthStencilState:dss];
		[enc setStencilReferenceValue:stRef];
		// DX9/D3D convention: front faces clockwise (the engine's UI quads
		// are authored for the Y-flipping 2D ortho, and stub_notransform_t
		// reproduces that flip, so CW is front for every DX9-convention
		// draw). Cull mode maps from the recorded DX9 state alongside.
		// p5 DIAG (launch104): env overrides to test the winding-cull theory
		// on the live encoder without rebuilding per hypothesis.
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
		id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()]
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
			d.compareFunc = (int)MtlMapCompare(S.CompareFunc);
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
		pm.ring = (__bridge id<MTLBuffer>)device.NewBuffer(kRingSize);
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
	pm.ringOff = 0;
	pm.identityDirty = true;
}

void MtlFrameEnd()
{
	PM().endEncoder();
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
		if (pm.enc && on0 && strstr(on0, "position"))
			pm.pendingPostGeom = pm.rt[0];
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
static std::map<void*, std::string> g_mtlRtNames;
void MtlDbgRTName(void* tex, const char* name)
{
	if (tex && name)
		g_mtlRtNames[tex] = name;
}
const char* MtlDbgRTGetName(void* tex)
{
	auto it = g_mtlRtNames.find(tex);
	return it != g_mtlRtNames.end() ? it->second.c_str() : "?";
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
		if (cn && (strstr(cn, "position") || strstr(cn, "albedo") || strstr(cn, "accum")))
		{
			static std::map<std::string, int> s_ccN;
			if (s_ccN[cn]++ < 8)
				Log("- p5 clearcolor: %s (%g,%g,%g,%g)", cn, r, g, b, a);
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
	// Fast path: exact size + format -> blit encoder.
	if (srcW == dstW && srcH == dstH && src.pixelFormat == dst.pixelFormat)
	{
		pm.dev->BlitTexture((__bridge void*)pm.cb, srcTex, dstTex);
		return;
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
void MtlSetViewport(float x, float y, float w, float h, float minD, float maxD)
{
	MtlPassManager& pm = PM();
	pm.vpX = x;
	pm.vpY = y;
	pm.vpW = w;
	pm.vpH = h;
	pm.vpMin = minD;
	pm.vpMax = maxD;
	if (pm.enc)
	{
		const MTLViewport vp{ x, y, w, h, minD, maxD };
		[pm.enc setViewport:vp];
	}
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
	(void)size;
}

// --- texture stages ---------------------------------------------------------------
void MtlRecordTextureStage(uint32_t stage, void* texture)
{
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
			[e setFragmentBuffer:pm.ring offset:slotOff atIndex:0];
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

	bool EmitDraw(MtlPassManager& pm, const MtlDrawState& ds, uint32_t topology, uint32_t primCount,
	              uint32_t startI, uint32_t baseV, uint32_t startV, bool indexed)
	{
		g_dbgDrawEnter++;
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

		// Constants snapshot
		uint64_t slotOff = 0;
		size_t imgSize = 0;
		if (pm.ring && (pm.vsSize || pm.psSize))
		{
			const uint32_t psBase = Align16(pm.vsSize);
			imgSize = psBase + Align16(pm.psSize);
			if (pm.ringOff + imgSize > kRingSize)
				pm.ringOff = 0; // wrap (bounded by per-frame commit; v1 policy)
			slotOff = pm.ringOff;
			uint8_t* dst = (uint8_t*)[pm.ring contents] + slotOff;
			std::memcpy(dst, pm.staging.data(), imgSize);
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
				if (rtNcH && strstr(rtNcH, "position") &&
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
			[pm.enc drawIndexedPrimitives:pt
			                   indexCount:primCount
			                    indexType:MTLIndexTypeUInt16
			                  indexBuffer:(__bridge id<MTLBuffer>)ds.ib
			            indexBufferOffset:(NSUInteger)startI * 2
			                  instanceCount:1
			                     baseVertex:(NSInteger)baseV
			                   baseInstance:0];
		}
		else
			[pm.enc drawPrimitives:pt vertexStart:startV vertexCount:primCount];
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
			if (rtNc && strstr(rtNc, "position") && (g_pgGate + 1) % 240 == 0 &&
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
			if (rtNc && strstr(rtNc, "position") && indexed && ds.vb && ds.ib &&
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
					if (pm.rt[0])
						pdB.colorFormats.push_back(pm.dev->TextureFormat(pm.rt[0]));
					// launch111: the REAL geometry PSO declares cf=[pos,albedo].
					// Build the fill probe with the same 2-attachment config:
					// magenta dies => 2-attachment PSO config is the killer;
					// lands => PSO config innocent, only the real PS differs.
					if (pm.rt[1])
						pdB.colorFormats.push_back(pm.dev->TextureFormat(pm.rt[1]));
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
					if (pm.rt[0])
						pdI.colorFormats.push_back(pm.dev->TextureFormat(pm.rt[0]));
					// launch128: NO depth format -> the pass-end append encoder
					// attaches only the position RT; the in-pass draw ignores the
					// (present but PSO-unbound) depth attachment.
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
							static id<MTLFunction> s_clipFn, s_cyanFn, s_redFn, s_mgnFn, s_ylwFn;
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
								                       "0.5, clamp(zw * 0.5 + 0.5, 0.0, "
								                       "1.0), 0.5, 1.0);\n"
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
							}
							if (f7 && s_clipFn)
							{
								PipelineDesc pd7 = pdI;
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
						}
							if (f5 && s_cyanFn)
							{
								PipelineDesc pd5 = pdI;
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
			static std::map<std::string, int> s_scLogged;
			if (n0 && s_scLogged[pn]++ < 6)
			{
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
				Log("* p5 scenecolor: pair=%s named=%s rt=(%p,%p,%p,%p) zb=%p cf=%d mask=%X bl=%d "
				    "zE=%d zF=%d vp=(%.0f,%.0f,%.0fx%.0f) sc=%d(%d,%d,%d,%d) pt=%u n=%u idx=%d "
				    "vsSize=%u wvpSeen=%d wvpIn=%d wvpOff=%d "
				    "mWVP=(%.2f %.2f %.2f %.2f|%.2f %.2f %.2f %.2f) "
				    "mWVP2=(%.2f %.2f %.2f %.2f) mWVP3=(%.2f %.2f %.2f %.2f) mW0=(%.2f %.2f %.2f %.2f) "
				    "mW3=(%.2f %.2f %.2f %.2f) "
				    "mV0=(%.2f %.2f %.2f %.2f) mP0=(%.2f %.2f %.2f %.2f)",
				    pn, n0, pm.rt[0], pm.rt[1], pm.rt[2], pm.rt[3], pm.zb, cfCount,
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
				    mp ? mp[0] : 9e9f, mp ? mp[1] : 9e9f, mp ? mp[2] : 9e9f, mp ? mp[3] : 9e9f);
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
	// v1: always pending -> callers treat as "occluded unknown" and DRAW
	// (QueryHelper contract: S_FALSE = not ready). Real MTLCounterSampleBuffer
	// resolution lands with p5 t3.
	if (!query || !data || dataSize < 4)
		return 2; // E_FAIL
	*(uint32_t*)data = 1;
	return 1; // S_FALSE
}
} // namespace xray::render::RENDER_NAMESPACE
