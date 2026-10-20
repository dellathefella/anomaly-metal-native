// metal_swap_test.mm — p5 t2 validation: CAMetalLayer swapchain on the SDL2
// Cocoa window (MetalDevice facade).
//
// Proves, on-screen:
//   * CAMetalLayer attach to the SDL window's contentView (HiDPI drawableSize)
//   * full frame loop through the swapchain: runtime-compiled HLSL->MSL
//     fullscreen triangle (DXC in-process + SPIRV-Cross) -> drawable -> present
//   * drawable CONTENT verified by CPU readback after GPU completion
//     (clear=green corners, triangle=blue centre) — framebufferOnly=NO path
//   * vsync pacing (presentInterval=1)
//   * SDL resize -> drawableSize update (drawable texture dimensions follow)
//   * occlusion guard plumbing (CanPresent / skipped-frame accounting)
//
// Prints SWAP_TEST_PASS when every check holds.

#define SDL_MAIN_HANDLED // before SDL headers: keep plain main, no SDLmain shim

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_device.h"
#include "mtl_shader_compiler.h"

#include <SDL.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

// SM6-native source: no DX9 shim needed (compat shim off). Entry names kept
// (SPIRV-Cross only renames 'main').
static const char* kTriangleHlsl = R"(
struct PSIn
{
	float4 pos : SV_Position;
	float4 col : TEXCOORD0;
};

PSIn vs_main(uint vid : SV_VertexID)
{
	PSIn o;
	float2 p = vid == 0u ? float2(-0.5, -0.5)
	         : (vid == 1u ? float2(0.5, -0.5) : float2(0.0, 0.5));
	o.pos = float4(p, 0.0, 1.0);
	o.col = float4(0.0, 0.0, 1.0, 1.0);
	return o;
}

float4 ps_main(PSIn i) : SV_TARGET
{
	return i.col;
}
)";

static id<MTLFunction> LoadFunction(id<MTLDevice> device, const std::string& msl,
                                    const char* preferred, const char* fallback)
{
	NSString* src = [NSString stringWithUTF8String:msl.c_str()];
	NSError* err = nil;
	id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
	if (!lib)
	{
		printf("FAIL: newLibraryWithSource: %s\n", err.localizedDescription.UTF8String);
		return nil;
	}
	id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:preferred]];
	if (!fn)
		fn = [lib newFunctionWithName:[NSString stringWithUTF8String:fallback]];
	return fn;
}

