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
#include <map>
#include <set>
#include <string>
#include <vector>

// Host-side float4 (MTL vector types are device-only).
struct Float4
{
	float x, y, z, w;
};

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

namespace xray::render::RENDER_NAMESPACE
{
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

		// Built-ins
		id<MTLFunction> blitVs = nil, blitPs = nil, fillPs = nil;
		std::map<uint32_t, id<MTLRenderPipelineState>> blitPso; // key: (dstFmt<<1|fill)
		std::map<uint32_t, id<MTLRenderPipelineState>> fillZPso; // depth-rect fills

		void initBuiltins();
		void endEncoder();
		void ensureEncoder();
		void applyEncoderState();
		void markTouched();
		id<MTLRenderPipelineState> blitPipeline(MTLPixelFormat fmt, bool fillMode, bool depthPass);
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
			att.loadAction = touched.count(rt[i]) ? MTLLoadActionLoad : MTLLoadActionDontCare;
			att.storeAction = MTLStoreActionStore;
		}
		if (zb)
		{
			id<MTLTexture> tex = (__bridge id<MTLTexture>)zb;
			MTLRenderPassDepthAttachmentDescriptor* att = rpd.depthAttachment;
			att.texture = tex;
			att.loadAction = touched.count(zb) ? MTLLoadActionLoad : MTLLoadActionDontCare;
			att.storeAction = MTLStoreActionStore;
			if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
			{
				MTLRenderPassStencilAttachmentDescriptor* satt = rpd.stencilAttachment;
				satt.texture = tex;
				satt.loadAction = touched.count(zb) ? MTLLoadActionLoad : MTLLoadActionDontCare;
				satt.storeAction = MTLStoreActionStore;
			}
		}
		enc = [cb renderCommandEncoderWithDescriptor:rpd];
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
		[enc setFrontFacingWinding:MTLWindingClockwise]; // D3D convention
		[enc setCullMode:(MTLCullMode)MtlMapCull(cull)];
		[enc setTriangleFillMode:(MTLTriangleFillMode)MtlMapFillMode(fill)];
	}

	id<MTLRenderPipelineState> MtlPassManager::blitPipeline(MTLPixelFormat fmt, bool fillMode, bool depthPass)
	{
		initBuiltins();
		if (!blitVs || !blitPs)
			return nil;
		const uint32_t key = ((uint32_t)fmt << 2) | (fillMode ? 2u : 0u) | (depthPass ? 1u : 0u);
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
			pd.depthFormat = (int)fmt; // depth format == attachment
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

void MtlInvalidatePass()
{
	MtlPassManager& pm = PM();
	pm.endEncoder();
	pm.identityDirty = true;
}

// --- targets -----------------------------------------------------------------
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
	for (int i = 0; i < 4; i++)
		pm.rt[i] = rts ? rts[i] : nullptr;
	pm.zb = (void*)zb;
	pm.identityDirty = true;
}

// --- clears ------------------------------------------------------------------
void MtlClearColor(void* rt, float r, float g, float b, float a)
{
	MtlPassManager& pm = PM();
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
	id<MTLRenderPipelineState> ResolvePipeline(MtlPassManager& pm, const MtlStageRefl& vsRefl,
	                                          const MtlStageRefl& psRefl, uint32_t stride,
	                                          const MtlShaderPair* pairName)
	{
		PipelineDesc pd;
		pd.vs = vsRefl.function;
		pd.ps = psRefl.function;
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

		// Pass attachment formats
		for (int i = 0; i < 4; i++)
			if (pm.rt[i])
				pd.colorFormats.push_back(pm.dev->TextureFormat(pm.rt[i]));
		if (pd.colorFormats.empty())
			pd.colorFormat = -1; // depth-only pass
		if (pm.zb)
		{
			const int zf = pm.dev->TextureFormat(pm.zb);
			if (zf == 253) // Depth32Float_Stencil8
				pd.stencilFormat = zf;
			else
				pd.depthFormat = zf;
		}
		pd.blend = pm.blend;

		std::string error;
		id<MTLRenderPipelineState> pso =
			(__bridge id<MTLRenderPipelineState>)pm.cache->Pipeline(pm.dev->Device(), pd, error);
		if (!pso)
		{
			static int s_logged = 0;
			if (s_logged++ < 12)
				Log("! xrRenderMetal: PSO failed (%s): %s", pairName ? pairName->name.c_str() : "?",
				    error.c_str());
		}
		return pso;
	}

	// Bind cbuffer snapshot + stage resources for both stages.
	void BindDraw(MtlPassManager& pm, id<MTLRenderCommandEncoder> e, const MtlStageRefl& vsRefl,
	              const MtlStageRefl& psRefl, uint64_t slotOff)
	{
		if (pm.ring)
		{
			[e setVertexBuffer:pm.ring offset:slotOff atIndex:0];
			[e setFragmentBuffer:pm.ring offset:slotOff atIndex:0];
		}
		auto bindStage = [&](bool fragment, const MtlStageRefl& refl) {
			for (const auto& r : refl.resources)
			{
				if (r.isSamplerOnly)
					continue;
				const uint32_t slot = r.textureSlot;
				void* tex = slot < kMaxStage ? pm.stageTex[slot] : nullptr;
				if (tex)
				{
					if (fragment)
						[e setFragmentTexture:(__bridge id<MTLTexture>)tex atIndex:slot];
					else
						[e setVertexTexture:(__bridge id<MTLTexture>)tex atIndex:slot];
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
		if (!pm.dev || !pm.cb)
			return false;
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
		if (!vsR || !psR || !vsR->function || !psR->function)
			return false; // null/failed shader: skip draw (GL bound program 0)

		pm.ensureEncoder();
		if (!pm.enc)
			return false;

		id<MTLRenderPipelineState> pso = ResolvePipeline(pm, *vsR, *psR, ds.vbStride, pair);
		if (!pso)
			return false;
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

		BindDraw(pm, pm.enc, *vsR, *psR, slotOff);

		const MTLPrimitiveType pt = (MTLPrimitiveType)topology; // 0..4 == Metal order
		if (topology > 4)
		{
			static int s_fan_logged = 0;
			if (s_fan_logged++ < 4)
				Log("! xrRenderMetal: triangle-fan draws unsupported (p5 t3)");
			return false;
		}
		if (indexed)
		{
			if (!ds.ib)
				return false;
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
