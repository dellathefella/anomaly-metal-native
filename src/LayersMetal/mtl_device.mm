// mtl_device.mm — Metal device/queue + CAMetalLayer swapchain on the SDL2
// Cocoa window (p5 t2). See mtl_device.h for the contract.
// Compiled with -fobjc-arc (see LayersMetal/CMakeLists.txt): ObjC pointers in
// the pimpl struct are ARC-managed; the void* accessors hand out BORROWED
// pointers valid for the lifetime of this object.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "mtl_device.h"

#include <SDL.h>
#include <SDL_syswm.h>

#include <atomic>
#include <cmath>
#include <map>
#include <memory>
#include <utility>
#include <vector>

// deprecated legacy API, still exported by CoreGraphics (same route as the
// GL path's occlusion guard): catches the screen lock where occlusion lags.
extern "C" CFDictionaryRef CGSessionCopyCurrentDictionary(void);

namespace xray::metal
{

	struct MetalDevice::Impl
	{
		id<MTLDevice> device = nil;
		id<MTLCommandQueue> queue = nil;
		NSWindow* window = nil;               // not owned (SDL owns it)
		CAMetalLayer* layer = nil;            // retained while attached
		id<CAMetalDrawable> drawable = nil;   // current frame's drawable
		uint32_t width = 0;
		uint32_t height = 0;
		int presentInterval = 1;
		bool ignoreDisplay = false;
		// Ownership arena for NewBuffer/NewTexture2D (see mtl_device.h).
		std::vector<id<NSObject>> arena;
		// Drawables handed out but not yet presented+GPU-complete. macOS SDK's
		// CAMetalLayer exposes no available-drawable count (nextDrawable always
		// blocks; only a 1s timeout-nil escape hatch), so we account ourselves
		// via command-buffer completed handlers and skip frames instead.
		std::shared_ptr<std::atomic<int>> inFlight = std::make_shared<std::atomic<int>>(0);
		std::map<std::pair<int, int>, id<MTLSamplerState>> samplers;
	};

	MetalDevice::MetalDevice() : m_impl(new Impl()) {}

	MetalDevice::~MetalDevice()
	{
		Detach();
		delete m_impl;
	}

	bool MetalDevice::Create(std::string& error)
	{
		m_impl->device = MTLCreateSystemDefaultDevice();
		if (!m_impl->device)
		{
			error = "MTLCreateSystemDefaultDevice returned nil";
			return false;
		}
		m_impl->queue = [m_impl->device newCommandQueue];
		if (!m_impl->queue)
		{
			error = "newCommandQueue failed";
			return false;
		}
		return true;
	}

	bool MetalDevice::AttachToSDLWindow(void* sdlWindow, std::string& error)
	{
		if (!m_impl->device)
		{
			error = "MetalDevice::Create not called";
			return false;
		}
		if (!sdlWindow)
		{
			error = "null SDL_Window";
			return false;
		}
		SDL_SysWMinfo wm;
		SDL_VERSION(&wm.version);
		if (!SDL_GetWindowWMInfo(static_cast<SDL_Window*>(sdlWindow), &wm))
		{
			error = "SDL_GetWindowWMInfo failed";
			return false;
		}
		if (wm.subsystem != SDL_SYSWM_COCOA || !wm.info.cocoa.window)
		{
			error = "not a Cocoa SDL window";
			return false;
		}
		NSWindow* nsw = wm.info.cocoa.window;
		if (m_impl->window == nsw && m_impl->layer)
			return true; // same window: layer still valid
		Detach();

		NSView* content = [nsw contentView];
		if (!content)
		{
			error = "NSWindow has no contentView";
			return false;
		}
		[content setWantsLayer:YES];

		CAMetalLayer* layer = [CAMetalLayer layer];
		layer.device = m_impl->device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		// framebufferOnly NO: the renderer must be able to copy/read back the
		// backbuffer (MCP screenshots, post-processing); costs a little memory
		// bandwidth on the drawable pool.
		layer.framebufferOnly = NO;
		layer.presentsWithTransaction = NO;
		const double scale = [nsw backingScaleFactor];
		const NSRect rect = [nsw contentRectForFrameRect:[nsw frame]];
		layer.contentsScale = scale;
		layer.drawableSize = CGSizeMake(static_cast<CGFloat>(rect.size.width) * scale,
		                                static_cast<CGFloat>(rect.size.height) * scale);
		layer.maximumDrawableCount = 3;
		layer.frame = [content bounds]; // sublayers get no automatic geometry
		layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
		[content.layer addSublayer:layer];

		m_impl->window = nsw;
		m_impl->layer = layer;
		m_impl->width = static_cast<uint32_t>(layer.drawableSize.width);
		m_impl->height = static_cast<uint32_t>(layer.drawableSize.height);
		return true;
	}

