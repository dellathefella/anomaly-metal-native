// metal_poc.mm — p5 Metal renderer proof-of-life.
//
// Validates the foundations every native Metal renderer needs, on this
// machine, end to end:
//   1. Runtime shader pipeline: HLSL -> SPIR-V (DXC IN-PROCESS via
//      libdxcompiler.dylib) -> MSL (SPIRV-Cross, linked statically), with the
//      hash-keyed on-disk shader cache proven cold-miss + hot-hit.
//   2. Metal device + render pipeline + offscreen draw + CPU readback.
//
// A vertex-coloured triangle is compiled through the pipeline and rendered to
// an offscreen BGRA8 target; the centre pixel is read back and asserted.
// This is the seed of the xrRenderMetal device backend.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_shader_compiler.h"

#include <cstdint>
#include <cstdio>
#include <filesystem>
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

int main()
{
	@autoreleasepool
	{
		printf("== metal_poc: Metal renderer proof-of-life ==\n");

		// 1) Metal device
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device)
		{
			printf("FAIL: MTLCreateSystemDefaultDevice returned null\n");
			return 2;
		}
		printf("[ok] device: %s\n", device.name.UTF8String);

		// 2) Shader compiler: in-process DXC + disk cache (fresh: cold test)
		std::error_code ec;
		std::filesystem::remove_all("/tmp/metal_poc_shadercache", ec);

		xray::metal::MetalShaderCompiler sh;
		Check(sh.Init({DXCOMPILER_PATH}, DXC_PATH, "/tmp/metal_poc_shadercache"), "compiler init");
		Check(sh.HasInProcessDxc(), "DXC loaded in-process (libdxcompiler.dylib)");
		printf("[info] DXC backend: %s\n", sh.DxcBackendName());

		// Compat shim smoke: DX9 tokens rewrite to SM6 spellings.
		{
			const std::string shimmed = xray::metal::MetalShaderCompiler::ApplyCompatShim(
				"float4 s(float2 uv):COLOR{ sampler2D t; return tex2D(t,uv); }");
			Check(shimmed.find("Texture2D<float4>") != std::string::npos &&
				      shimmed.find("Sample(t,uv)") != std::string::npos,
			      "DX9->DXC compat shim rewrites sampler2D/tex2D");
		}

		// 3) Shader source (modern HLSL triangle)
		const char* hlsl =
			"struct VS_IN { float2 pos : POSITION; float3 col : COLOR; };\n"
			"struct PS_IN { float4 pos : SV_POSITION; float3 col : COLOR; };\n"
			"PS_IN vs_main(VS_IN v) { PS_IN o; o.pos = float4(v.pos, 0.0, 1.0); o.col = v.col; return o; }\n"
			"float4 ps_main(PS_IN i) : SV_TARGET { return float4(i.col, 1.0); }\n";

		using xray::metal::ShaderCompileResult;
		using xray::metal::ShaderStage;

		const ShaderCompileResult vs = sh.Compile(hlsl, "vs_main", ShaderStage::Vertex);
		if (!vs.ok)
			printf("  dxc messages: %s | error: %s\n", vs.messages.c_str(), vs.error.c_str());
		Check(vs.ok && !vs.fromCache && !vs.msl.empty(), "VS compiled (cache cold)");

		const ShaderCompileResult vs2 = sh.Compile(hlsl, "vs_main", ShaderStage::Vertex);
		Check(vs2.ok && vs2.fromCache && vs2.msl == vs.msl, "VS served from shader cache (hot)");

		const ShaderCompileResult ps = sh.Compile(hlsl, "ps_main", ShaderStage::Pixel);
		Check(ps.ok && !ps.fromCache && !ps.msl.empty(), "PS compiled (cache cold)");
		if (g_failures)
			return 3;

		// 4) Metal libraries from MSL
		NSError* nserr = nil;
		id<MTLLibrary> vsLib = [device newLibraryWithSource:[NSString stringWithUTF8String:vs.msl.c_str()]
		                                            options:nil
		                                              error:&nserr];
		if (!vsLib)
		{
			printf("FAIL: MSL VS compile: %s\n---- VS MSL ----\n%s\n",
			       nserr.localizedDescription.UTF8String, vs.msl.c_str());
			return 5;
		}
		id<MTLFunction> vsFn = [vsLib newFunctionWithName:@"vs_main"];
		id<MTLLibrary> psLib = [device newLibraryWithSource:[NSString stringWithUTF8String:ps.msl.c_str()]
		                                            options:nil
		                                              error:&nserr];
		if (!psLib)
		{
			printf("FAIL: MSL PS compile: %s\n---- PS MSL ----\n%s\n",
			       nserr.localizedDescription.UTF8String, ps.msl.c_str());
			return 5;
		}
		id<MTLFunction> psFn = [psLib newFunctionWithName:@"ps_main"];
		Check(vsFn && psFn, "MTLFunction vs_main + ps_main");
		if (!vsFn || !psFn)
			return 5;

		// 5) Pipeline with a vertex descriptor matching the SPIRV-Cross
		// attribute layout (POSITION=attribute0 float2, COLOR=attribute1 float3).
		MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat3;
		vd.attributes[1].offset = 8;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = 20;
		vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

		MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
		pd.vertexFunction = vsFn;
		pd.fragmentFunction = psFn;
		pd.vertexDescriptor = vd;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&nserr];
		if (!pso)
		{
			printf("FAIL: pipeline: %s\n", nserr.localizedDescription.UTF8String);
			return 6;
		}
		printf("[ok] render pipeline state\n");

		// 6) Fullscreen triangle, all-vertex red so the centre is unambiguous.
		struct V
		{
			float p[2];
			float c[3];
		};
		V verts[3] = {
			{ { -1.0f, -1.0f }, { 1.0f, 0.0f, 0.0f } },
			{ { 3.0f, -1.0f }, { 1.0f, 0.0f, 0.0f } },
			{ { -1.0f, 3.0f }, { 1.0f, 0.0f, 0.0f } },
		};
		id<MTLBuffer> vb = [device newBufferWithBytes:verts
		                                      length:sizeof(verts)
		                                     options:MTLResourceStorageModeShared];

		const uint32_t W = 64, H = 64;
		MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                              width:W
		                                                                             height:H
		                                                                          mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> rt = [device newTextureWithDescriptor:td];

		id<MTLCommandQueue> queue = [device newCommandQueue];
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = rt;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:pso];
		[enc setVertexBuffer:vb offset:0 atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
		[cb commit];
		[cb waitUntilCompleted];

		// 7) Read back the centre pixel.
		uint8_t px[4] = { 0, 0, 0, 0 };
		[rt getBytes:px
		           bytesPerRow:4
		            fromRegion:MTLRegionMake2D(W / 2, H / 2, 1, 1)
		           mipmapLevel:0];
		printf("[info] centre BGRA = %u %u %u %u\n", px[0], px[1], px[2], px[3]);
		// Expected red in BGRA8Unorm: B=0 G=0 R=255 A=255.
		Check(px[2] > 240 && px[1] < 16 && px[0] < 16 && px[3] > 240,
		      "centre pixel = red (pipeline rendered correctly)");

		// Dump a PPM for the record.
		std::vector<uint8_t> full(W * H * 4);
		[rt getBytes:full.data()
		           bytesPerRow:W * 4
		            fromRegion:MTLRegionMake2D(0, 0, W, H)
		           mipmapLevel:0];
		FILE* ppm = fopen("/tmp/metal_poc.ppm", "wb");
		if (ppm)
		{
			fprintf(ppm, "P6\n%u %u\n255\n", W, H);
			for (uint32_t i = 0; i < W * H; i++)
			{
				uint8_t b = full[i * 4 + 0], g = full[i * 4 + 1], r = full[i * 4 + 2];
				fputc(r, ppm);
				fputc(g, ppm);
				fputc(b, ppm);
			}
			fclose(ppm);
			printf("[ok] wrote /tmp/metal_poc.ppm\n");
		}

		if (g_failures == 0)
			printf("METAL_POC_PASS\n");
		else
			printf("METAL_POC_FAIL (%d)\n", g_failures);
		return g_failures ? 1 : 0;
	}
}
