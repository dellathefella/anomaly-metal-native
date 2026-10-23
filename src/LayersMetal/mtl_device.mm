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

#include <mach/mach.h>

#include <SDL.h>
#include <SDL_syswm.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <utility>
#include <vector>

// deprecated legacy API, still exported by CoreGraphics (same route as the
// GL path's occlusion guard): catches the screen lock where occlusion lags.
extern "C" CFDictionaryRef CGSessionCopyCurrentDictionary(void);

// launch131 LEAK HEARTBEAT (strip in t6): resource creation counters + RSS.
static std::atomic<uint64_t> g_mtlTexCreated{ 0 }, g_mtlBufCreated{ 0 }, g_mtlResReleased{ 0 };
static uint64_t MtlCurRSSBytes()
{
	task_vm_info_data_t vi;
	mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &cnt) != KERN_SUCCESS)
		return 0;
	return (uint64_t)vi.internal + vi.compressed;
}

namespace xray::metal
{

	// p5 launch221: see mtl_device.h — set by the render layer at load.
	void (*g_texReleaseHook)(void*) = nullptr;

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
		// ARC keeps each pushed object alive for the arena's lifetime; the
		// void* handles handed out are borrowed against it (ReleaseResource
		// erases the entry and lets ARC retire the object).
		std::vector<id<NSObject>> arena;
		// Drawables handed out but not yet presented+GPU-complete. macOS SDK's
		// CAMetalLayer exposes no available-drawable count (nextDrawable always
		// blocks; only a 1s timeout-nil escape hatch), so we account ourselves
		// via command-buffer completed handlers and skip frames instead.
		std::shared_ptr<std::atomic<int>> inFlight = std::make_shared<std::atomic<int>>(0);
		// launch133: recently committed CBs, oldest first. Bounded backlog =
		// GL-parity swap blocking (see Present).
		std::deque<id<MTLCommandBuffer>> inflightCBs;
		// launch134: GPU buffer pool. vmmap verdict (launch133): IOAccelerator
		// (graphics) 19.8G→26.2G in 45s while the arena stayed flat — freed
		// shared buffers never returned their driver-side backing once
		// MB-scale staging buffers churned ~10/s. Recycle them explicitly
		// (the GL driver did this implicitly for VBOs). Released buffers sit
		// in bufRetire until every CB that could have encoded them retired
		// (bounded by the inflightCBs cap), then join the size-bucketed pool.
		std::multimap<size_t, id<MTLBuffer>> bufPool;
		std::deque<std::pair<id<MTLBuffer>, uint64_t>> bufRetire;
		size_t pooledBytes = 0;
		uint64_t presentGen = 0;
		std::map<std::pair<int, int>, id<MTLSamplerState>> samplers;
		std::map<std::array<uint32_t, 8>, id<MTLSamplerState>> samplersFull;
		std::map<std::pair<void*, uint32_t>, id<MTLTexture>> sliceViews;

		// Push into the arena (ARC retains); returns the object.
		id<NSObject> retain(id<NSObject> obj)
		{
			if (obj)
			{
				arena.push_back(obj);
				g_mtlTexCreated++; // 3D/cube/array textures route here (leakbeat)
			}
			return obj;
		}
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

