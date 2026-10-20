// metal_devicetest.mm — p5 t2 validation: resource/state substrate for the
// Metal renderer backend, on-device, offscreen (no window needed):
//   * MetalDevice factories: NewBuffer (vertex/index/constant), NewTexture2D,
//     WriteTexture upload, Sampler (nearest/linear, cached)
//   * MetalStateCache: pipeline cache keyed by (VS,PS,layout,depth,blend,fmt),
//     vertex descriptor -> SPIRV-Cross [[attribute(N)]] order
//   * full GPU data path: indexed draw, cbuffer b0 (wvp) + b1 (tint),
//     texture sampling, depth test, src-alpha blending — all asserted by
//     CPU readback of a 64x64 BGRA8 RT.
// Prints DEVICETEST_PASS when every check holds.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_device.h"
#include "mtl_shader_compiler.h"
#include "mtl_state.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifndef DXC_PATH
#define DXC_PATH "/Users/jdella/Desktop/anomaly-metal-native/repos/dxc/build-mac/bin/dxc"
#endif
#ifndef DXCOMPILER_PATH
#define DXCOMPILER_PATH "/Users/jdella/Desktop/anomaly-metal-native/repos/dxc/build-mac/lib/libdxcompiler.dylib"
#endif

static int g_failures = 0;

static void Check(bool cond, const char* what)
{
	if (cond)
		printf("[ok] %s\n", what);
	else
	{
		printf("FAIL: %s\n", what);
		g_failures++;
	}
}

// SM6-native HLSL; wvp is supplied as an identity matrix (vertices are NDC),
// tint comes from cbuffer b1; texture t0 sampled with s0.
static const char* kQuadHlsl = R"(
cbuffer Matrices : register(b0)
{
	float4x4 wvp;
};

cbuffer Material : register(b1)
{
	float4 tint;
};

struct VSIn
{
	float3 pos : POSITION;
	float2 uv : TEXCOORD0;
};

struct PSIn
{
	float4 pos : SV_Position;
	float2 uv : TEXCOORD0;
};

PSIn vs_main(VSIn i)
{
	PSIn o;
	o.pos = mul(wvp, float4(i.pos, 1.0));
	o.uv = i.uv;
	return o;
}

Texture2D<float4> t_diffuse : register(t0);
SamplerState smp : register(s0);

float4 ps_main(PSIn i) : SV_TARGET
{
	return t_diffuse.Sample(smp, i.uv) * tint;
}
)";

static id<MTLFunction> LoadFunction(id<MTLDevice> device, const std::string& msl, const char* name,
                                    const char* fallback)
{
	NSError* err = nil;
	id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:msl.c_str()] options:nil
	                                            error:&err];
	if (!lib)
	{
		printf("FAIL: newLibraryWithSource: %s\n", err.localizedDescription.UTF8String);
		return nil;
	}
	id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:name]];
	if (!fn)
		fn = [lib newFunctionWithName:[NSString stringWithUTF8String:fallback]];
	return fn;
}

// One vertex: pos(xyz) + uv(xy).
struct Vx
{
	float x, y, z, u, v;
};

static void FillQuad(std::vector<Vx>& out, float z)
{
	out = {{-1, -1, z, 0, 1}, {1, -1, z, 1, 1}, {1, 1, z, 1, 0}, {-1, 1, z, 0, 0}};
}