	void MetalDevice::Detach()
	{
		m_impl->drawable = nil;
		[m_impl->layer removeFromSuperlayer];
		m_impl->layer = nil;
		m_impl->window = nil;
		m_impl->width = m_impl->height = 0;
	}

	void MetalDevice::SetPresentInterval(int frames)
	{
		m_impl->presentInterval = frames < 0 ? 0 : frames;
		// vsync itself is the default presentDrawable behaviour; the drawable
		// pool depth is what actually bounds an uncapped loop.
		if (m_impl->layer)
			m_impl->layer.maximumDrawableCount = m_impl->presentInterval > 0 ? 3 : 2;
	}

	void MetalDevice::Resize(uint32_t widthPx, uint32_t heightPx)
	{
		if (widthPx == 0 || heightPx == 0)
			return;
		m_impl->width = widthPx;
		m_impl->height = heightPx;
		if (m_impl->layer)
			m_impl->layer.drawableSize = CGSizeMake(static_cast<CGFloat>(widthPx), static_cast<CGFloat>(heightPx));
	}

	bool MetalDevice::CanPresent() const
	{
		if (!m_impl->layer || !m_impl->width || !m_impl->height)
			return false;
		if (!m_impl->ignoreDisplay)
		{
			if (m_impl->window && ([m_impl->window occlusionState] & NSWindowOcclusionStateVisible) == 0)
				return false;
			CFDictionaryRef d = CGSessionCopyCurrentDictionary();
			if (d)
			{
				bool locked = false;
				if (CFNumberRef v = (CFNumberRef)CFDictionaryGetValue(d, CFSTR("CGSSessionScreenIsLocked")))
				{
					int x = 0;
					CFNumberGetValue(v, kCFNumberIntType, &x);
					locked = x != 0;
				}
				CFRelease(d);
				if (locked)
					return false;
			}
		}
		return true;
	}

	void MetalDevice::SetIgnoreDisplayAvailability(bool ignore) { m_impl->ignoreDisplay = ignore; }

	// Plain pointer casts under ObjC++ are non-owning bridges: borrowed refs.
	void* MetalDevice::Device() const { return (__bridge void*)m_impl->device; }
	void* MetalDevice::Queue() const { return (__bridge void*)m_impl->queue; }
	void* MetalDevice::Layer() const { return m_impl->layer ? (__bridge void*)m_impl->layer : nullptr; }

	double MetalDevice::BackingScale() const
	{
		return m_impl->window ? [m_impl->window backingScaleFactor] : 1.0;
	}

	uint32_t MetalDevice::Width() const { return m_impl->width; }
	uint32_t MetalDevice::Height() const { return m_impl->height; }

	const char* MetalDevice::DeviceName() const
	{
		static std::string name;
		name = m_impl->device ? std::string([m_impl->device.name UTF8String]) : std::string("none");
		return name.c_str();
	}

	bool MetalDevice::NextDrawable(void** colorTexture, std::string& error)
	{
		*colorTexture = nullptr;
		if (!m_impl->layer)
		{
			error = "no layer attached";
			return false;
		}
		if (!CanPresent())
			return false; // frame must be skipped entirely (nextDrawable would block)
		if (m_impl->inFlight->load(std::memory_order_relaxed) >= (int)m_impl->layer.maximumDrawableCount)
			return false; // all drawables in flight; skip rather than block
		id<CAMetalDrawable> d = m_impl->layer.nextDrawable;
		if (!d)
			return false;
		m_impl->drawable = d;
		m_impl->inFlight->fetch_add(1, std::memory_order_relaxed);
		*colorTexture = (__bridge void*)d.texture; // borrowed; valid until Present()
		return true;
	}

