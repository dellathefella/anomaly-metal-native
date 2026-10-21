#pragma once
// Pipeline state cache over runtime-compiled MSL functions (p5 t2).
// The renderer backend resolves (VS, PS, vertex layout, fixed states, target
// formats) per pass; identical combinations must reuse one MTLPipelineState
// (creation is expensive). Plain-C++ facade; ObjC types stay in the .mm TU.

#include <cstdint>
#include <string>
#include <vector>

namespace xray::metal
{
	struct VertexAttr
	{
		uint32_t index;  // [[attribute(N)]] index — SPIRV-Cross emits HLSL
		                 // semantics in declaration order, keep it aligned.
		uint32_t offset; // bytes within the vertex stream (buffer slot 0)
		uint32_t format; // MTLVertexFormat raw value (Float=28, Float2=29,
		                 // Float3=30, Float4=31, Half=53, UChar4Normalized=9)
	};

	// DX9 blend state; src/dst/op fields carry RAW D3DBLEND/D3DBLENDOP values
	// (d3d9compat.hpp layout) — mapped via mtl_dx9_map.h inside the .mm.
	// writeMask = D3DCOLORWRITEENABLE bits (1=R 2=G 4=B 8=A).
	struct BlendDesc
	{
		bool enabled = false;
		int src = 5, dst = 8;       // D3DBLEND (SRCALPHA/INVDESTALPHA default)
		int op = 1;                 // D3DBLENDOP (ADD)
		int srcA = 5, dstA = 8;
		int opA = 1;
		uint32_t writeMask = 15;
	};

	struct PipelineDesc
	{
		void* vs = nullptr; // borrowed id<MTLFunction>
		void* ps = nullptr; // borrowed id<MTLFunction>
		std::vector<VertexAttr> attrs;
		uint32_t stride = 0;         // 0 + empty attrs = vertex-id-only VS
		uint32_t vbSlot = 0;         // buffer slot of the vertex stream; use 1+
		                             // when the VS also takes cbuffers (DXC b0
		                             // lands on [[buffer(0)]]).
		bool depthEnabled = false;   // less-equal depth test
		bool depthWrite = false;
		bool blendAlpha = false;     // src*srcAlpha + dst*(1-srcAlpha)
		int colorFormat = 80;        // MTLPixelFormat raw (BGRA8Unorm default)
		int depthFormat = 0;         // 0 = no depth attachment
		// Full-state extension (renderer path). When colorFormats is empty the
		// single colorFormat above is used (devicetest compatibility); when
		// blend.enabled is false AND blendAlpha false, blending stays off.
		std::vector<int> colorFormats; // up to 4 attachments, raw MTLPixelFormat
		int stencilFormat = 0;         // 0 = none (else same format as depth w/ stencil)
		bool depthOnly = false;        // nil fragmentFunction (DX9 null-PS passes, e.g. sun shadows)
		BlendDesc blend;
	};

	// Full DX9 depth+stencil state (raw D3DCMPFUNC/D3DSTENCILOP values; the
	// DX9 model is single-sided, applied to both Metal faces). stencilRef is
	// NOT part of the state — set per-encoder (setStencilReferenceValue).
	struct DepthStencilDesc
	{
		bool depthEnable = false;
		int depthFunc = 4;            // D3DCMPFUNC (LESSEQUAL)
		bool depthWrite = false;
		bool stencilEnable = false;
		uint32_t readMask = 0xff;     // D3D STENCILMASK
		uint32_t writeMask = 0xff;    // D3D STENCILWRITEMASK
		int func = 8;                 // D3DCMPFUNC stencil compare (ALWAYS)
		int failOp = 1, passOp = 1, zFailOp = 1; // D3DSTENCILOP (KEEP)
	};

	class MetalStateCache
	{
	public:
		MetalStateCache();
		~MetalStateCache();
		MetalStateCache(const MetalStateCache&) = delete;
		MetalStateCache& operator=(const MetalStateCache&) = delete;

		// Cached id<MTLRenderPipelineState> (borrowed; owned by the cache).
		// device: borrowed id<MTLDevice>. nullptr + error on failure.
		// NOTE: Metal pipelines do NOT carry depth-stencil state — bind the
		// DepthState() below on the encoder.
		void* Pipeline(void* device, const PipelineDesc& desc, std::string& error);

		// Cached id<MTLDepthStencilState> (borrowed): less-compare when enabled.
		void* DepthState(void* device, bool enabled, bool write);

		// Full depth+stencil variant (renderer path).
		void* DepthStateFull(void* device, const DepthStencilDesc& desc);

		size_t Count() const; // distinct cached pipelines (diagnostics/tests)
		void Clear();

	private:
		struct Impl;
		Impl* m_impl;
	};

} // namespace xray::metal