	// launch131: Present() carries the leakbeat (see top of file).
	// p6: exported so render-layer probes can gate on real frame progress
	// (encoder counts burn during the 3.5-min load screen and are useless).
	uint64_t g_mtlPresentCount = 0;
	void MetalDevice::Present(void* commandBuffer)
	{
		static uint64_t s_presentN = 0;
		g_mtlPresentCount = ++s_presentN;
		if (s_presentN % 120 == 0)
		{
			// launch132: live arena BYTES (buffers: exact length; textures:
			// w*h*4*4/3 rough) — separates engine-side retention from
			// driver-side retention of released resources.
			unsigned long long bufMB = 0, texMB = 0;
			for (id<NSObject> o : m_impl->arena)
			{
				if ([o isKindOfClass:[NSObject class]] && [o respondsToSelector:@selector(textureType)])
				{
					id<MTLTexture> t = (id<MTLTexture>)o;
					texMB += (unsigned long long)t.width * t.height * 4ull * 4 / 3;
				}
				else if ([o respondsToSelector:@selector(length)])
					bufMB += [(id<MTLBuffer>)o length];
			}
			fprintf(stderr, "- p5 leakbeat: present=%llu rss=%lluMB tex=%llu buf=%llu rel=%llu liveBufMB=%llu liveTexMB~=%llu pooledMB=%llu retireQ=%llu\n",
			        (unsigned long long)s_presentN,
			        (unsigned long long)(MtlCurRSSBytes() >> 20),
			        (unsigned long long)g_mtlTexCreated.load(),
			        (unsigned long long)g_mtlBufCreated.load(),
			        (unsigned long long)g_mtlResReleased.load(),
			        bufMB >> 20, texMB >> 20,
			        (unsigned long long)(m_impl->pooledBytes >> 20),
			        (unsigned long long)m_impl->bufRetire.size());
		}
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
		// launch133: bounded CPU ahead-run. GL's SwapBuffers blocked; here a
		// committed CB pins every buffer it encoded until it retires, so the
		// marsh staging churn (~10 MB-scale buffers/s) grew RSS unboundedly
		// (launch131: 30GB with arena counts balanced).
		if (cb)
		{
			m_impl->inflightCBs.push_back(cb);
			const size_t cap =
			    (m_impl->layer ? (size_t)m_impl->layer.maximumDrawableCount : 3u) + 1u;
			while (m_impl->inflightCBs.size() > cap)
			{
				[m_impl->inflightCBs.front() waitUntilCompleted];
				m_impl->inflightCBs.pop_front();
			}
			// launch301 experiment: XR_P5_SYNC=1 drains every CB each frame
			// (fully synchronous GPU). If release-mode draws land with this,
			// the black world is a CPU-ahead-of-GPU race, not state.
			static const bool s_syncDrain = !!getenv("XR_P5_SYNC");
			if (s_syncDrain)
			{
				while (!m_impl->inflightCBs.empty())
				{
					[m_impl->inflightCBs.front() waitUntilCompleted];
					m_impl->inflightCBs.pop_front();
				}
			}
			// launch134: retire released buffers — reusable only after every
			// CB that could have encoded them retired (the wait above bounds
			// the backlog to cap presents, so gen+cap+1 is a safe lag).
			++m_impl->presentGen;
			while (!m_impl->bufRetire.empty() &&
			       m_impl->bufRetire.front().second + cap + 1 <= m_impl->presentGen)
			{
				id<MTLBuffer> b = m_impl->bufRetire.front().first;
				m_impl->bufRetire.pop_front();
				const size_t len = [b length];
				if (len <= (size_t(64) << 20)) // >=64MB one-offs: really free
				{
					m_impl->bufPool.emplace(len, b);
					m_impl->pooledBytes += len;
					while (m_impl->pooledBytes > (size_t(1536) << 20) && !m_impl->bufPool.empty())
					{
						auto last = std::prev(m_impl->bufPool.end());
						m_impl->pooledBytes -= [last->second length];
						m_impl->bufPool.erase(last);
					}
				}
			}
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

	void* MetalDevice::BufferContents(void* buffer)
	{
		id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
		return buf ? [buf contents] : nullptr;
	}

	size_t MetalDevice::BufferSize(void* buffer)
	{
		id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
		return buf ? (size_t)[buf length] : 0;
	}

	void* MetalDevice::NewBuffer(size_t bytes)
	{
		if (!m_impl->device || bytes == 0)
			return nullptr;
		// launch134: pool-first (see Impl::bufPool) — the driver retained the
		// GPU backing of released buffers (vmmap: IOAccelerator +6.4GB/45s),
		// so recycle instead of churning MB-scale allocations. Reuse is safe:
		// entries only become poolable after their last encoder retired.
		if (!m_impl->bufPool.empty())
		{
			auto pit = m_impl->bufPool.lower_bound(bytes);
			if (pit != m_impl->bufPool.end())
			{
				id<MTLBuffer> reuse = pit->second;
				m_impl->bufPool.erase(pit);
				m_impl->pooledBytes -= [reuse length];
				m_impl->arena.push_back(reuse);
				g_mtlBufCreated++;
				return (__bridge void*)reuse;
			}
		}
		id<MTLBuffer> buf = [m_impl->device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		if (buf)
		{
			m_impl->arena.push_back(buf); // device-owned arena; borrowed handle back
			g_mtlBufCreated++; // leakbeat
		}
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
		// p6 wvp13: with the RT-dump knob on, make screen-sized RTs readable
		// (incl. the framebufferOnly gbuffer) so rtdump can actually read them.
		static const bool s_rtdAll = !!getenv("XR_METAL_RTDUMP");
		if (shaderReadable || !framebufferOnly || (s_rtdAll && w >= 1024 && h >= 600))
			td.usage |= MTLTextureUsageShaderRead;
		id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:td];
		if (tex)
		{
			m_impl->arena.push_back(tex);
			g_mtlTexCreated++; // leakbeat
		}
		return (__bridge void*)tex;
	}

	void MetalDevice::ReleaseResource(void* obj)
	{
		if (!obj)
			return;
		// p5 launch221: let the render layer drop raw handles to this resource
		// BEFORE ARC retires it (dangling-id crash guard, see g_texReleaseHook).
		if (g_texReleaseHook)
			g_texReleaseHook(obj);
		// p5 launch221: cached slice views keyed by this texture must die with
		// it (allocator address reuse would otherwise hand out stale views).
		for (auto it = m_impl->sliceViews.begin(); it != m_impl->sliceViews.end();)
			it = (it->first.first == obj) ? m_impl->sliceViews.erase(it) : std::next(it);
		id<NSObject> target = (__bridge id<NSObject>)obj;
		// launch134: MTLBuffers (respond to -length; textures don't) go to the
		// pool retire queue instead of being dropped — deferred recycling
		// until the GPU is done with them (see Present).
		const bool isBuffer = [target respondsToSelector:@selector(length)];
		for (auto it = m_impl->arena.begin(); it != m_impl->arena.end(); ++it)
		{
			if (*it == target)
			{
				if (isBuffer)
					m_impl->bufRetire.emplace_back((id<MTLBuffer>)*it, m_impl->presentGen);
				m_impl->arena.erase(it);
				g_mtlResReleased++; // leakbeat
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

	// ---------------------------------------------------------------------------
	// p5 t2 renderer substrate additions (device-layer contract)
	// ---------------------------------------------------------------------------

	static MTLTextureDescriptor* baseDesc(MTLPixelFormat fmt, uint32_t w, uint32_t h, uint32_t mips,
	                                      bool framebufferOnly, bool shaderReadable)
	{
		MTLTextureDescriptor* td = [MTLTextureDescriptor new];
		td.pixelFormat = fmt;
		td.width = w;
		td.height = h;
		td.mipmapLevelCount = mips == 0 ? (NSUInteger)(std::log2((double)(w > h ? w : h))) + 1
		                  : mips > 1   ? mips
		                               : 1;
		td.usage = MTLTextureUsageRenderTarget;
		if (shaderReadable || !framebufferOnly ||
		    (w >= 1024 && h >= 600 && getenv("XR_METAL_RTDUMP")))
			td.usage |= MTLTextureUsageShaderRead;
		return td;
	}

	void* MetalDevice::NewTexture3D(uint32_t w, uint32_t h, uint32_t d, uint32_t mips, int pixelFormat,
	                                bool shaderReadable)
	{
		if (!m_impl->device || w == 0 || h == 0 || d == 0)
			return nullptr;
		MTLTextureDescriptor* td = baseDesc((MTLPixelFormat)pixelFormat, w, h, mips, /*fbOnly*/ false, shaderReadable);
		td.textureType = MTLTextureType3D;
		td.depth = d;
		td.usage = MTLTextureUsageShaderRead; // volumes are sampled, never rendered to
		id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:td];
		return (__bridge void*)m_impl->retain(tex);
	}

	void* MetalDevice::NewTextureCube(uint32_t size, uint32_t mips, int pixelFormat,
	                                  bool framebufferOnly, bool shaderReadable)
	{
		if (!m_impl->device || size == 0)
			return nullptr;
		MTLTextureDescriptor* td = baseDesc((MTLPixelFormat)pixelFormat, size, size, mips, framebufferOnly, shaderReadable);
		td.textureType = MTLTextureTypeCube;
		td.arrayLength = 1;
		id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:td];
		return (__bridge void*)m_impl->retain(tex);
	}

	void* MetalDevice::NewTexture2DArray(uint32_t w, uint32_t h, uint32_t count, uint32_t mips, int pixelFormat,
	                                     bool framebufferOnly, bool shaderReadable)
	{
		if (!m_impl->device || w == 0 || h == 0 || count == 0)
			return nullptr;
		MTLTextureDescriptor* td = baseDesc((MTLPixelFormat)pixelFormat, w, h, mips, framebufferOnly, shaderReadable);
		td.textureType = MTLTextureType2DArray;
		td.arrayLength = count;
		id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:td];
		return (__bridge void*)m_impl->retain(tex);
	}

	void* MetalDevice::TextureSliceView(void* texture, uint32_t slice)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex)
			return nullptr;
		if (tex.textureType == MTLTextureType2D)
			return texture; // convenience: plain 2D returns itself
		auto key = std::make_pair(texture, slice);
		auto it = m_impl->sliceViews.find(key);
		if (it != m_impl->sliceViews.end())
			return (__bridge void*)it->second;
		id<MTLTexture> view = [tex newTextureViewWithPixelFormat:tex.pixelFormat
														textureType:MTLTextureType2D
														   levels:NSMakeRange(0, tex.mipmapLevelCount)
														   slices:NSMakeRange(slice, 1)];
		if (view)
			m_impl->sliceViews[key] = view; // map holds it; parent texture keeps storage alive
		return (__bridge void*)view;
	}

