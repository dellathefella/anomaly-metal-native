// mtl_state.mm — pipeline state cache implementation (p5 t2).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_state.h"
// relative include (file-dir based): substrate TU sits in LayersMetal/, the
// mapping header lives in the device-layer subdir.
#include "xrRenderMetal/mtl_dx9_map.h"

#include <mach/mach.h>

#include <cstdio>
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
		mix(d.colorFormats.size());
		for (int f : d.colorFormats)
			mix((uint64_t)f);
		mix((uint64_t)d.stencilFormat);
		// blend state: pack enums+mask (values are small ints / 4-bit mask)
		uint64_t b = 0;
		b |= (d.blend.enabled ? 1ull : 0);
		b |= (uint64_t)(d.blend.src & 0x1f) << 1;
		b |= (uint64_t)(d.blend.dst & 0x1f) << 6;
		b |= (uint64_t)(d.blend.op & 0x7) << 11;
		b |= (uint64_t)(d.blend.srcA & 0x1f) << 14;
		b |= (uint64_t)(d.blend.dstA & 0x1f) << 19;
		b |= (uint64_t)(d.blend.opA & 0x7) << 24;
		b |= (uint64_t)(d.blend.writeMask & 0x1f) << 27;
		mix(b);
		return h;
	}

	MetalStateCache::MetalStateCache() : m_impl(new Impl()) {}
	MetalStateCache::~MetalStateCache() { delete m_impl; }

	void* MetalStateCache::Pipeline(void* device, const PipelineDesc& desc, std::string& error)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
		if (!dev || !desc.vs || (!desc.ps && !desc.depthOnly))
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
		// p5: the DX9 rasterizer cull state is not wired into PipelineDesc yet
		// (t3). Metal's default (Back-cull + CCW front) silently culls the
		// UI/menu quads whose winding flips under the D3D-convention Y map,
		// so disable culling until the state plumbing lands. This SDK/runtime
		// moved cull/winding to encoder state (pipeline-descriptor props are
		// gone — KVC throws); set them per encoder below (applyEncoderState).
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
		if (desc.colorFormat >= 0)
			pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)desc.colorFormat;
		if (!desc.colorFormats.empty())
		{
			pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)desc.colorFormats[0];
			for (NSUInteger i = 1; i < desc.colorFormats.size() && i < 4; ++i)
				pd.colorAttachments[i].pixelFormat = (MTLPixelFormat)desc.colorFormats[i];
		}
		if (desc.depthFormat != 0)
			pd.depthAttachmentPixelFormat = (MTLPixelFormat)desc.depthFormat;
		if (desc.stencilFormat != 0)
		{
			pd.depthAttachmentPixelFormat = (MTLPixelFormat)desc.stencilFormat;
			pd.stencilAttachmentPixelFormat = (MTLPixelFormat)desc.stencilFormat;
		}
		const bool multiRT = !desc.colorFormats.empty();
		// p5 DIAG (launch155): blend-off experiment gate for the live PSO path.
		static const bool s_noBlend = [] {
			const char* e = getenv("XR_METAL_NOBLEND");
			return e && e[0] == '1';
		}();
		if (desc.blendAlpha && !multiRT)
		{
			MTLRenderPipelineColorAttachmentDescriptor* ca = pd.colorAttachments[0];
			ca.blendingEnabled = s_noBlend ? NO : YES;
			ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
			ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
			ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		}
		else if (multiRT || desc.blend.enabled)
		{
			// Full DX9 blend on all attachments (XRay binds one blend state
			// per pass; MRT g-buffer passes are blend-off).
			const NSUInteger count = multiRT ? (NSUInteger)desc.colorFormats.size() : 1;
			for (NSUInteger i = 0; i < count; ++i)
			{
				MTLRenderPipelineColorAttachmentDescriptor* ca = pd.colorAttachments[i];
				ca.blendingEnabled = desc.blend.enabled ? YES : NO;
				ca.rgbBlendOperation = (MTLBlendOperation)xray::render::RENDER_NAMESPACE::MtlMapBlendOp(desc.blend.op);
				ca.alphaBlendOperation = (MTLBlendOperation)xray::render::RENDER_NAMESPACE::MtlMapBlendOp(desc.blend.opA);
				ca.sourceRGBBlendFactor = (MTLBlendFactor)xray::render::RENDER_NAMESPACE::MtlMapBlend(desc.blend.src);
				ca.destinationRGBBlendFactor = (MTLBlendFactor)xray::render::RENDER_NAMESPACE::MtlMapBlend(desc.blend.dst);
				ca.sourceAlphaBlendFactor = (MTLBlendFactor)xray::render::RENDER_NAMESPACE::MtlMapBlend(desc.blend.srcA);
				ca.destinationAlphaBlendFactor = (MTLBlendFactor)xray::render::RENDER_NAMESPACE::MtlMapBlend(desc.blend.dstA);
				ca.writeMask = (MTLColorWriteMask)desc.blend.writeMask;
			}
		}

		NSError* nserr = nil;
		id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&nserr];
		if (!pso)
		{
			error = nserr ? std::string([nserr.localizedDescription UTF8String]) : std::string("pipeline creation failed");
			return nullptr;
		}
		m_impl->cache[key] = pso;
		// launch131 LEAK HEARTBEAT (strip in t6): PSO churn + RSS.
		{
			static uint64_t s_psoN = 0;
			if (++s_psoN % 100 == 0)
			{
				task_vm_info_data_t vi;
				mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
				unsigned long long rss = 0;
				if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &cnt) == KERN_SUCCESS)
					rss = (unsigned long long)((uint64_t)vi.internal + vi.compressed) >> 20;
				fprintf(stderr, "- p5 leakbeat: pso=%llu cached=%zu rss=%lluMB\n",
				        (unsigned long long)s_psoN, m_impl->cache.size(), rss);
			}
		}
		return (__bridge void*)pso;
	}

	void* MetalStateCache::DepthState(void* device, bool enabled, bool write)
	{
		DepthStencilDesc d;
		d.depthEnable = enabled;
		d.depthWrite = write;
		d.depthFunc = enabled ? 2 : 8; // D3D LESS / ALWAYS (legacy behavior)
		return DepthStateFull(device, d);
	}

	void* MetalStateCache::DepthStateFull(void* device, const DepthStencilDesc& desc)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
		if (!dev)
			return nullptr;
		using namespace xray::render::RENDER_NAMESPACE;
		uint64_t key = 0;
		key |= (desc.depthEnable ? 1ull : 0);
		key |= (uint64_t)(desc.depthFunc & 0xf) << 1;
		key |= (desc.depthWrite ? 1ull : 0) << 5;
		key |= (desc.stencilEnable ? 1ull : 0) << 6;
		key |= (uint64_t)(desc.func & 0xf) << 7;
		key |= (uint64_t)(desc.failOp & 0xf) << 11;
		key |= (uint64_t)(desc.passOp & 0xf) << 15;
		key |= (uint64_t)(desc.zFailOp & 0xf) << 19;
		key |= (uint64_t)(desc.readMask & 0xff) << 23;
		key |= (uint64_t)(desc.writeMask & 0xff) << 31;
		auto it = m_impl->depthStates.find(key);
		if (it != m_impl->depthStates.end())
			return (__bridge void*)it->second;
		// p5 DIAG (launch152): which depth-stencil states the live draws bind.
		{
			static int s_dssDiag = 0;
			if (s_dssDiag < 16)
			{
				fprintf(stderr, "- p5 DIAG DSSdiag: zE=%d zF=%d zW=%d sE=%d sF=%d rm=%X wm=%X\n",
				        desc.depthEnable ? 1 : 0, desc.depthFunc, desc.depthWrite ? 1 : 0,
				        desc.stencilEnable ? 1 : 0, desc.func, desc.readMask, desc.writeMask);
				s_dssDiag++;
			}
		}
		MTLDepthStencilDescriptor* dsd = [MTLDepthStencilDescriptor new];
		dsd.depthCompareFunction = (MTLCompareFunction)MtlMapCompare(desc.depthFunc);
		if (!desc.depthEnable)
			dsd.depthCompareFunction = MTLCompareFunctionAlways;
		// p5 DIAG (launch152): depth-test bypass experiment.
		{
			static const char* s_noDepth = getenv("XR_METAL_NODEPTH");
			if (s_noDepth && s_noDepth[0] == '1')
				dsd.depthCompareFunction = MTLCompareFunctionAlways;
		}
		dsd.depthWriteEnabled = desc.depthWrite ? YES : NO;
		if (desc.stencilEnable)
		{
			// p5 launch242: XR_P5_NOSTENCIL globally neutralizes stencil
			// (test always-pass, ops keep) to isolate state-test culling of
			// the sun accum cuboid. Temporary, strip in t6.
			static const char* s_noStencil = getenv("XR_P5_NOSTENCIL");
			if (s_noStencil && s_noStencil[0] == '1')
			{
				dsd.frontFaceStencil = nil;
				dsd.backFaceStencil = nil;
			}
			else
			{
			MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
			sd.stencilCompareFunction = (MTLCompareFunction)MtlMapCompare(desc.func);
			sd.stencilFailureOperation = (MTLStencilOperation)MtlMapStencilOp(desc.failOp);
			sd.depthFailureOperation = (MTLStencilOperation)MtlMapStencilOp(desc.zFailOp);
			sd.depthStencilPassOperation = (MTLStencilOperation)MtlMapStencilOp(desc.passOp);
			sd.readMask = desc.readMask;
			sd.writeMask = desc.writeMask;
			dsd.frontFaceStencil = sd;
			dsd.backFaceStencil = sd; // DX9 is single-sided
			}
		}
		id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
		// p6: nil DSS => applyEncoderState silently skips the bind => the
		// encoder keeps Metal's DEFAULT state (Always, no write) — the only
		// mechanism left that fits "dssg zW=1 but zb never written". The
		// DSS API has no error variant; dump the desc instead.
		if (!dss)
		{
			static int s_dssNil = 0;
			if (s_dssNil < 8)
			{
				s_dssNil++;
				fprintf(stderr, "! p6 DSSnil: zE=%d zF=%d zW=%d sE=%d sF=%d "
				        "ops=%d/%d/%d rm=%X wm=%X\n",
				        desc.depthEnable ? 1 : 0, desc.depthFunc,
				        desc.depthWrite ? 1 : 0, desc.stencilEnable ? 1 : 0,
				        desc.func, desc.failOp, desc.passOp, desc.zFailOp,
				        desc.readMask, desc.writeMask);
			}
		}
		if (dss)
			m_impl->depthStates[key] = dss;
		return (__bridge void*)dss;
	}

	size_t MetalStateCache::Count() const { return m_impl->cache.size(); }
	void MetalStateCache::Clear() { m_impl->cache.clear(); }

} // namespace xray::metal