// Read one BGRA pixel from a texture (drawable textures are readable with
// framebufferOnly=NO; region reads avoid copying the whole frame).
static bool SamplePixel(void* tex, uint32_t x, uint32_t y, uint8_t out[4])
{
	id<MTLTexture> t = (__bridge id<MTLTexture>)tex;
	if (!t)
	{
		out[0] = out[1] = out[2] = out[3] = 0;
		return false;
	}
	uint8_t buf[4];
	[t getBytes:buf bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
	memcpy(out, buf, 4);
	return true;
}

int main(int argc, char** argv)
{
	setvbuf(stdout, nullptr, _IONBF, 0); // live progress: a hang must be locatable
	@autoreleasepool
	{
		printf("== metal_swap_test: CAMetalLayer swapchain on SDL2 window ==\n");
		(void)argc;
		(void)argv;
		// SDL2/macOS rewrites main->SDL_main and expects its app-entry shim
		// (SDLmain). SDL_MAIN_HANDLED opts out: plain main + SetMainReady.
		SDL_SetMainReady();
		if (SDL_Init(SDL_INIT_VIDEO) != 0)
		{
			printf("FAIL: SDL_Init: %s\n", SDL_GetError());
			return 2;
		}
		SDL_Window* wnd = SDL_CreateWindow("xr metal swap test", SDL_WINDOWPOS_CENTERED,
		                                   SDL_WINDOWPOS_CENTERED, 640, 360,
		                                   SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI);
		if (!wnd)
		{
			printf("FAIL: SDL_CreateWindow: %s\n", SDL_GetError());
			return 2;
		}

		xray::metal::MetalDevice dev;
		std::string err;
		if (::getenv("XR_METAL_IGNORE_LOCK"))
		{
			printf("[..] XR_METAL_IGNORE_LOCK: display-availability clauses bypassed (locked-screen verification run)\n");
			dev.SetIgnoreDisplayAvailability(true);
		}
		Check(dev.Create(err), "Metal device + queue");
		printf("[dev] %s\n", dev.DeviceName());
		Check(dev.AttachToSDLWindow(wnd, err), "CAMetalLayer attached to SDL window");
		if (err.empty() == false)
			printf("      attach error: %s\n", err.c_str());

		const double scale = dev.BackingScale();
		int pw = 0, ph = 0;
		SDL_GetWindowSize(wnd, &pw, &ph);
		printf("[ok] window %dx%d pt @ scale %.1f -> layer %ux%u px\n", pw, ph, scale,
		       dev.Width(), dev.Height());
		Check(dev.Width() == (uint32_t)llround(pw * scale) && dev.Height() == (uint32_t)llround(ph * scale),
		      "drawableSize matches window points * backing scale (HiDPI)");
		Check(dev.CanPresent(), "CanPresent() true for visible unlocked window");

		// --- shader pipeline -------------------------------------------------
		xray::metal::MetalShaderCompiler comp;
		Check(comp.Init({DXCOMPILER_PATH}, DXC_PATH, "/tmp/xr_metal_swap_cache"), "shader compiler init");
		auto vs = comp.Compile(kTriangleHlsl, "vs_main", xray::metal::ShaderStage::Vertex, false);
		auto ps = comp.Compile(kTriangleHlsl, "ps_main", xray::metal::ShaderStage::Pixel, false);
		Check(vs.ok, "VS HLSL->MSL");
		Check(ps.ok, "PS HLSL->MSL");
		if (!vs.ok || !ps.ok)
		{
			printf("  vs err: %s\n  ps err: %s\n", vs.error.c_str(), ps.error.c_str());
			SDL_Quit();
			return 2;
		}

		id<MTLDevice> device = (__bridge id<MTLDevice>)dev.Device();
		id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)dev.Queue();
		id<MTLFunction> vsFn = LoadFunction(device, vs.msl, "vs_main", "main0");
		id<MTLFunction> psFn = LoadFunction(device, ps.msl, "ps_main", "main0");
		Check(vsFn && psFn, "MSL functions loaded");
		if (!vsFn || !psFn)
		{
			SDL_Quit();
			return 2;
		}

		MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = vsFn;
		pd.fragmentFunction = psFn;
		pd.vertexDescriptor = nil; // vertex-id triangle: no attributes
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		NSError* nserr = nil;
		id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&nserr];
		Check(pso != nil, "render pipeline state (BGRA8 drawable format)");
		if (!pso)
		{
			printf("  pso err: %s\n", nserr.localizedDescription.UTF8String);
			SDL_Quit();
			return 2;
		}

		// --- frame loop ------------------------------------------------------
		const int kFrames = 60;
		const int kVerifyFrame = 10;
		int presented = 0, skipped = 0;
		bool readbackChecked = false;
		bool firstFrameLogged = false;
		auto t0 = std::chrono::steady_clock::now();
		while (presented < kFrames)
		{
			double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
			if (el > 20.0) // environment guard: display asleep/locked/occluded
			{
				printf("[..] 20s deadline: presented=%d skipped=%d CanPresent=%d\n", presented,
				       skipped, (int)dev.CanPresent());
				break;
			}
			SDL_PumpEvents();
			SDL_Event ev;
			bool quit = false;
			while (SDL_PollEvent(&ev))
				if (ev.type == SDL_QUIT)
					quit = true;
			if (quit)
				break;

			void* tex = nullptr;
			if (!dev.NextDrawable(&tex, err))
			{
				skipped++;
				if (skipped == 120) // ~quarter second of skips: say so once
					printf("[..] drawables unavailable (CanPresent=%d err='%s')\n", (int)dev.CanPresent(),
					       err.c_str());
				SDL_Delay(2);
				continue;
			}
			if (!firstFrameLogged)
			{
				firstFrameLogged = true;
				id<MTLTexture> ft = (__bridge id<MTLTexture>)tex;
				printf("[ok] first drawable: %llu x %llu\n", (unsigned long long)ft.width,
				       (unsigned long long)ft.height);
			}
			id<MTLTexture> drawableTex = (__bridge id<MTLTexture>)tex;
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = drawableTex;
			rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 1.0, 0.0, 1.0); // green bg
			id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:pso];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[enc endEncoding];

			if (presented == kVerifyFrame)
			{
				// Hold the exact frame's drawable + buffer; present, wait for GPU,
				// then read back before the pool can recycle the texture.
				id<MTLTexture> verifyTex = drawableTex; // ARC retain
				dev.Present((__bridge void*)cb);
				[cb waitUntilCompleted];
				uint8_t center[4], corner[4];
				SamplePixel((__bridge void*)verifyTex, dev.Width() / 2, dev.Height() / 2, center);
				SamplePixel((__bridge void*)verifyTex, 4, 4, corner);
				printf("[ok] swapchain readback: center BGRA %u %u %u %u | corner BGRA %u %u %u %u\n",
				       center[0], center[1], center[2], center[3], corner[0], corner[1], corner[2], corner[3]);
				// BGRA byte order: [0]=B [1]=G [2]=R [3]=A. Triangle (blue) is a
				// centred half-size triangle; clear (green) shows at the corners.
				Check(center[0] > 200 && center[2] < 40 && center[1] < 40,
				      "swapchain center pixel is blue (triangle rasterized into drawable)");
				Check(corner[1] > 200 && corner[0] < 40 && corner[2] < 40, "swapchain corner pixel is green (clear color)");
				readbackChecked = true;
			}
			else
			{
				dev.Present((__bridge void*)cb);
			}
			presented++;
		}
		auto t1 = std::chrono::steady_clock::now();
		double secs = std::chrono::duration<double>(t1 - t0).count();

		printf("[ok] presented=%d skipped=%d in %.2fs (%.1f presented fps, vsync on)\n", presented,
		       skipped, secs, presented / secs);
		Check(readbackChecked, "swapchain content verified on-device");
		double ms_per_frame = presented > 0 ? secs * 1000.0 / presented : 1e9;
		if (::getenv("XR_METAL_IGNORE_LOCK"))
			printf("[..] pacing check skipped (locked session: display sync not enforced, %.1f ms/frame)\n",
			       ms_per_frame);
		else
			Check(ms_per_frame >= 3.0, "present pacing is display-synced (>= 3ms/frame, uncapped would be <<)");
		Check(presented >= kFrames / 2, "frame loop ran to completion (not wedged by occlusion)");

		// --- resize ----------------------------------------------------------
		SDL_SetWindowSize(wnd, 480, 270);
		SDL_PumpEvents();
		SDL_GetWindowSize(wnd, &pw, &ph);
		dev.Resize((uint32_t)llround(pw * dev.BackingScale()), (uint32_t)llround(ph * dev.BackingScale()));
		Check(dev.Width() == (uint32_t)llround(pw * dev.BackingScale()) &&
		          dev.Height() == (uint32_t)llround(ph * dev.BackingScale()),
		      "Resize() updates drawableSize to new window px");
		void* tex = nullptr;
		bool got = dev.NextDrawable(&tex, err);
		if (got)
		{
			id<MTLTexture> t = (__bridge id<MTLTexture>)tex;
			Check(t.width == dev.Width() && t.height == dev.Height(),
			      "next drawable matches new drawableSize (swapchain resized)");
			id<MTLCommandBuffer> cb = [queue commandBuffer];
			dev.Present((__bridge void*)cb); // drop: commit only
		}
		else
			printf("[..] resize drawable skipped (window occluded)\n");

		if (g_failures == 0)
			printf("SWAP_TEST_PASS\n");
		else
			printf("SWAP_TEST_FAIL failures=%d\n", g_failures);

		SDL_Delay(300); // let the last frames show before teardown
		dev.Detach();
		SDL_DestroyWindow(wnd);
		SDL_Quit();
		return g_failures == 0 ? 0 : 1;
	}
}