	void* MetalDevice::SamplerFull(const SamplerDesc& desc)
	{
		if (!m_impl->device)
			return nullptr;
		std::array<uint32_t, 8> key{};
		key[0] = (uint32_t)desc.addressU | ((uint32_t)desc.addressV << 3) | ((uint32_t)desc.addressW << 6) |
		         ((uint32_t)desc.minFilter << 9) | ((uint32_t)desc.magFilter << 10) | ((uint32_t)desc.mipFilter << 11);
		key[1] = (uint32_t)desc.maxAnisotropy;
		key[2] = (uint32_t)desc.compareFunc;
		key[3] = (uint32_t)desc.borderColor;
		key[4] = *(const uint32_t*)&desc.lodBias;
		key[5] = *(const uint32_t*)&desc.minLod;
		key[6] = *(const uint32_t*)&desc.maxLod;
		auto it = m_impl->samplersFull.find(key);
		if (it != m_impl->samplersFull.end())
			return (__bridge void*)it->second;

		auto am = [](int m) {
			switch (m)
			{
			case 1: return MTLSamplerAddressModeRepeat;
			case 2: return MTLSamplerAddressModeMirrorRepeat;
			case 3: return MTLSamplerAddressModeClampToBorderColor;
			default: return MTLSamplerAddressModeClampToEdge;
			}
		};
		MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
		sd.sAddressMode = am(desc.addressU);
		sd.tAddressMode = am(desc.addressV);
		sd.rAddressMode = am(desc.addressW);
		const bool aniso = desc.maxAnisotropy > 1;
		sd.minFilter = (aniso || desc.minFilter == 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
		sd.magFilter = (aniso || desc.magFilter == 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
		sd.mipFilter = desc.mipFilter == 1 ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
		if (aniso)
		{
			// DX9 state caches can carry out-of-range anisotropy; Metal
			// rejects >16 with an ObjC exception (terminate without catch).
			int a = desc.maxAnisotropy;
			if (a > 16)
				a = 16;
			sd.maxAnisotropy = (NSUInteger)a;
		}
		// minLod/maxLod/lodAccuracy/lodBias are not (portably) declared by the
		// CLT SDK's MTLSamplerDescriptor although the runtime implements them
		// since Metal 1 — set via KVC (bypasses SDK declaration/availability gaps).
		// SDK/runtime naming across macOS versions: pre-Metal4 declared
		// lodMinClamp/lodMaxClamp + mipLODBias (later lodBias, gated
		// macos(26.0) here while our deployment target is older). KVC with a
		// fallback chain covers both runtimes without availability issues;
		// unknown keys throw NSUnknownKeyException (uncaught = terminate)
		// so every attempt is exception-guarded.
		auto finiteClamp = [](float v, float lo, float hi, float fallback) {
			return std::isfinite(v) ? std::min(std::max(v, lo), hi) : fallback;
		};
		const float lodBias = finiteClamp(desc.lodBias, -16.f, 16.f, 0.f);
		float minLod = finiteClamp(desc.minLod, 0.f, 1000.f, 0.f);
		float maxLod = finiteClamp(desc.maxLod, 0.f, 1000.f, 1000.f);
		if (maxLod < minLod)
			maxLod = minLod;
		auto kvc = [](id o, NSString* k, float v) {
			@try
			{
				[o setValue:@(v) forKey:k];
				return true;
			}
			@catch (NSException*)
			{
				return false;
			}
		};
		if (!kvc(sd, @"lodMinClamp", minLod))
			kvc(sd, @"lodMinClamp", minLod);
		if (!kvc(sd, @"lodMaxClamp", maxLod))
			kvc(sd, @"lodMaxClamp", maxLod);
		if (!kvc(sd, @"lodBias", lodBias))
			kvc(sd, @"mipLODBias", lodBias);
		switch (desc.borderColor)
		{
		case 1: sd.borderColor = MTLSamplerBorderColorOpaqueWhite; break;
		case 2: sd.borderColor = MTLSamplerBorderColorTransparentBlack; break;
		default: sd.borderColor = MTLSamplerBorderColorOpaqueBlack; break;
		}
		if (desc.compareFunc >= 0)
		{
			// compareFunction alone enables depth-compare sampling on macOS
			// (MTLSamplerCompareMode is not in this SDK).
			if (desc.compareFunc <= (int)MTLCompareFunctionNever)
				sd.compareFunction = (MTLCompareFunction)desc.compareFunc;
			else
				fprintf(stderr, "! xrRenderMetal: SamplerFull bad compareFunc %d ignored\n",
				        desc.compareFunc);
		}
		id<MTLSamplerState> s = nil;
		@try
		{
			s = [m_impl->device newSamplerStateWithDescriptor:sd];
		}
		@catch (NSException* e)
		{
			fprintf(stderr,
			        "! xrRenderMetal: sampler creation failed: %s (%s) aniso=%d bias=%g lod=[%g,%g]\n",
			        e.name.UTF8String, e.reason.UTF8String, desc.maxAnisotropy, (double)lodBias,
			        (double)minLod, (double)maxLod);
			s = nil;
		}
		if (s)
			m_impl->samplersFull[key] = s;
		return (__bridge void*)s;
	}

	bool MetalDevice::WriteTextureBlocks(void* texture, uint32_t slice, uint32_t mip, const void* data,
	                                     uint32_t w, uint32_t h, uint32_t blockBytes, std::string& error)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex || !data)
		{
			error = "null texture/data";
			return false;
		}
		const NSUInteger rowBytes = ((NSUInteger)(w + 3) / 4) * blockBytes;
		// 3D volumes pick the z-slice via region.origin.z (slice: ignored);
		// cube faces / array slices via the slice: argument (origin.z must be 0).
		const bool is3D = tex.textureType == MTLTextureType3D;
		const MTLRegion region = MTLRegionMake3D(0, 0, is3D ? (NSInteger)slice : 0, (NSInteger)w, (NSInteger)h, 1);
		[tex replaceRegion:region
			  mipmapLevel:mip
					slice:is3D ? 0 : slice
				withBytes:data
			  bytesPerRow:rowBytes
			bytesPerImage:rowBytes * ((NSUInteger)(h + 3) / 4)];
		return true;
	}

