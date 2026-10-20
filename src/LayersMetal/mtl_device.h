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

		const char* DeviceName() const;

	private:
		struct Impl;
		Impl* m_impl;
	};

} // namespace xray::metal
