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
		uint32_t format; // MTLVertexFormat raw value (Float3=23, Float2=21...)
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

		size_t Count() const; // distinct cached pipelines (diagnostics/tests)
		void Clear();

	private:
		struct Impl;
		Impl* m_impl;
	};

} // namespace xray::metal