	bool MetalDevice::WriteTextureRegion(void* texture, uint32_t slice, uint32_t mip, const void* pixels,
	                                     uint32_t w, uint32_t h, uint32_t bytesPerPixel, std::string& error)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex || !pixels)
		{
			error = "null texture/pixels";
			return false;
		}
		const NSUInteger rowBytes = (NSUInteger)bytesPerPixel * w;
		if (tex.textureType == MTLTextureType2D && mip == 0 && slice == 0)
		{
			[tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels bytesPerRow:rowBytes];
			return true;
		}
		// 3D volumes pick the z-slice via region.origin.z (slice: ignored);
		// cube faces / array slices via the slice: argument (origin.z must be 0).
		const bool is3D = tex.textureType == MTLTextureType3D;
		const MTLRegion region = MTLRegionMake3D(0, 0, is3D ? (NSInteger)slice : 0, (NSInteger)w, (NSInteger)h, 1);
		[tex replaceRegion:region
			  mipmapLevel:mip
					slice:is3D ? 0 : slice
				withBytes:pixels
			  bytesPerRow:rowBytes
			bytesPerImage:(tex.textureType == MTLTextureType3D ? rowBytes * h : 0)];
		return true;
	}

	bool MetalDevice::ReadbackSlice(void* texture, void* dst, uint32_t bytesPerRow, uint32_t w, uint32_t h,
	                                uint32_t slice, uint32_t mip, std::string& error)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex)
		{
			error = "null texture";
			return false;
		}
		if ((tex.usage & MTLTextureUsageShaderRead) == 0)
		{
			error = "texture is framebufferOnly — not readable";
			return false;
		}
		// Self-contained synchronous readback: a DEDICATED command buffer
		// blits the slice into a shared buffer and waits — getBytes on the
		// live texture would race uncommitted frame work (the frame CB is not
		// committed when the present-time screenshot runs).
		id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)Queue();
		if (!queue)
		{
			error = "no command queue";
			return false;
		}
		// p5 launch181: BC-compressed textures need block-aligned srcBpr —
		// w*TextureBpp is wrong for them (BC1 = 0.5 B/px) and produced
		// garbage reads (the S13tex "96% black" artifact).
		NSUInteger blockBytes = 0;
		switch (tex.pixelFormat)
		{
		case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:
		case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm:
			blockBytes = 8; break;
		case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB:
		case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
		case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm:
		case MTLPixelFormatBC6H_RGBUfloat: case MTLPixelFormatBC6H_RGBFloat:
		case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
			blockBytes = 16; break;
		default: break;
		}
		const NSUInteger srcBpr = blockBytes ? (((w + 3) / 4) * blockBytes)
		                                     : ((NSUInteger)w * TextureBpp(texture));
		const NSUInteger sliceBytes =
		    blockBytes ? srcBpr * ((h + 3) / 4) : srcBpr * h;
		void* stagingHandle = NewBuffer(sliceBytes ? sliceBytes : 1);
		id<MTLBuffer> staging = (__bridge id<MTLBuffer>)stagingHandle;
		if (!staging)
		{
			error = "staging alloc failed";
			return false;
		}
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		// Depth planes REQUIRE MTLBlitOptionDepthFloat on copy-to-buffer
		// (tolerated-but-undefined with None in release; hard assertion under
		// MTL_DEBUG_LAYER — launch108 crash).
		MTLBlitOption blitOpt = MTLBlitOptionNone;
		if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
			blitOpt = MTLBlitOptionDepthFromDepthStencil;
		[blit copyFromTexture:tex
		          sourceSlice:(NSUInteger)slice
		          sourceLevel:(NSUInteger)mip
		         sourceOrigin:MTLOriginMake(0, 0, 0)
		           sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
		             toBuffer:staging
		       destinationOffset:0
		  destinationBytesPerRow:(NSUInteger)srcBpr
		destinationBytesPerImage:(NSUInteger)sliceBytes
		                options:blitOpt];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		const uint8_t* src = (const uint8_t*)[staging contents];
		const NSUInteger copyBpr = bytesPerRow < (uint32_t)srcBpr ? bytesPerRow : (uint32_t)srcBpr;
		// BC rows are 4px tall — looping `h` rows overran dst by 4x (181 crash).
		const NSUInteger copyRows = blockBytes ? ((h + 3) / 4) : (NSUInteger)h;
		for (NSUInteger r = 0; r < copyRows; ++r)
			std::memcpy((uint8_t*)dst + (size_t)r * bytesPerRow, src + (size_t)r * srcBpr, copyBpr);
		ReleaseResource(stagingHandle);
		return true;
	}

	// Self-contained depth clear to 1.0 (own command buffer + wait). DX/GL
	// depth surfaces conventionally begin at far (1.0); Metal zero-fills, and
	// the engine skips the sun-shadow phase clear when the sun is inactive —
	// a zeroed smap then reads as all-shadow and kills the direct light.
	void MetalDevice::ClearDepthOne(void* texture)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex)
			return;
		if (tex.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 && tex.pixelFormat != MTLPixelFormatDepth32Float)
			return;
		id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)Queue();
		if (!queue)
			return;
		id<MTLCommandBuffer> cb = [queue commandBuffer];
		MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
		rpd.depthAttachment.texture = tex;
		rpd.depthAttachment.loadAction = MTLLoadActionClear;
		rpd.depthAttachment.storeAction = MTLStoreActionStore;
		rpd.depthAttachment.clearDepth = 1.0;
		if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
		{
			rpd.stencilAttachment.texture = tex;
			rpd.stencilAttachment.loadAction = MTLLoadActionClear;
			rpd.stencilAttachment.storeAction = MTLStoreActionStore;
			rpd.stencilAttachment.clearStencil = 0;
		}
		id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
		[e endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
	}

	uint32_t MetalDevice::TextureBpp(void* texture)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!tex)
			return 0;
		switch (tex.pixelFormat)
		{
		case MTLPixelFormatR8Unorm:
		case MTLPixelFormatR8Unorm_sRGB: return 1;
		case MTLPixelFormatR16Unorm:
		case MTLPixelFormatR16Float: return 2;
		case MTLPixelFormatRGBA8Unorm:
		case MTLPixelFormatRGBA8Unorm_sRGB:
		case MTLPixelFormatBGRA8Unorm:
		case MTLPixelFormatBGRA8Unorm_sRGB:
		case MTLPixelFormatDepth32Float:
		case MTLPixelFormatR32Float: return 4;
		case MTLPixelFormatRGBA16Unorm:
		case MTLPixelFormatRGBA16Float: return 8;
		case MTLPixelFormatRGBA32Float: return 16;
		default: return 4; // renderer uploads decode to 8-bit RGBA
		}
	}

	int MetalDevice::TextureFormat(void* texture)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		return tex ? (int)tex.pixelFormat : 0;
	}

	void MetalDevice::TextureDims(void* texture, uint32_t* w, uint32_t* h)
	{
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (w)
			*w = tex ? (uint32_t)tex.width : 0;
		if (h)
			*h = tex ? (uint32_t)tex.height : 0;
	}

	void MetalDevice::GenerateMipmaps(void* commandBuffer, void* texture)
	{
		id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)commandBuffer;
		id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
		if (!cb || !tex || tex.mipmapLevelCount < 2)
			return;
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit generateMipmapsForTexture:tex];
		[blit endEncoding];
	}

	void MetalDevice::BlitTexture(void* commandBuffer, void* srcTex, void* dstTex)
	{
		id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)commandBuffer;
		id<MTLTexture> src = (__bridge id<MTLTexture>)srcTex;
		id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;
		if (!cb || !src || !dst)
			return;
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
					 sourceSize:MTLSizeMake(src.width, src.height, 1)
					toTexture:dst destinationSlice:0 destinationLevel:0
				destinationOrigin:MTLOriginMake(0, 0, 0)];
		[blit endEncoding];
	}

	void MetalDevice::BlitTextureScaled(void* commandBuffer, void* srcTex, void* dstTex,
	                                    uint32_t srcW, uint32_t srcH, uint32_t dstW, uint32_t dstH)
	{
		// Blit encoders cannot scale; same-size copy fast path, otherwise the
		// caller (present/PP flip) goes through the render-pass blit in
		// mtlRuntime.mm. Here: clamp to overlapping extent copy.
		id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)commandBuffer;
		id<MTLTexture> src = (__bridge id<MTLTexture>)srcTex;
		id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;
		if (!cb || !src || !dst)
			return;
		const uint32_t w = srcW < dstW ? srcW : dstW;
		const uint32_t h = srcH < dstH ? srcH : dstH;
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
					 sourceSize:MTLSizeMake(w, h, 1)
					toTexture:dst destinationSlice:0 destinationLevel:0
				destinationOrigin:MTLOriginMake(0, 0, 0)];
		[blit endEncoding];
	}

} // namespace xray::metal
