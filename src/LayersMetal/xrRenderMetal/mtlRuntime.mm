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
			if (++g_pgGate % 240 < 5) // launch110: read canaryG(0)/vscanary(1)/H2(2)/H3(3)/canaryI(4)
			{
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
					size_t nz = 0;
					for (size_t k = 0; k + 4 <= px.size(); k += 64)
						if (px[k] | px[k + 1] | px[k + 2])
							nz++;
					const size_t mid = (size_t(h / 2) * w + w / 2) * 4;
					Log("- p5 postgeom: position nz=%zu mid=(%u,%u,%u,%u) tick=%d", nz, px[mid],
					    px[mid + 1], px[mid + 2], px[mid + 3], g_pgGate % 240);
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
		switch (d3dType)
		{
		case 0: return 53; // FLOAT16 -> Half
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
		case 11: return 20; // USHORT2N -> UShort2Normalized
		case 12: return 21; // USHORT4N -> UShort4Normalized
		case 15: return 25; // FLOAT16_2 -> Half2
		case 16: return 27; // FLOAT16_4 -> Half4
		default: return 30; // Float3 fallback
		}
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
			// launch125: capture a REAL DEFER pair only (launch124 captured a rain
			// shader whose PS has no TEXCOORD1 => passthru fell back to magenta yet
			// readback was zero — rain geometry may not cover; verdict unreliable).
			const bool defferI = psR->name.find("deffer") != std::string::npos &&
			                     psR->msl.find("in_var_TEXCOORD1") != std::string::npos &&
			                     vsR->msl.find("m_WVP") != std::string::npos;
			if (!defferI)
			{
				static int s_skipI = 0;
				if (s_skipI++ < 12)
					Log("- p5 canaryI: skip non-deffer ps=%s", psR->name.c_str());
			}
			if (defferI && rtNcI && strstr(rtNcI, "position") && indexed && ds.vb && ds.ib &&
			    (g_pgGate + 1) % 240 == 4 && g_dbgDrawOK - s_lastI > 50000ull)
			{
				s_lastI = g_dbgDrawOK;
				// launch111 FIX: build the passthru PS from the LIVE pair's
				// ALIGNED main0_in struct (hardcoded struct mismatched the live
				// VS: "Fragment input(s) user(locn1..3) mismatching").
				id<MTLFunction> fnI = nil;
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
							retExpr =
								"float4(any(in.in_var_TEXCOORD0 != float2(0.0)) ? 1.0 : 0.0, "
								"any(in.in_var_TEXCOORD1 != float4(0.0)) ? 1.0 : 0.0, 0.0, 1.0)";
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
					MtlPdDepthFromEncoder(pm, pdI); // RC#5: match live rpd
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
						Log("- p5 canaryI: realVS+passthruPS encoded attrs=%d", (int)pdI.attrs.size());
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
