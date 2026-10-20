// metal_poc.mm — p5 Metal renderer proof-of-life.
//
// Validates the two foundations every native Metal renderer needs, on this
// machine, end to end:
//   1. Runtime shader pipeline: HLSL -> SPIR-V (DXC) -> MSL (SPIRV-Cross).
//   2. Metal device + render pipeline + offscreen draw + CPU readback.
//
// A vertex-coloured triangle is compiled through the pipeline and rendered to
// an offscreen BGRA8 target; the centre pixel is read back and asserted. The
// DX9->HLSL compatibility shim is exercised too. This is the seed of the
// xrRenderMetal device backend; the DXC call is a subprocess for now and the
// production path (dlopen libdxcompiler in-process) is tracked as a follow-up.
//
// Build (see CMake target metal_poc) or manually:
//   clang++ -std=c++17 -fobjc-arc metal_poc.mm \
//     -I<spirv-cross-include> <spirv-cross-msl.a> <spirv-cross-core.a> \
//     -framework Metal -framework Foundation -o metal_poc

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <spirv_cross/spirv_cross.hpp>
#include <spirv_cross/spirv_msl.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifndef DXC_PATH
#define DXC_PATH "/Users/jdella/Desktop/anomaly-metal-native/repos/dxc/build-mac/bin/dxc"
#endif

// --- DX9 -> DXC-compatible HLSL shim ---------------------------------------
// X-Ray / Anomaly shaders are DX9-era. DXC (SM6) rejects legacy tokens. The
// corpus is small in token variety, so a targeted textual rewrite covers it.
// Kept as a standalone function so the future backend + tests can reuse it.
static std::string ApplyCompatShim(const std::string& in)
{
	std::string s = in;
	static const std::pair<const char*, const char*> repl[] = {
		{ "sampler2D", "Texture2D<float4>" },
		{ "samplerCUBE", "TextureCube<float4>" },
		{ "sampler_state", "SamplerState" },
		{ "tex2D", "Sample" },
		{ "tex2Dproj", "SampleProj" },
		{ "texCUBE", "SampleCube" },
		{ "float4x4", "float4x4" }, // no-op, documents the token
		{ "mul(", "mul(" },         // no-op
	};
	for (const auto& r : repl)
	{
		size_t pos = 0;
		const std::string from = r.first, to = r.second;
		if (from == to)
			continue;
		while ((pos = s.find(from, pos)) != std::string::npos)
		{
			s.replace(pos, from.size(), to);
			pos += to.size();
		}
	}
	return s;
}

static std::string ReadFile(const std::string& p)
{
	FILE* f = fopen(p.c_str(), "rb");
	if (!f)
		return {};
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	std::string out(static_cast<size_t>(n), '\0');
	if (n > 0 && fread(&out[0], 1, static_cast<size_t>(n), f) != static_cast<size_t>(n))
		out.clear();
	fclose(f);
	return out;
}

static void WriteFile(const std::string& p, const void* data, size_t n)
{
	FILE* f = fopen(p.c_str(), "wb");
	if (!f)
		return;
	if (n)
		fwrite(data, 1, n, f);
	fclose(f);
}

// HLSL -> SPIR-V via dxc subprocess.
static bool HlslToSpirv(const std::string& hlsl, const char* entry, const char* target,
                        std::vector<uint32_t>& spirv, std::string& err)
{
	const char* hlslPath = "/tmp/metal_poc_shader.hlsl";
	const char* spvPath = "/tmp/metal_poc_shader.spv";
	WriteFile(hlslPath, hlsl.data(), hlsl.size());

	char cmd[1024];
	snprintf(cmd, sizeof(cmd),
	         "\"%s\" -T %s -E %s -spirv -O1 -Fo \"%s\" \"%s\" 2>&1",
	         DXC_PATH, target, entry, spvPath, hlslPath);
	int rc = system(cmd);
	if (rc != 0)
	{
		err = "dxc exit " + std::to_string(rc);
		return false;
	}
	std::string bytes = ReadFile(spvPath);
	if (bytes.size() < 4 || (bytes.size() % 4) != 0)
	{
		err = "no/short SPIR-V output";
		return false;
	}
	spirv.resize(bytes.size() / 4);
	memcpy(spirv.data(), bytes.data(), bytes.size());
	if (spirv[0] != 0x07230203u) // SPIR-V magic
	{
		err = "bad SPIR-V magic";
		return false;
	}
	return true;
}

