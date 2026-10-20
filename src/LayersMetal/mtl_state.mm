// mtl_state.mm — pipeline state cache implementation (p5 t2).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_state.h"

#include <unordered_map>

namespace xray::metal
{
	struct MetalStateCache::Impl
	{
		std::unordered_map<uint64_t, id<MTLRenderPipelineState>> cache;
		std::unordered_map<uint64_t, id<MTLDepthStencilState>> depthStates;
	};

	static uint64_t HashDesc(const PipelineDesc& d)
	{
		uint64_t h = 1469598103934665603ull; // FNV-1a 64
		auto mix = [&h](uint64_t v)
		{
			for (int i = 0; i < 8; i++)
			{
				h ^= (v >> (i * 8)) & 0xff;
				h *= 1099511628211ull;
			}
		};
		mix((uint64_t)(uintptr_t)d.vs);
		mix((uint64_t)(uintptr_t)d.ps);
		mix(d.stride);
		mix(d.vbSlot);
		mix(d.attrs.size());
		for (const VertexAttr& a : d.attrs)
		{
			mix(a.index);
			mix(a.offset);
			mix(a.format);
		}
		mix(d.depthEnabled | (d.depthWrite << 1) | (d.blendAlpha << 2));
		mix((uint64_t)d.colorFormat);
		mix((uint64_t)d.depthFormat);
		return h;
	}

	MetalStateCache::MetalStateCache() : m_impl(new Impl()) {}
	MetalStateCache::~MetalStateCache() { delete m_impl; }

	void* MetalStateCache::Pipeline(void* device, const PipelineDesc& desc, std::string& error)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
		if (!dev || !desc.vs || !desc.ps)
		{
			error = "Pipeline: null device or function";
			return nullptr;
		}
		uint64_t key = HashDesc(desc);
		auto it = m_impl->cache.find(key);
		if (it != m_impl->cache.end())
			return (__bridge void*)it->second;

		MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = (__bridge id<MTLFunction>)desc.vs;
		pd.fragmentFunction = (__bridge id<MTLFunction>)desc.ps;
		if (!desc.attrs.empty())
		{
			MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
			vd.layouts[desc.vbSlot].stride = desc.stride;
			vd.layouts[desc.vbSlot].stepFunction = MTLVertexStepFunctionPerVertex;
			for (const VertexAttr& a : desc.attrs)
			{
				vd.attributes[a.index].format = (MTLVertexFormat)a.format;
				vd.attributes[a.index].offset = a.offset;
				vd.attributes[a.index].bufferIndex = desc.vbSlot;
			}
			pd.vertexDescriptor = vd;
		}
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)desc.colorFormat;
		if (desc.depthFormat != 0)
			pd.depthAttachmentPixelFormat = (MTLPixelFormat)desc.depthFormat;
		if (desc.blendAlpha)
		{
			MTLRenderPipelineColorAttachmentDescriptor* ca = pd.colorAttachments[0];
			ca.blendingEnabled = YES;
			ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
			ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
			ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		}

		NSError* nserr = nil;
		id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&nserr];
		if (!pso)
		{
			error = nserr ? std::string([nserr.localizedDescription UTF8String]) : std::string("pipeline creation failed");
			return nullptr;
		}
		m_impl->cache[key] = pso;
		return (__bridge void*)pso;
	}

	void* MetalStateCache::DepthState(void* device, bool enabled, bool write)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
		if (!dev)
			return nullptr;
		uint64_t key = (enabled ? 1 : 0) | (write ? 2 : 0);
		auto it = m_impl->depthStates.find(key);
		if (it != m_impl->depthStates.end())
			return (__bridge void*)it->second;
		MTLDepthStencilDescriptor* dsd = [MTLDepthStencilDescriptor new];
		dsd.depthCompareFunction = enabled ? MTLCompareFunctionLess : MTLCompareFunctionAlways;
		dsd.depthWriteEnabled = write ? YES : NO;
		id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
		if (dss)
			m_impl->depthStates[key] = dss;
		return (__bridge void*)dss;
	}

	size_t MetalStateCache::Count() const { return m_impl->cache.size(); }
	void MetalStateCache::Clear() { m_impl->cache.clear(); }

} // namespace xray::metal
