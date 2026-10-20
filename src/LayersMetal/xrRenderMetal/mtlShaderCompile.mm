// mtlShaderCompile.mm — Metal compile bridge for the renderer (p5 t2).
//
// HLSL (already DX9->SM6 translated by the PC layer) -> DXC -> SPIR-V ->
// reflection (SPIRV-Cross) -> MSL -> id<MTLFunction>. The renderer layer
// (rmtl_shaders.cpp) owns include resolution, its own disk cache (MSL text +
// serialized reflection) and SPP pairing; this TU only turns source text
// into live functions on MtlSharedDevice().
//
// Device-side TU: no engine stdafx (ObjC BOOL rule).
#import <Metal/Metal.h>

#include "mtlShader.h"
#include "mtlRuntime.h" // MtlSharedDevice

#include "mtl_shader_compiler.h"
#include "mtl_spirv_reflect.h"

#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

// Contract types (MtlStageRefl, MtlSharedDevice) live in the render namespace.
namespace xray::render::RENDER_NAMESPACE
{
namespace
{
	using xray::metal::MetalShaderCompiler;
	using xray::metal::ShaderCompileResult;
	using xray::metal::ShaderReflection;
	using xray::metal::ShaderStage;

	MetalShaderCompiler g_compiler;
	std::once_flag g_init_once;
	std::atomic<bool> g_init_ok{ false };

	// Compiled MTLLibraries stay alive for the process: MTLFunction handles
	// escape this TU as borrowed void*s (shaders are session-lifetime;
	// _DeleteVS keeps the pair records but engine shaders are never truly
	// unloaded mid-session).
	std::mutex g_libsLock;
	std::vector<id<MTLLibrary>> g_libraries;

	id<MTLFunction> CreateFunction(NSString* mslSource, const char* entryName, const char* label,
	                               std::string& error)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)MtlSharedDevice();
		if (!dev)
		{
			error = "no Metal device";
			return nil;
		}
		NSError* err = nil;
		id<MTLLibrary> lib = [dev newLibraryWithSource:mslSource options:nil error:&err];
		if (!lib)
		{
			error = err ? std::string("msl compile: ") + [[err localizedDescription] UTF8String]
			            : std::string("msl compile: unknown");
			return nil;
		}
		{
			std::lock_guard<std::mutex> lock(g_libsLock);
			g_libraries.push_back(lib);
		}
		id<MTLFunction> fn = [lib newFunctionWithName:@(entryName)];
		if (!fn)
			fn = [lib newFunctionWithName:@"main"]; // SPIRV-Cross may rename
		if (!fn)
		{
			error = std::string("entry '") + entryName + "' not found in MSL (" + label + ")";
			return nil;
		}
		return fn;
	}

	void FillRefl(MtlStageRefl& out, const ShaderReflection& refl)
	{
		out.cbufferSize = refl.cbufferSize;
		out.uniforms.clear();
		for (const auto& u : refl.uniforms)
		{
			MtlUniformRefl m;
			m.name = u.name;
			m.offset = u.offset;
			m.size = u.size;
			m.stride = u.stride;
			m.elements = u.elements;
			m.baseType = u.baseType;
			m.rows = u.rows;
			m.cols = u.cols;
			out.uniforms.push_back(std::move(m));
		}
		out.resources.clear();
		for (const auto& r : refl.resources)
		{
			MtlResourceRefl m;
			m.name = r.name;
			m.textureSlot = r.textureSlot;
			m.samplerSlot = r.samplerSlot;
			m.isSamplerOnly = r.isSamplerOnly;
			out.resources.push_back(std::move(m));
		}
		out.inputs.clear();
		for (const auto& i : refl.inputs)
		{
			MtlStageRefl::InputAttr m;
			m.semantic = i.semantic;
			m.attribute = i.attribute;
			m.components = i.components;
			m.isMatrixRow = i.isMatrixRow;
			out.inputs.push_back(std::move(m));
		}
	}
} // namespace (anon)

bool MtlShaderCompilerInit()
{
	std::call_once(g_init_once, [] {
		std::vector<std::string> dylibs;
#ifdef DXCOMPILER_PATH
		if (DXCOMPILER_PATH[0])
			dylibs.push_back(DXCOMPILER_PATH);
#endif
		dylibs.push_back("/opt/homebrew/lib/libdxcompiler.dylib");
		std::string exe;
#ifdef DXC_PATH
		if (DXC_PATH[0])
			exe = DXC_PATH;
#endif
		if (exe.empty())
			exe = "/opt/homebrew/bin/dxc";
		// No compiler-level MSL cache: the renderer caches MSL + reflection
		// together (rmtl_shaders.cpp), so keep the SPIR-V round trip honest.
		g_init_ok = g_compiler.Init(dylibs, exe, "");
	});
	return g_init_ok.load();
}

bool MetalCompileStage(MtlStageRefl& out, std::string* outMsl, char target, const char* name,
                       const char* translatedHlsl, const char* entry, std::string& error)
{
	if (!MtlShaderCompilerInit())
	{
		error = "DXC backend unavailable";
		return false;
	}
	const ShaderStage stage = target == 'v' ? ShaderStage::Vertex : ShaderStage::Pixel;

	ShaderCompileResult res;
	std::vector<uint32_t> spirv;
	if (!g_compiler.CompileWithSpirv(translatedHlsl, entry, stage, {}, res, spirv))
	{
		error = res.error.empty() ? "DXC compile failed" : res.error;
		if (!res.messages.empty())
			error += " | " + res.messages.substr(0, 512);
		return false;
	}

	ShaderReflection refl;
	std::vector<std::string> semantics;
	if (target == 'v')
		semantics = xray::metal::CollectInputSemantics(translatedHlsl, entry);
	if (!xray::metal::ReflectSpirv(spirv, semantics, refl, error))
		return false;

	id<MTLFunction> fn = CreateFunction([NSString stringWithUTF8String:res.msl.c_str()], entry, name, error);
	if (!fn)
		return false;

	out.function = (__bridge void*)fn;
	FillRefl(out, refl);
	if (outMsl)
		*outMsl = std::move(res.msl);
	return true;
}

