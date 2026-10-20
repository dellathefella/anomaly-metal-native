#pragma once
// Metal device + CAMetalLayer swapchain behind a plain-C++ facade (pimpl),
// p5 t2. ObjC objects stay inside the .mm TU; the accessors hand out void*
// which Metal-backend .mm translation units cast back to id<...>.
//
// Swapchain contract mirrors the GL device layer (CHW::Present on macOS):
// while the window receives no frames (occluded, another Space, screen
// locked) Metal's nextDrawable blocks forever, so callers must SKIP THE
// FRAME when CanPresent() is false — not merely the present.

#include <cstdint>
#include <string>

namespace xray::metal
{

	class MetalDevice
	{
	public:
		MetalDevice();
		~MetalDevice();
		MetalDevice(const MetalDevice&) = delete;
		MetalDevice& operator=(const MetalDevice&) = delete;

		// MTLCreateSystemDefaultDevice + command queue.
		bool Create(std::string& error);

		// sdlWindow: SDL_Window* (SDL2). Makes the Cocoa contentView layer-backed
		// and attaches a CAMetalLayer (BGRA8, framebufferOnly). Idempotent per
		// window; re-attaching to a different window detaches the old layer.
		bool AttachToSDLWindow(void* sdlWindow, std::string& error);
		void Detach();

		// vsync: 0 = immediate, 1 = every display refresh (default), 2 = every other.
		void SetPresentInterval(int frames);

		// drawableSize in BACKING PIXELS (points * backingScaleFactor on HiDPI).
		void Resize(uint32_t widthPx, uint32_t heightPx);

		// False while the window is occluded/invisible, the screen is locked or
		// no layer/size is set. NextDrawable refuses while this is false.
		bool CanPresent() const;

		// Test/validation only: bypass the environment clauses of CanPresent()
		// (screen lock + window occlusion) so swapchain verification can run
		// while the display is locked. The game path must never set this:
		// presenting to a locked/occluded session wedges on nextDrawable.
		void SetIgnoreDisplayAvailability(bool ignore);

		// Opaque BORROWED handles, valid for this object's lifetime (cast back
		// to id<...> in .mm TUs).
		void* Device() const;   // id<MTLDevice>
		void* Queue() const;    // id<MTLCommandQueue>
		void* Layer() const;    // CAMetalLayer* (nil until attached)
		double BackingScale() const;
		uint32_t Width() const;
		uint32_t Height() const;

		// Acquire the next swapchain drawable; *colorTexture = drawable.texture
		// (id<MTLTexture>, borrowed until Present). Returns false (no error) when
		// CanPresent() is false or no drawable is currently available — caller
		// should skip the frame.
		bool NextDrawable(void** colorTexture, std::string& error);

		// Presents the drawable handed out by NextDrawable and commits the
		// command buffer (id<MTLCommandBuffer>). Safe to call with a null buffer
		// (drops the drawable).
		void Present(void* commandBuffer);

		// Copy a BGRA8/RGBA8 region of a texture into CPU memory
		// (texture: id<MTLTexture>). For validation/screenshot paths.
		bool Readback(void* texture, uint8_t* dst, uint32_t bytesPerRow, uint32_t w, uint32_t h, std::string& error);