	void MetalDevice::Present(void* commandBuffer)
	{
		id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)commandBuffer;
		if (cb && m_impl->drawable)
		{
			auto inflight = m_impl->inFlight;
			[cb addCompletedHandler:^(id<MTLCommandBuffer>) {
				inflight->fetch_sub(1, std::memory_order_relaxed);
			}];
			[cb presentDrawable:m_impl->drawable];
			[cb commit];
		}
		else
		{
			if (cb)
				[cb commit];
			if (m_impl->drawable) // drawable handed out but buffer dropped it
				m_impl->inFlight->fetch_sub(1, std::memory_order_relaxed);
		}
		m_impl->drawable = nil;
	}

	bool MetalDevice::Readback(void* texture, uint8_t* dst, uint32_t bytesPerRow, uint32_t w, uint32_t h,
	                           std::string& error)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex)
		{
			error = "null texture";
			return false;
		}
		[tex getBytes:dst
		  bytesPerRow:bytesPerRow
		   fromRegion:MTLRegionMake2D(0, 0, w, h)
		  mipmapLevel:0];
		return true;
	}

	void* MetalDevice::NewBuffer(size_t bytes)
	{
		if (!m_impl->device || bytes == 0)
			return nullptr;
		id<MTLBuffer> buf = [m_impl->device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		if (buf)
			m_impl->arena.push_back(buf); // device-owned arena; borrowed handle back
		return (__bridge void*)buf;
	}

	void* MetalDevice::NewTexture2D(uint32_t w, uint32_t h, uint32_t mips, int pixelFormat,
	                                bool framebufferOnly, bool shaderReadable)
	{
		if (!m_impl->device || w == 0 || h == 0)
			return nullptr;
		MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat
																					 width:w
																				height:h
																		 mipmapped:mips != 1];
		if (mips == 0)
			td.mipmapLevelCount = (NSUInteger)(std::log2((double)(w > h ? w : h))) + 1;
		else if (mips > 1)
			td.mipmapLevelCount = mips;
		// MTLTextureDescriptor has no framebufferOnly knob (read-only on the
		// texture): usage bits decide. framebufferOnly == usage RenderTarget;
		// readable/copyable textures need ShaderRead (also enables getBytes).
		td.usage = MTLTextureUsageRenderTarget;
		if (shaderReadable || !framebufferOnly)
			td.usage |= MTLTextureUsageShaderRead;
		id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:td];
		if (tex)
			m_impl->arena.push_back(tex);
		return (__bridge void*)tex;
	}

	void MetalDevice::ReleaseResource(void* obj)
	{
		if (!obj)
			return;
		id<NSObject> target = (__bridge id<NSObject>)obj;
		for (auto it = m_impl->arena.begin(); it != m_impl->arena.end(); ++it)
		{
			if (*it == target)
			{
				m_impl->arena.erase(it);
				return;
			}
		}
	}

	void* MetalDevice::Sampler(int addressMode, int filter)
	{
		if (!m_impl->device)
			return nullptr;
		auto key = std::make_pair(addressMode, filter);
		auto it = m_impl->samplers.find(key);
		if (it != m_impl->samplers.end())
			return (__bridge void*)it->second;
		MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
		MTLSamplerAddressMode am = addressMode == 1 ? MTLSamplerAddressModeRepeat
		                 : addressMode == 2 ? MTLSamplerAddressModeMirrorRepeat
		                 : MTLSamplerAddressModeClampToEdge;
		sd.sAddressMode = am;
		sd.tAddressMode = am;
		sd.minFilter = filter == 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
		sd.magFilter = filter == 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
		id<MTLSamplerState> s = [m_impl->device newSamplerStateWithDescriptor:sd];
		if (s)
			m_impl->samplers[key] = s;
		return (__bridge void*)s;
	}

	bool MetalDevice::WriteTexture(void* texture, const void* pixels, uint32_t w, uint32_t h, std::string& error)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex || !pixels)
		{
			error = "null texture/pixels";
			return false;
		}
		[tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
			   mipmapLevel:0
				 withBytes:pixels
			   bytesPerRow:4 * w];
		return true;
	}

} // namespace xray::metal