bool MetalCreateStageFromMsl(MtlStageRefl& out, const char* name, const char* msl, const char* entry,
                             std::string& error)
{
	id<MTLFunction> fn = CreateFunction([NSString stringWithUTF8String:msl], entry, name, error);
	if (!fn)
		return false;
	out.function = (__bridge void*)fn;
	return true;
}

// --- reflection blob -----------------------------------------------------------
namespace
{
	void putU32(std::string& b, uint32_t v)
	{
		b.append(reinterpret_cast<const char*>(&v), 4);
}
	void putI32(std::string& b, int32_t v)
	{
		b.append(reinterpret_cast<const char*>(&v), 4);
	}
	void putStr(std::string& b, const std::string& s)
	{
		putU32(b, static_cast<uint32_t>(s.size()));
		b += s;
	}
	bool getU32(const char*& p, const char* end, uint32_t& v)
	{
		if (end - p < 4)
			return false;
		std::memcpy(&v, p, 4);
		p += 4;
		return true;
	}
	bool getI32(const char*& p, const char* end, int32_t& v)
	{
		if (end - p < 4)
			return false;
		std::memcpy(&v, p, 4);
		p += 4;
		return true;
	}
	bool getStr(const char*& p, const char* end, std::string& s)
	{
		uint32_t n = 0;
		if (!getU32(p, end, n) || static_cast<long>(end - p) < static_cast<long>(n))
			return false;
		s.assign(p, n);
		p += n;
		return true;
	}
} // namespace

std::string MtlSerializeReflection(const MtlStageRefl& refl)
{
	std::string b("MRS1", 4);
	putU32(b, refl.cbufferSize);
	putU32(b, static_cast<uint32_t>(refl.uniforms.size()));
	for (const auto& u : refl.uniforms)
	{
		putStr(b, u.name);
		putU32(b, u.offset);
		putU32(b, u.size);
		putU32(b, u.stride);
		putU32(b, u.elements);
		putI32(b, u.baseType);
		putI32(b, u.rows);
		putI32(b, u.cols);
	}
	putU32(b, static_cast<uint32_t>(refl.resources.size()));
	for (const auto& r : refl.resources)
	{
		putStr(b, r.name);
		putU32(b, r.textureSlot);
		putU32(b, r.samplerSlot);
		b += r.isSamplerOnly ? '\1' : '\0';
	}
	putU32(b, static_cast<uint32_t>(refl.inputs.size()));
	for (const auto& i : refl.inputs)
	{
		putStr(b, i.semantic);
		putU32(b, i.attribute);
		putU32(b, i.components);
		b += i.isMatrixRow ? '\1' : '\0';
	}
	return b;
}

bool MtlDeserializeReflection(const std::string& blob, MtlStageRefl& refl, std::string& error)
{
	if (blob.size() < 4 || blob.compare(0, 4, "MRS1") != 0)
	{
		error = "reflection blob: bad magic";
		return false;
	}
	const char* p = blob.data() + 4;
	const char* end = blob.data() + blob.size();
	uint32_t n = 0;
	if (!getU32(p, end, refl.cbufferSize))
		return false;
	if (!getU32(p, end, n))
		return false;
	refl.uniforms.resize(n);
	for (uint32_t i = 0; i < n; i++)
	{
		auto& u = refl.uniforms[i];
		if (!getStr(p, end, u.name) || !getU32(p, end, u.offset) || !getU32(p, end, u.size) ||
		    !getU32(p, end, u.stride) || !getU32(p, end, u.elements))
			return false;
		int32_t bt = 0, rows = 0, cols = 0;
		if (!getI32(p, end, bt) || !getI32(p, end, rows) || !getI32(p, end, cols))
			return false;
		u.baseType = bt;
		u.rows = rows;
		u.cols = cols;
	}
	if (!getU32(p, end, n))
		return false;
	refl.resources.resize(n);
	for (uint32_t i = 0; i < n; i++)
	{
		auto& r = refl.resources[i];
		if (!getStr(p, end, r.name) || !getU32(p, end, r.textureSlot) || !getU32(p, end, r.samplerSlot))
			return false;
		if (end - p < 1)
			return false;
		r.isSamplerOnly = *p++ != 0;
	}
	if (!getU32(p, end, n))
		return false;
	refl.inputs.resize(n);
	for (uint32_t i = 0; i < n; i++)
	{
		auto& in = refl.inputs[i];
		if (!getStr(p, end, in.semantic) || !getU32(p, end, in.attribute) || !getU32(p, end, in.components))
			return false;
		if (end - p < 1)
			return false;
		in.isMatrixRow = *p++ != 0;
	}
	return true;
}

MtlShaderPair* MtlMakeShaderPair(const char* name)
{
	auto* pair = new MtlShaderPair();
	pair->name = name ? name : "?";
	return pair;
}
} // namespace xray::render::RENDER_NAMESPACE