		// --- Resource factories (p5 t2 substrate for the renderer backend).
		// Created objects live in the device's ownership arena and the returned
		// void* handles are BORROWED, valid until ReleaseResource() or device
		// teardown; backend classes (CTexture/CBuffer equivalents) call
		// ReleaseResource() in their destructors. ---
		void* NewBuffer(size_t bytes); // id<MTLBuffer>, shared storage (CPU+GPU)
		// CPU pointer to a shared-storage buffer's contents (nullptr for
		// non-buffer handles).
		void* BufferContents(void* buffer);
		size_t BufferSize(void* buffer); // allocated length in bytes
		// pixelFormat: MTLPixelFormat raw value (RGBA8Unorm=70, BGRA8Unorm=80,
		// Depth32Float=252...). mips=0 -> full mip chain.
		void* NewTexture2D(uint32_t w, uint32_t h, uint32_t mips, int pixelFormat,
		                   bool framebufferOnly, bool shaderReadable); // id<MTLTexture>
		void* NewTexture3D(uint32_t w, uint32_t h, uint32_t d, uint32_t mips, int pixelFormat,
		                   bool shaderReadable); // volume (water_sbumpvolume)
		void* NewTextureCube(uint32_t size, uint32_t mips, int pixelFormat,
		                     bool framebufferOnly, bool shaderReadable); // sky/envmap
		void* NewTexture2DArray(uint32_t w, uint32_t h, uint32_t count, uint32_t mips, int pixelFormat,
		                        bool framebufferOnly, bool shaderReadable); // details atlas
		// 2D view of one cube face / array slice / depth-array slice — used as
		// a render-pass attachment (Metal passes bind slices via views).
		// Cached per (texture, slice); borrowed, owned by the device.
		void* TextureSliceView(void* texture, uint32_t slice);
		// Cached sampler states. addressMode: 0=clamp 1=repeat 2=mirror;
		// filter: 0=nearest 1=linear. id<MTLSamplerState>, owned by the cache.
		void* Sampler(int addressMode, int filter);
		// Full DX9-mapped sampler (borders, anisotropy, LOD bias/clamp, depth
		// compare for shadow maps). Raw values documented inline. Cached.
		struct SamplerDesc
		{
			int addressU = 0, addressV = 0, addressW = 0; // 0=clamp 1=repeat 2=mirror 3=clamp-border
			int minFilter = 1, magFilter = 1, mipFilter = 1; // 0=nearest 1=linear
			int maxAnisotropy = 1; // 1..16 (forces linear min/mag when >1)
			float lodBias = 0.f;
			float minLod = 0.f, maxLod = 1000.f;
			int borderColor = 0; // 0=opaque black 1=opaque white 2=transparent black (border modes)
			int compareFunc = -1; // -1=off; else MTLCompareFunction raw (2=lessEqual) — depth textures
		};
		void* SamplerFull(const SamplerDesc& desc);
		// Drop an arena entry (buffer/texture). Safe with nullptr.
		void ReleaseResource(void* obj);
		// Replace a texture's mip0 with CPU pixels (BGRA8/RGBA8, region w x h).
		bool WriteTexture(void* texture, const void* pixels, uint32_t w, uint32_t h, std::string& error);
		// Generalized upload: pixels at (slice, mip), bytesPerPixel row pitch.
		bool WriteTextureRegion(void* texture, uint32_t slice, uint32_t mip, const void* pixels,
		                        uint32_t w, uint32_t h, uint32_t bytesPerPixel, std::string& error);
		// Compressed (BCn) upload: raw block data for one (slice, mip) image.
		// blockBytes = 8 (BC1/BC4) or 16 (BC2/3/5/6/7). Metal requires the
		// region to be block-aligned OR flush with the texture edge — DDS mips
		// satisfy that naturally.
		bool WriteTextureBlocks(void* texture, uint32_t slice, uint32_t mip, const void* data,
		                        uint32_t w, uint32_t h, uint32_t blockBytes, std::string& error);
		// Generalized CPU readback (needs ShaderRead usage).
		bool ReadbackSlice(void* texture, void* dst, uint32_t bytesPerRow, uint32_t w, uint32_t h,
		                   uint32_t slice, uint32_t mip, std::string& error);
		uint32_t TextureBpp(void* texture); // bytes per pixel of the texture format
		int TextureFormat(void* texture); // MTLPixelFormat raw value (0 on null)
		// Mipmap chain generation via a blit encoder on the given command
		// buffer (texture needs ShaderRead; generates from mip0 downward).
		void GenerateMipmaps(void* commandBuffer, void* texture);
		// Whole-texture copy (same format/extent) via blit encoder.
		void BlitTexture(void* commandBuffer, void* srcTex, void* dstTex);
		// Scaled/offset color blit (drawable flip path); NEAREST filtering.
		void BlitTextureScaled(void* commandBuffer, void* srcTex, void* dstTex,
		                       uint32_t srcW, uint32_t srcH, uint32_t dstW, uint32_t dstH);

		const char* DeviceName() const;

	private:
		struct Impl;
		Impl* m_impl;
	};

} // namespace xray::metal