// SPIR-V -> MSL via SPIRV-Cross (in-process).
static bool SpirvToMsl(const std::vector<uint32_t>& spirv, bool isVertex,
                       std::string& msl, std::string& err)
{
	(void)isVertex;
	try
	{
		spirv_cross::CompilerMSL comp(spirv);
		spirv_cross::CompilerMSL::Options opts;
		opts.set_msl_version(2, 1);
		opts.platform = spirv_cross::CompilerMSL::Options::macOS;
		comp.set_msl_options(opts);
		msl = comp.compile();
	}
	catch (const std::exception& e)
	{
		err = e.what();
		return false;
	}
	return true;
}

int main()
{
	@autoreleasepool
	{
		int failures = 0;
		printf("== metal_poc: Metal renderer proof-of-life ==\n");

		// 1) Device
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device)
		{
			printf("FAIL: MTLCreateSystemDefaultDevice returned null\n");
			return 2;
		}
		printf("[ok] device: %s\n", device.name.UTF8String);

		// 2) Shader source (modern HLSL; also exercise the compat shim path).
		(void)ApplyCompatShim("float4 s(float2 uv):COLOR{ sampler2D t; return tex2D(t,uv); }");

		const char* hlsl =
		    "struct VS_IN { float2 pos : POSITION; float3 col : COLOR; };\n"
		    "struct PS_IN { float4 pos : SV_POSITION; float3 col : COLOR; };\n"
		    "PS_IN vs_main(VS_IN v) { PS_IN o; o.pos = float4(v.pos, 0.0, 1.0); o.col = v.col; return o; }\n"
		    "float4 ps_main(PS_IN i) : SV_TARGET { return float4(i.col, 1.0); }\n";

		// 3) VS: HLSL -> SPIR-V -> MSL
		std::vector<uint32_t> vsSpv, psSpv;
		std::string vsMsl, psMsl, err;
		if (!HlslToSpirv(hlsl, "vs_main", "vs_6_0", vsSpv, err))
		{
			printf("FAIL: dxc VS: %s\n", err.c_str());
			return 3;
		}
		printf("[ok] HLSL->SPIR-V (VS): %zu words\n", vsSpv.size());
		if (!SpirvToMsl(vsSpv, true, vsMsl, err))
		{
			printf("FAIL: spirv-cross VS: %s\n", err.c_str());
			return 4;
		}
		printf("[ok] SPIR-V->MSL (VS): %zu bytes\n", vsMsl.size());

		if (!HlslToSpirv(hlsl, "ps_main", "ps_6_0", psSpv, err))
		{
			printf("FAIL: dxc PS: %s\n", err.c_str());
			return 3;
		}
		if (!SpirvToMsl(psSpv, false, psMsl, err))
		{
			printf("FAIL: spirv-cross PS: %s\n", err.c_str());
			return 4;
		}
		printf("[ok] SPIR-V->MSL (PS): %zu bytes\n", psMsl.size());

		// 4) Metal libraries from MSL
		NSError* nserr = nil;
		id<MTLLibrary> vsLib = [device newLibraryWithSource:[NSString stringWithUTF8String:vsMsl.c_str()]
		                                            options:nil
		                                              error:&nserr];
		if (!vsLib)
		{
			printf("FAIL: MSL VS compile: %s\n", nserr.localizedDescription.UTF8String);
			printf("---- VS MSL ----\n%s\n", vsMsl.c_str());
			return 5;
		}
		id<MTLFunction> vsFn = [vsLib newFunctionWithName:@"vs_main"];
		if (!vsFn)
		{
			printf("FAIL: vs_main not found in MSL\n---- VS MSL ----\n%s\n", vsMsl.c_str());
			return 5;
		}
		id<MTLLibrary> psLib = [device newLibraryWithSource:[NSString stringWithUTF8String:psMsl.c_str()]
		                                            options:nil
		                                              error:&nserr];
		if (!psLib)
		{
			printf("FAIL: MSL PS compile: %s\n", nserr.localizedDescription.UTF8String);
			printf("---- PS MSL ----\n%s\n", psMsl.c_str());
			return 5;
		}
		id<MTLFunction> psFn = [psLib newFunctionWithName:@"ps_main"];
		if (!psFn)
		{
			printf("FAIL: ps_main not found in MSL\n");
			return 5;
		}
		printf("[ok] MTLFunction vs_main + ps_main\n");

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
		struct V { float p[2]; float c[3]; };
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
		if (px[2] > 240 && px[1] < 16 && px[0] < 16 && px[3] > 240)
			printf("[ok] centre pixel = red (pipeline rendered correctly)\n");
		else
		{
			printf("FAIL: centre pixel not red\n");
			failures++;
		}

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

		if (failures == 0)
			printf("METAL_POC_PASS\n");
		else
			printf("METAL_POC_FAIL (%d)\n", failures);
		return failures ? 1 : 0;
	}
}