int main()
{
	setvbuf(stdout, nullptr, _IONBF, 0);
	@autoreleasepool
	{
		printf("== metal_devicetest: resource/state substrate ==\n");

		xray::metal::MetalDevice dev;
		std::string err;
		Check(dev.Create(err), "MetalDevice create");
		id<MTLDevice> device = (__bridge id<MTLDevice>)dev.Device();
		id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)dev.Queue();

		// --- shaders ---------------------------------------------------------
		xray::metal::MetalShaderCompiler comp;
		Check(comp.Init({DXCOMPILER_PATH}, DXC_PATH, "/tmp/xr_metal_devicetest_cache"), "shader compiler init");
		auto vs = comp.Compile(kQuadHlsl, "vs_main", xray::metal::ShaderStage::Vertex, false);
		auto ps = comp.Compile(kQuadHlsl, "ps_main", xray::metal::ShaderStage::Pixel, false);
		Check(vs.ok && ps.ok, "quad HLSL->MSL");
		if (!vs.ok || !ps.ok)
		{
			printf("  vs: %s\n  ps: %s\n", vs.error.c_str(), ps.error.c_str());
			return 2;
		}
		id<MTLFunction> vsFn = LoadFunction(device, vs.msl, "vs_main", "main0");
		id<MTLFunction> psFn = LoadFunction(device, ps.msl, "ps_main", "main0");
		Check(vsFn && psFn, "MSL functions loaded");
		if (!vsFn || !psFn)
			return 2;
		printf("[..] VS MSL buffer bindings:\n");
		{ // show the argument layout once (b0/b1 -> [[buffer(N)]] mapping)
			std::string s;
			for (char c : vs.msl)
			{
				s += c;
				if (c == '\n' && s.find("vertex") != std::string::npos && s.find("vs_main") != std::string::npos)
					break;
			}
			printf("     %s\n", s.c_str());
		}

		// --- resources -------------------------------------------------------
		const uint32_t RTW = 64, RTE = 64;
		void* rtTex = dev.NewTexture2D(RTW, RTE, 1, MTLPixelFormatBGRA8Unorm, false, true);
		void* depthTex = dev.NewTexture2D(RTW, RTE, 1, MTLPixelFormatDepth32Float, false, false);
		Check(rtTex && depthTex, "NewTexture2D: BGRA8 RT + Depth32F");

		// 8x8 RGBA8: TL red, TR green, BL blue, BR white
		uint8_t tex8[8 * 8 * 4];
		for (int y = 0; y < 8; y++)
			for (int x = 0; x < 8; x++)
			{
				uint8_t* p = tex8 + (y * 8 + x) * 4;
				const bool left = x < 4, top = y < 4;
				if (left && top) { p[0] = 255; p[1] = 0; p[2] = 0; }        // red
				else if (!left && top) { p[0] = 0; p[1] = 255; p[2] = 0; }  // green
				else if (left && !top) { p[0] = 0; p[1] = 0; p[2] = 255; }  // blue
				else { p[0] = 255; p[1] = 255; p[2] = 255; }                // white
				p[3] = 255;
			}
		void* samplerTex = dev.NewTexture2D(8, 8, 1, MTLPixelFormatRGBA8Unorm, false, true);
		Check(samplerTex != nullptr, "NewTexture2D: 8x8 RGBA8 sampler source");
		Check(dev.WriteTexture(samplerTex, tex8, 8, 8, err), "WriteTexture upload");

		std::vector<Vx> quad;
		FillQuad(quad, 0.0f);
		void* vb = dev.NewBuffer(sizeof(Vx) * quad.size());
		memcpy([(__bridge id<MTLBuffer>)vb contents], quad.data(), sizeof(Vx) * quad.size());
		std::vector<Vx> quadBlue, quadRed;
		FillQuad(quadBlue, 0.4f);
		FillQuad(quadRed, 0.6f);
		void* vbBlue = dev.NewBuffer(sizeof(Vx) * 4);
		memcpy([(__bridge id<MTLBuffer>)vbBlue contents], quadBlue.data(), sizeof(Vx) * 4);
		void* vbRed = dev.NewBuffer(sizeof(Vx) * 4);
		memcpy([(__bridge id<MTLBuffer>)vbRed contents], quadRed.data(), sizeof(Vx) * 4);
		const uint16_t idx[6] = {0, 1, 2, 0, 2, 3};
		void* ib = dev.NewBuffer(sizeof(idx));
		memcpy([(__bridge id<MTLBuffer>)ib contents], idx, sizeof(idx));
		Check(vb && ib && vbBlue && vbRed, "NewBuffer: vertex (x2 z-variants) + index");

		float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
		void* cbWvp = dev.NewBuffer(sizeof(identity));
		memcpy([(__bridge id<MTLBuffer>)cbWvp contents], identity, sizeof(identity));
		void* cbTint = dev.NewBuffer(16);
		Check(cbWvp && cbTint, "NewBuffer: constant (wvp + tint)");

		void* sampNearest = dev.Sampler(0, 0);
		void* sampLinear = dev.Sampler(0, 1);
		Check(sampNearest && dev.Sampler(0, 0) == sampNearest, "Sampler: cached (nearest==nearest)");

		// --- pipelines -------------------------------------------------------
		xray::metal::MetalStateCache states;
		xray::metal::PipelineDesc base;
		base.vs = (__bridge void*)vsFn;
		base.ps = (__bridge void*)psFn;
		base.stride = sizeof(Vx);
		base.vbSlot = 1; // slot 0 = DXC b0 (wvp) in the VS argument table
		base.attrs = {{0, 0, (uint32_t)MTLVertexFormatFloat3}, {1, 12, (uint32_t)MTLVertexFormatFloat2}};
		void* psoBase = states.Pipeline((__bridge void*)device, base, err);
		Check(psoBase != nullptr, "pipeline cache: base");
		if (!psoBase)
			printf("  err: %s\n", err.c_str());
		Check(states.Pipeline((__bridge void*)device, base, err) == psoBase && states.Count() == 1,
		      "pipeline cache: identical desc reuses PSO");

		xray::metal::PipelineDesc depthDesc = base;
		depthDesc.depthEnabled = true;
		depthDesc.depthWrite = true;
		depthDesc.depthFormat = MTLPixelFormatDepth32Float;
		void* psoDepth = states.Pipeline((__bridge void*)device, depthDesc, err);
		Check(psoDepth != nullptr && states.Count() == 2, "pipeline cache: depth variant distinct");

		xray::metal::PipelineDesc blendDesc = base;
		blendDesc.blendAlpha = true;
		void* psoBlend = states.Pipeline((__bridge void*)device, blendDesc, err);
		Check(psoBlend != nullptr && states.Count() == 3, "pipeline cache: blend variant distinct");
		Check(states.Pipeline((__bridge void*)device, base, err) == psoBase && states.Count() == 3,
		      "pipeline cache: base still cached");
		if (!psoBase || !psoDepth || !psoBlend)
			return 2;

		// --- render helper ----------------------------------------------------
		auto setTint = [cbTint](float r, float g, float b, float a)
		{
			float t[4] = {r, g, b, a};
			memcpy([(__bridge id<MTLBuffer>)cbTint contents], t, sizeof(t));
		};
		auto drawAgain = [&](id<MTLRenderCommandEncoder> enc, id<MTLBuffer> vbuf, id<MTLBuffer> tint)
		{
			[enc setVertexBuffer:vbuf offset:0 atIndex:1];
			[enc setFragmentBuffer:tint offset:0 atIndex:0];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16
			              indexBuffer:(__bridge id<MTLBuffer>)ib indexBufferOffset:0];
		};
		auto runPassSmp = [&](void* pso, id<MTLBuffer> vbuf, id<MTLSamplerState> smp) -> bool
		{
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = (__bridge id<MTLTexture>)rtTex;
			rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
			id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)pso];
			[enc setVertexBuffer:(__bridge id<MTLBuffer>)cbWvp offset:0 atIndex:0];
			[enc setVertexBuffer:vbuf offset:0 atIndex:1];
			[enc setFragmentTexture:(__bridge id<MTLTexture>)samplerTex atIndex:0];
			[enc setFragmentSamplerState:smp atIndex:0];
			[enc setFragmentBuffer:(__bridge id<MTLBuffer>)cbTint offset:0 atIndex:0];
			[enc setVertexBuffer:vbuf offset:0 atIndex:1];
			[enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16
			              indexBuffer:(__bridge id<MTLBuffer>)ib indexBufferOffset:0];
			[enc endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			return cb.error == nil;
		};

		uint8_t fb[RTW * RTE * 4];
		auto pixel = [&](uint32_t x, uint32_t y, uint8_t out[4])
		{
			out[0] = fb[(y * RTW + x) * 4 + 0];
			out[1] = fb[(y * RTW + x) * 4 + 1];
			out[2] = fb[(y * RTW + x) * 4 + 2];
			out[3] = fb[(y * RTW + x) * 4 + 3];
		};
		auto readback = [&]()
		{ return dev.Readback(rtTex, fb, RTW * 4, RTW, RTE, err); };

		// --- pass 1: NEAREST quadrant sampling (VB+IB+wvp+texture+sampler) ----
		setTint(1, 1, 1, 1);
		Check(runPassSmp(psoBase, (__bridge id<MTLBuffer>)vb, (__bridge id<MTLSamplerState>)sampNearest),
		      "pass1 draw (indexed, cbuffers, nearest sampler)");
		readback();
		uint8_t p[4];
		pixel(16, 16, p);
		Check(p[2] > 200 && p[0] < 40 && p[1] < 40, "nearest TL sample = red (R high)");
		pixel(48, 16, p);
		Check(p[1] > 200 && p[0] < 40 && p[2] < 40, "nearest TR sample = green");
		pixel(16, 48, p);
		Check(p[0] > 200 && p[1] < 40 && p[2] < 40, "nearest BL sample = blue");
		pixel(48, 48, p);
		Check(p[0] > 200 && p[1] > 200 && p[2] > 200, "nearest BR sample = white");

		// --- pass 2: tint cbuffer (b1) ----------------------------------------
		setTint(0, 0, 1, 1); // RGB tint -> white texel becomes blue
		Check(runPassSmp(psoBase, (__bridge id<MTLBuffer>)vb, (__bridge id<MTLSamplerState>)sampNearest), "pass2 draw");
		readback();
		pixel(48, 48, p);
		Check(p[0] > 200 && p[1] < 40 && p[2] < 40, "tint cbuffer applied (white x blue = blue)");
		setTint(1, 1, 1, 1);

		// --- pass 3: LINEAR filter differs from NEAREST at quadrant boundary --
		Check(runPassSmp(psoBase, (__bridge id<MTLBuffer>)vb, (__bridge id<MTLSamplerState>)sampLinear), "pass3 draw");
		readback();
		pixel(32, 16, p); // texel coord 3.56: linear blends red|green, nearest -> pure green
		bool blended = p[2] > 60 && p[2] < 200 && p[1] > 60 && p[1] < 200 && p[0] < 40;
		Check(blended, "linear sampler blends across texel boundary (nearest would not)");
		printf("      boundary pixel BGRA %u %u %u %u\n", p[0], p[1], p[2], p[3]);

		// --- pass 4: depth test (nearer blue survives, farther red rejected) --
		{
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = (__bridge id<MTLTexture>)rtTex;
			rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
			rpd.depthAttachment.texture = (__bridge id<MTLTexture>)depthTex;
			rpd.depthAttachment.loadAction = MTLLoadActionClear;
			rpd.depthAttachment.clearDepth = 1.0;
			rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
			id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)psoDepth];
			[enc setDepthStencilState:(__bridge id<MTLDepthStencilState>)states.DepthState(
				(__bridge void*)device, true, true)];
			[enc setVertexBuffer:(__bridge id<MTLBuffer>)cbWvp offset:0 atIndex:0];
			[enc setFragmentTexture:(__bridge id<MTLTexture>)samplerTex atIndex:0];
			[enc setFragmentSamplerState:(__bridge id<MTLSamplerState>)sampNearest atIndex:0];
			[enc setFragmentBuffer:(__bridge id<MTLBuffer>)cbTint offset:0 atIndex:0];
			// NOTE: CPU tint writes between draws in ONE command buffer race
			// (GPU reads final value) — use distinct tint buffers per draw.
			void* cbTintBlue = dev.NewBuffer(16);
			void* cbTintRed = dev.NewBuffer(16);
			{
				float b[4] = {0, 0, 1, 1}, r[4] = {1, 0, 0, 1};
				memcpy([(__bridge id<MTLBuffer>)cbTintBlue contents], b, sizeof(b));
				memcpy([(__bridge id<MTLBuffer>)cbTintRed contents], r, sizeof(r));
			}
			drawAgain(enc, (__bridge id<MTLBuffer>)vbBlue, (__bridge id<MTLBuffer>)cbTintBlue);
			drawAgain(enc, (__bridge id<MTLBuffer>)vbRed, (__bridge id<MTLBuffer>)cbTintRed);
			[enc endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			Check(cb.error == nil, "pass4 draw (depth test, two draws)");
		}
		readback();
		pixel(32, 32, p);
		Check(p[0] > 200 && p[2] < 40, "depth test: nearer quad kept, farther rejected");
		setTint(1, 1, 1, 1);

		// --- pass 5: src-alpha blend (white a=0.5 over black -> ~gray) --------
		setTint(1, 1, 1, 0.5f);
		Check(runPassSmp(psoBlend, (__bridge id<MTLBuffer>)vb, (__bridge id<MTLSamplerState>)sampNearest),
		      "pass5 draw (src-alpha blend)");
		readback();
		pixel(48, 48, p); // white texel * 0.5 alpha over black
		bool gray = p[0] > 100 && p[0] < 160 && p[1] > 100 && p[1] < 160 && p[2] > 100 && p[2] < 160;
		Check(gray, "blend: white@0.5 over black = mid-gray");
		printf("      blend pixel BGRA %u %u %u %u\n", p[0], p[1], p[2], p[3]);

		if (g_failures == 0)
			printf("DEVICETEST_PASS\n");
		else
			printf("DEVICETEST_FAIL failures=%d\n", g_failures);
		return g_failures == 0 ? 0 : 1;
	}
}
