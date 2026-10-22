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

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <tuple>
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

	// launch146: env-gated clip-convention fix injected into every compiled
	// VS (launch144/145 verdict: engine VS geometry is correct but dies at
	// Metal's clip test 0<=z<=w). XR_METAL_CLIPFIX=z => depth remap
	// z' = 0.5z + 0.5w; XR_METAL_CLIPFIX=w => w sign flip. Target check:
	// only VSes declare 'gl_Position [[position]]' (PSes carry
	// 'gl_FragCoord [[position]]'), and DXC MSL returns via 'return out;'.
	static NSString* MtlClipFixSource(NSString* src)
	{
		static int mode = -1;
		if (mode == -1)
		{
			const char* e = getenv("XR_METAL_CLIPFIX");
			mode = 0;
			if (e && !strcmp(e, "z"))
				mode = 1;
			else if (e && !strcmp(e, "w"))
				mode = 2;
			else if (e && !strcmp(e, "z2"))
				mode = 3;
			else if (e && !strcmp(e, "clamp"))
				mode = 4; // launch149 verdict: S12 min-clamp lands full coverage
		}
		if (!mode)
			return src;
		if ([src rangeOfString:@"gl_Position [[position]]"].location == NSNotFound)
			return src; // not a vertex shader
		NSMutableString* mu = [src mutableCopy];
		static NSString* patS = @"return out;";
		int n = 0;
		NSUInteger from = 0;
		NSRange r;
		while ((r = [mu rangeOfString:patS options:0
		                        range:NSMakeRange(from, mu.length - from)]).location !=
		       NSNotFound)
		{
			NSString* ins = mode == 1
			                    ? @"out.gl_Position.z = out.gl_Position.z * 0.5 + "
			                      @"out.gl_Position.w * 0.5;\n    return out;"
			                    : mode == 2 ? @"out.gl_Position.w = -out.gl_Position.w;\n    "
			                                  @"return out;"
			                                : mode == 3
			                                      ? @"out.gl_Position.z = out.gl_Position.z * 0.5 + "
			                                        @"out.gl_Position.w;\n    return out;"
			                                      : @"out.gl_Position.z = min(out.gl_Position.z, "
			                                        @"out.gl_Position.w * 0.9999);\n    return out;";
			[mu replaceCharactersInRange:r withString:ins];
			from = r.location + ins.length;
			n++;
		}
		if (n)
			fprintf(stderr, "- xrMetal CLIPFIX=%s injected x%d\n",
			        mode == 1 ? "z" : (mode == 2 ? "w" : (mode == 3 ? "z2" : "clamp")), n);
		return mu;
	}

	id<MTLFunction> CreateFunction(NSString* mslSource, const char* entryName, const char* label,
	                               std::string& error)
	{
		id<MTLDevice> dev = (__bridge id<MTLDevice>)MtlSharedDevice();
		if (!dev)
		{
			error = "no Metal device";
			return nil;
		}
		mslSource = MtlClipFixSource(mslSource);
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
			// SPIRV-Cross renames HLSL 'main' to 'main0'/... — locate the
			// actual entry by its [[vertex]]/[[fragment]] attributed line.
			static NSRegularExpression* re = [NSRegularExpression
				regularExpressionWithPattern:@"^\\s*(vertex|fragment|kernel)\\s+.*?\\b([A-Za-z_][A-Za-z0-9_]*)\\s*\\("
									 options:NSRegularExpressionAnchorsMatchLines
									   error:nil];
			NSTextCheckingResult* mt = re
				? [re firstMatchInString:mslSource options:0 range:NSMakeRange(0, mslSource.length)]
				: nil;
			if (mt)
				fn = [lib newFunctionWithName:[mslSource substringWithRange:[mt rangeAtIndex:2]]];
		}
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

	// --- MSL-native constant-block offset fix ---------------------------------
	// DXC -Zpr packs c-buffer members at row-major (c-register) offsets
	// (m_P@96, m_WVP@272) and SPIRV-Cross emits those members verbatim as MSL
	// types — but a float4x4 inside an MSL struct has 64-byte alignment, so the
	// Metal compiler silently shifts misaligned matrix members (m_P 96->128,
	// m_WVP 272->320). The engine constant table writes at the DXC offsets, so
	// the VS/PS would read the wrong bytes (garbage m_WVP => every world vertex
	// clipped; UI survives because stub shaders skip the transform). Recompute
	// reflection offsets against the emitted struct's *native* MSL layout so
	// staging places constants where the GPU actually reads them.
	static uint32_t MslAlignUp(uint32_t v, uint32_t a)
	{
		return a ? (v + a - 1) / a * a : v;
	}

	// Vector alignment: 1 comp -> comp size, 2 comps -> 2x, 3-4 comps -> 4x.
	static uint32_t MslVecAlign(uint32_t n, uint32_t comp)
	{
		return n == 1 ? comp : (n == 2 ? 2 * comp : 4 * comp);
	}

	// Size/alignment of an MSL scalar/vector/matrix type (packed_* included).
	// Returns false for unrecognized types (caller bails — safer than a partial
	// relayout).
	static bool MslTypeSizeAlign(const std::string& typeIn, uint32_t& size, uint32_t& align)
	{
		std::string t = typeIn;
		bool packed = false;
		if (t.rfind("packed_", 0) == 0)
		{
			packed = true;
			t = t.substr(7);
		}
		uint32_t comp = 4;
		size_t i = 0;
		while (i < t.size() && isalpha((unsigned char)t[i]))
			i++;
		const std::string base = t.substr(0, i);
		const std::string dims = t.substr(i);
		if (base == "float" || base == "int" || base == "uint")
			comp = 4;
		else if (base == "short" || base == "ushort" || base == "half")
			comp = 2;
		else if (base == "char" || base == "uchar" || base == "bool")
			comp = 1;
		else
			return false;
		uint32_t C = 1, R = 1;
		if (!dims.empty())
		{
			if (sscanf(dims.c_str(), "%ux%u", &C, &R) != 2 && sscanf(dims.c_str(), "%u", &C) != 1)
				return false;
			if (C == 0 || C > 4 || R > 4)
				return false;
		}
		if (R == 1) // vector / scalar
		{
			size = C * comp;
			align = packed ? comp : MslVecAlign(C, comp);
			return true;
		}
		// matrix: MSL `T CxR` = C columns x R rows. The COLUMN vector is the
		// R-component vector: column stride rounds vec<R> up to its own
		// alignment, the struct size is C columns of that stride. (launch166
		// root cause: this used C for the column vector and R as the count —
		// every non-square matrix got the wrong size. float3x4 computed 64B
		// instead of 48B, so the realign pass "confirmed" DXC's column-major
		// SPIR-V offsets (m_WVP@320) as MSL-native and refused to move them,
		// while the emitted MSL struct packs m_WVP@272: every matrix uniform
		// after the first float3x4 was read from the wrong bytes — VS output
		// clipped entirely, zero fragments on every geometry draw.)
		// Empirical (launch168 offprobe on this toolchain): alignof(float4x4)
		// == 16, NOT the 64 the MSL spec prose suggests — sizeof 64, packed at
		// 16. Measured struct: m_VP@208, m_WVP@272, m_xform@960, size 1152.
		// DXC's SPIR-V offsets use DXBC 64B matrix registers (m_WVP@320,
		// m_xform@1008) — the realign pass must MOVE them to the 16-aligned
		// MSL layout; the old 4x4-64B special case reproduced DXC's layout
		// verbatim, reported changed=0, and every mixed-size struct read its
		// matrices from the wrong bytes (zero fragments on all geometry).
		const uint32_t colAlign = packed ? comp : MslVecAlign(R, comp);
		const uint32_t colStride = packed ? R * comp : MslAlignUp(R * comp, colAlign);
		size = C * colStride;
		align = packed ? comp : colAlign;
		return true;
	}

	static void MtlAlignReflToMslLayout(MtlStageRefl& refl, const std::string& msl)
	{
		if (refl.uniforms.empty())
			return;
		const size_t b = msl.find("[[buffer(0)]]");
		if (b == std::string::npos)
			return; // no cbuffer bound
		const size_t amp = msl.rfind('&', b);
		const size_t ts = amp == std::string::npos ? std::string::npos : msl.rfind(' ', amp);
		if (ts == std::string::npos || amp == std::string::npos || amp <= ts + 1)
			return;
		const std::string sname = msl.substr(ts + 1, amp - ts - 1);
		size_t sd = msl.find("struct " + sname);
		if (sd == std::string::npos)
			return;
		sd = msl.find('{', sd);
		const size_t se = sd == std::string::npos ? std::string::npos : msl.find('}', sd);
		if (sd == std::string::npos || se == std::string::npos)
			return;
		const std::string body = msl.substr(sd + 1, se - sd - 1);

		// Walk members in declaration order, replicating the Metal compiler's
		// struct layout; record native offsets by member name.
		std::map<std::string, uint32_t> native;
		uint32_t cur = 0;
		size_t pos = 0;
		while (pos < body.size())
		{
			size_t semi = body.find(';', pos);
			if (semi == std::string::npos)
				break;
			std::string decl = body.substr(pos, semi - pos);
			pos = semi + 1;
			// strip comments + attributes
			for (size_t c; (c = decl.find("//")) != std::string::npos;)
				decl.erase(c);
			for (size_t c; (c = decl.find("[[")) != std::string::npos;)
				decl.erase(c, decl.find("]]", c) + 2 - c);
			// trim
			size_t s1 = decl.find_first_not_of(" \t\r\n");
			if (s1 == std::string::npos)
				continue;
			decl = decl.substr(s1);
			// array suffix?
			uint32_t count = 1;
			std::string name, type;
			if (const size_t lb = decl.find('[') ; lb != std::string::npos)
			{
				count = (uint32_t)atoi(decl.c_str() + lb + 1);
				name = decl.substr(0, lb);
			}
			else
				name = decl;
			// trailing identifier = member name; leading token = type
			size_t ns1 = name.find_last_not_of(" \t\r\n");
			if (ns1 == std::string::npos)
				continue;
			name.erase(ns1 + 1);
			size_t sp = name.rfind(' ');
			if (sp == std::string::npos)
				continue; // e.g. stray padding without type — bail conservatively
			type = name.substr(0, sp);
			name = name.substr(sp + 1);
			uint32_t sz = 0, al = 0;
			if (!MslTypeSizeAlign(type, sz, al))
			{
				fprintf(stderr, "! xrMetal refl: unknown cbuffer member type '%s' in %s — offsets "
				    "left as SPIR-V packing\n",
				    type.c_str(), sname.c_str());
				return; // unknown layout rules — do not half-relayout
			}
			const uint32_t total = count > 1 ? count * MslAlignUp(sz, al) : sz;
			cur = MslAlignUp(cur, al);
			native[name] = cur;
			cur += total;
		}
		if (native.empty())
			return;

		uint32_t changed = 0;
		for (auto& u : refl.uniforms)
		{
			const auto it = native.find(u.name);
			if (it == native.end())
				continue; // optimized out or renamed — leave as-is
			if (u.offset != it->second)
			{
				u.offset = it->second;
				changed++;
			}
		}
		refl.cbufferSize = MslAlignUp(cur, 16);
		if (changed)
			fprintf(stderr, "- xrMetal refl: %s realigned to MSL-native cbuffer layout (cbSize=%u, "
			    "%u offsets moved)\n",
			    sname.c_str(), refl.cbufferSize, changed);
	}
void* g_ppVar[7] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
} // namespace (anon)

// p5 launch218: postprocess PS term-bisect variants. Patch the final
// out.out_var_SV_TARGET assignment to isolate formula terms; EmitDraw
// cycles modes per frame-era (0=black 1=scene(_68) 2=gray(_78)
// 3=noc0(mix without the *C0 mult)). Defined outside the anon namespace
// (declared in mtlRuntime.h); CreateFunction/g_ppVar stay anon-visible.
void MtlBuildPpVariants(const std::string& msl, const char* entry)
{
	static const char* kExprs[7] = {
		"float4(0.0, 0.0, 0.0, 1.0)",
		"float4(_68, 1.0)",
		"float4(_78, 1.0)",
		"float4(mix((_78 * float3(s_noise.sample(s_noise_smplr, in.in_var_TEXCOORD2).xyz)) * "
		"2.0, _78, float3(in.in_var_TEXCOORD10.w)), 1.0)",
		// launch220: show COLOR0 interpolant raw (0.498 gray expected); full
		// formula with CONSTANT multiplier (black expected) — isolates whether
		// the NaN rides in in_var_TEXCOORD10 itself.
		"float4(in.in_var_TEXCOORD10.xyz, 1.0)",
		"float4(mix((_78 * float3(s_noise.sample(s_noise_smplr, in.in_var_TEXCOORD2).xyz)) * "
		"2.0, _78, float3(in.in_var_TEXCOORD10.w)) * float3(0.498, 0.498, 0.498), 1.0)",
		// launch223: show the GPU-side c_brightness read (CB-offset verdict).
		"float4(_Globals.c_brightness.xyz, 1.0)",
	};
	const std::string needle = "out.out_var_SV_TARGET = ";
	size_t b = msl.rfind(needle);
	size_t semi = b == std::string::npos ? std::string::npos : msl.find(';', b);
	if (b == std::string::npos || semi == std::string::npos)
	{
		fprintf(stderr, "! xrMetal ppVariants: output stmt not found\n");
		return;
	}
	for (int m = 0; m < 7; m++)
	{
		if (g_ppVar[m])
			continue;
		const std::string patch = msl.substr(0, b + needle.size()) + kExprs[m] + msl.substr(semi);
		std::string e2;
		id<MTLFunction> vf = CreateFunction([NSString stringWithUTF8String:patch.c_str()], entry,
		                                   "ppVar", e2);
		if (vf)
			g_ppVar[m] = (__bridge_retained void*)vf;
		else
			fprintf(stderr, "! xrMetal ppVariant %d failed: %s\n", m, e2.c_str());
	}
	fprintf(stderr, "- xrMetal ppVariants: %d%d%d%d%d%d%d compiled\n", !!g_ppVar[0], !!g_ppVar[1],
	        !!g_ppVar[2], !!g_ppVar[3], !!g_ppVar[4], !!g_ppVar[5], !!g_ppVar[6]);
}

void* MtlPpVariantFn(int mode)
{
	return (mode >= 0 && mode < 7) ? g_ppVar[mode] : nullptr;
}

// launch151: exposed for MtlRawIntScaledVS (mtlRuntime.mm) — raw-int masked
// VS variants compile via newLibraryWithSource directly and bypass
// CreateFunction, so they never received the XR_METAL_CLIPFIX injection
// (launch150 verdict: 24 terrain/shadow raw-int variants ran unclamped).
NSString* MtlClipFixApply(NSString* src)
{
	return MtlClipFixSource(src);
}

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

// launch264-268: DX9 tex2Dproj onto a depth-comparison sampler compares the
// raster depth against the smap texel — the reference depth rides in the
// proj coord's z (c.z/c.w). SPIRV-Cross lowers proj samples to
// `sample(s, (c.xy / float2(c.w)))` and drops z, so Metal's runtime depth-
// compare (sampler compareFunction + depth texture, enabled by r_Sampler_cmp)
// compares against a missing value and fails every tap: shadow() returns 0
// everywhere and the direct sun never writes accum.
//
// Rewrite the shadow-sampler convention texture (s_smap) to this runtime's
// depth-texture form (macOS 26 metal_stdlib: `depth2d<float>` with explicit-
// dref `sample_compare(sampler, float2, float)` — sampler_compare/texture2d_depth/
// float3-coord forms do NOT exist in its stdlib, verified empirically):
//   a) s_smap.sample(S, (X.xy / float2(X.w))).x -> s_smap.sample_compare(S, X.xy / float2(X.w), X.z / X.w)
//   b) s_smap.sample(S, ARGS).x                 -> s_smap.sample(S, ARGS)   (raw/lod taps: depth2d returns the scalar directly)
//   c) texture2d<float> s_smap [[texture(N)]]   -> depth2d<float> s_smap [[texture(N)]]
// Only shaders that actually contain a proj-compare tap are converted;
// shaders binding the sample result to a vector (r2/shadow.h FOURCC-PCF
// style, accum_sun.ps channel math) are skipped wholesale and keep the old
// raw-sample behaviour that their software compares expect. Restricted to the
// sun shader family by name: spot/omni lights reuse the s_smap sampler name
// bound to r2_RT_generic0, a COLOR texture whose software compares need the
// raw form (a depth2d argument would fail binding validation). Idempotent:
// patched text matches none of the patterns.
static std::string MtlPatchShadowDref(const std::string& msl, const char* name)
{
	if (!name || !strstr(name, "accum_sun"))
		return msl; // dref semantics only apply to the sun shadow map
	if (msl.find("s_smap") == std::string::npos)
		return msl;
	static const std::regex projRe(
	    R"(s_smap\.sample\((\w+), \((\w+)\.xy / float2\(\2\.w\)\)\)\.x)");
	if (!std::regex_search(msl, projRe))
		return msl; // no hardware-compare tap — leave raw form alone
	// Vector-assigned sample results (FOURCC-PCF raw math) — leave be.
	static const std::regex assignRe(R"(=\s*s_smap\.sample\()");
	if (std::regex_search(msl, assignRe))
		return msl;
	std::string out = msl;
	out = std::regex_replace(out, projRe, "s_smap.sample_compare($1, $2.xy / float2($2.w), $2.z / $2.w)");
	static const std::regex tapRe(R"(s_smap\.sample\((\w+), ([^;]*?)\)\.x(?![\w]))");
	out = std::regex_replace(out, tapRe, "s_smap.sample($1, $2)");
	static const std::regex declRe(R"(texture2d<float> s_smap(?=[ \t]*\[\[texture\())");
	out = std::regex_replace(out, declRe, "depth2d<float> s_smap");
	return out;
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
	// Input semantics for BOTH stages: the VS copy drives the vertex-layout
	// resolver; the PS copy drives FFP vertex-shader synthesis in _LinkPP
	// (DX9 fixed-function passes need a VS mirroring the PS interpolants).
	std::vector<std::string> semantics = xray::metal::CollectInputSemantics(translatedHlsl, entry);
	if (!xray::metal::ReflectSpirv(spirv, semantics, refl, error))
		return false;
	// launch264: restore the proj-sample reference depth before the MSL
	// reaches the compiler, reflection, V2P patching or the disk cache.
	res.msl = MtlPatchShadowDref(res.msl, name);
	fprintf(stderr, "- xrMetal refl: %s cbSize=%u uniforms=%u resources=%u inputs=%u\n", name,
	        refl.cbufferSize, (unsigned)refl.uniforms.size(), (unsigned)refl.resources.size(),
	        (unsigned)refl.inputs.size());
	if (const char* d = getenv("XR_METAL_SPV_DUMP"))
	{
		std::string p = std::string(d) + "/" + name + (target == 'v' ? ".vs" : ".ps") + ".spv";
		if (FILE* f = fopen(p.c_str(), "wb"))
		{
			fwrite(spirv.data(), 4, spirv.size(), f);
			fclose(f);
		}
	}

	id<MTLFunction> fn = CreateFunction([NSString stringWithUTF8String:res.msl.c_str()], entry, name, error);
	if (!fn)
		return false;

	// p5 launch218: postprocess PS term bisect — compile patched variants of
	// the final output statement; EmitDraw cycles them per-frame era (black/
	// scene/gray/noc0) so ONE run isolates which formula term paints the
	// steady-state solid yellow.
	if (getenv("XR_METAL_PS_REWRITE") && name && strstr(name, "postprocess"))
		MtlBuildPpVariants(res.msl, entry);

	// ROOT CAUSE #4: MTLFunction handles stored in MtlStageRefl.function must
	// be RETAINED — plain (__bridge void*) let ARC dealloc the function when
	// the local went away, leaving every shader pair with a dangling handle.
	// Geometry PSOs built from the freed functions silently drew nothing.
	out.function = (__bridge_retained void*)fn;
	FillRefl(out, refl);
	MtlAlignReflToMslLayout(out, res.msl); // DXC offsets != MSL native layout
	out.msl = res.msl; // keep for per-pair V2P patching
	out.entry = entry;
	// p5 launch211: raw MSL text for targeted shader hunts (postprocess etc.).
	if (getenv("XR_METAL_DUMPMSL") && name &&
	    (strstr(name, "postprocess") || strstr(name, "combine") || strstr(name, "ffp_vs") ||
	     strstr(name, "deffer_base_flat") || strstr(name, "accum_sun")))
	{
		std::string dp = std::string("/tmp/msldump_") + name + (target == 'v' ? ".vs" : ".ps") +
		                 ".msl";
		for (size_t i = 13; i < dp.size(); i++)
			if (!(isalnum(dp[i]) || dp[i] == '.' || dp[i] == '_' || dp[i] == '-'))
				dp[i] = '_';
		if (FILE* fp = fopen(dp.c_str(), "wb"))
		{
			fwrite(res.msl.data(), 1, res.msl.size(), fp);
			fclose(fp);
		}
	}
	if (outMsl)
		*outMsl = std::move(res.msl);
	return true;
}

bool MetalCreateStageFromMsl(MtlStageRefl& out, const char* name, const char* msl, const char* entry,
                             std::string& error)
{
	// launch264: disk-cache entries compiled before the dref fix carry the
	// z-dropped proj samples; patch idempotently like the realign below.
	const std::string patched = MtlPatchShadowDref(msl, name);
	msl = patched.c_str();
	id<MTLFunction> fn = CreateFunction([NSString stringWithUTF8String:msl], entry, name, error);
	if (!fn)
		return false;
	out.function = (__bridge_retained void*)fn; // RC#4 — retain (see above)
	out.msl = patched; // keep for per-pair V2P patching
	out.entry = entry;
	// launch167: disk-cache hits carry the reflection blob serialized at
	// compile time — which predates the matrix-size fix (float3x4 was sized
	// 64B, so the realign "confirmed" DXC's column-major offsets and moved
	// nothing). Re-run the realign against the cached MSL struct: idempotent
	// for already-correct blobs, repairs every stale cache entry without a
	// cache-version bump (m_WVP must land at 272, not the SPIR-V 320).
	MtlAlignReflToMslLayout(out, out.msl);
	// p5 launch218: variants must also build when postprocess.ps is a
	// disk-cache hit (MetalCompileStage never runs then).
	if (getenv("XR_METAL_PS_REWRITE") && name && strstr(name, "postprocess"))
		MtlBuildPpVariants(out.msl, out.entry.c_str());
	return true;
}

// --- FFP vertex-shader synthesis ---------------------------------------------
// DX9 fed shader:begin("null",...) passes through the fixed-function pipeline:
// every PS interpolant was a plain pass-through of the matching vertex
// attribute (position went through the engine's 2D pixel-space ortho). Metal
// has no FFP, and because DXC assigns interpolant locations by *declaration
// order*, no single fixed stub VS can match every PS input signature (bloom
// wants TEXCOORD0..3 at locn0..3; HUD wants COLOR at locn1). So synthesize a
// per-signature VS that mirrors the PS input struct exactly — same order,
// same widths, same semantics — with the same pixel->clip transform the
// ported stub_notransform_t uses.
namespace
{
	// Reverse the translator's DX9-COLOR -> high-TEXCOORD PS-input rewrite so
	// the VS *inputs* match the DX9 vertex declaration (DIFFUSE/SPECULAR).
	std::string MapFfpInputSemantic(std::string sem)
	{
		if (sem == "TEXCOORD10")
			return "COLOR0";
		if (sem == "TEXCOORD11")
			return "COLOR1";
		if (sem == "TEXCOORD12")
			return "COLOR2";
		return sem;
	}

	std::string BuildFfpVsSource(const std::vector<MtlStageRefl::InputAttr>& psInputsIn)
	{
		std::vector<MtlStageRefl::InputAttr> psInputs = psInputsIn;
		std::sort(psInputs.begin(), psInputs.end(),
		          [](const MtlStageRefl::InputAttr& a, const MtlStageRefl::InputAttr& b)
		          { return a.attribute < b.attribute; });

		static const char* kTypes[5] = {"float", "float", "float2", "float3", "float4"};

		std::string s;
		// p5 launch218: SV_Position MUST be declared LAST in both structs.
		// DXC numbers user locns by declaration order and defers SV_Position
		// to the tail — the PS inputs (TEXCOORD10->locn0) follow that rule,
		// but a position-first struct shifted every VS locn +1 (PP read
		// COLOR0 from an unbound locn0 -> 0*garbage -> NaN -> solid yellow).
		s += "float4 screen_res;\nstruct FFV_In {\n";
		for (size_t i = 0; i < psInputs.size(); i++)
		{
			const auto& in = psInputs[i];
			s += "\t" + std::string(kTypes[in.components <= 4 ? in.components : 4]) + " ffvI" + std::to_string(i) +
			     " : " + MapFfpInputSemantic(in.semantic) + ";\n";
		}
		s += "\tfloat4 ffvPos : POSITION;\n};\nstruct FFV_Out {\n";
		for (size_t i = 0; i < psInputs.size(); i++)
		{
			const auto& in = psInputs[i];
			s += "\t" + std::string(kTypes[in.components <= 4 ? in.components : 4]) + " ffvO" + std::to_string(i) +
			     " : " + MapFfpInputSemantic(in.semantic) + ";\n";
		}
		s += "\tfloat4 ffvPos : SV_Position;\n};\nFFV_Out main(FFV_In I)\n{\n\tFFV_Out O;\n";
		s += "\tI.ffvPos.xy += 0.5;\n";
		s += "\tO.ffvPos.x = I.ffvPos.x * screen_res.z * 2.0 - 1.0;\n";
		s += "\tO.ffvPos.y = 1.0 - I.ffvPos.y * screen_res.w * 2.0;\n";
		s += "\tO.ffvPos.zw = I.ffvPos.zw;\n";
		for (size_t i = 0; i < psInputs.size(); i++)
			s += "\tO.ffvO" + std::to_string(i) + " = I.ffvI" + std::to_string(i) + ";\n";
		s += "\treturn O;\n}\n";
		return s;
	}

	// Session-lifetime records (engine shaders are never unloaded mid-session).
	std::mutex g_ffpLock;
	std::vector<std::unique_ptr<MtlStageRefl>> g_ffp_vs;
} // namespace

MtlStageRefl* MtlBuildFfpVertexStage(const std::vector<MtlStageRefl::InputAttr>& psInputs, std::string& error)
{
	for (const auto& in : psInputs)
		if (in.semantic.empty() || in.isMatrixRow)
		{
			error = "unusable PS input signature";
			return nullptr;
		}

	const std::string src = BuildFfpVsSource(psInputs);
	auto refl = std::make_unique<MtlStageRefl>();
	if (!MetalCompileStage(*refl, nullptr, 'v', "ffp_vs", src.c_str(), "main", error))
		return nullptr;
	refl->name = "ffp_vs";
	std::lock_guard<std::mutex> lock(g_ffpLock);
	g_ffp_vs.push_back(std::move(refl));
	return g_ffp_vs.back().get();
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

// --- p5: per-pair V2P interpolant alignment ----------------------------------
// DX9 matched VS outputs to PS inputs by semantic NAME; DXC assigned Metal
// locations by per-stage declaration order, so pairs whose VS/PS TEXCOORD
// usage diverges fail Metal's strict matching (off-by-one locns, unwritten
// inputs, width mismatches). Patch the pair's MSL text and recompile on the
// device (fast, no DXC round trip): PS input locns are remapped to the VS
// output of the same DX9 semantic, missing VS outputs are appended as
// zero-written floatNs, and Metal's exact-width interpolant rule is enforced
// by widening the narrower side (VS outputs widened in place; narrow PS
// inputs widened with floatN shadow locals preserving the original width).
namespace
{
	struct V2PField
	{
		std::string sem; // DX9 semantic name ("TEXCOORD2")
		int locn = -1;
		int width = 0; // floatN component count
		size_t lineStart = 0;
		size_t lineEnd = 0;
	};

	int V2PTypeWidth(const std::string& t)
	{
		if (t == "float")
			return 1;
		if (t == "float2")
			return 2;
		if (t == "float3")
			return 3;
		if (t == "float4")
			return 4;
		return 0;
	}

	// Parse a SPIRV-Cross stage struct: `floatN out_var_TEXCOORD2 [[user(locn2)]];`
	bool ParseV2PStruct(const std::string& msl, const char* structName, const char* varPrefix,
	                    std::vector<V2PField>& out)
	{
		out.clear();
		const size_t sh = msl.find("struct " + std::string(structName));
		if (sh == std::string::npos)
			return false;
		const size_t ob = msl.find('{', sh);
		const size_t cb = ob == std::string::npos ? std::string::npos : msl.find('}', ob);
		if (cb == std::string::npos)
			return false;
		const std::string prefix(varPrefix);
		size_t pos = ob + 1;
		while (pos < cb)
		{
			size_t nl = msl.find('\n', pos);
			if (nl == std::string::npos || nl > cb)
				nl = cb;
			const std::string line = msl.substr(pos, nl - pos);
			const size_t vt = line.find(prefix);
			if (vt != std::string::npos)
			{
				V2PField f;
				const size_t ts = line.find_first_not_of(" \t\r\n");
				const size_t te = line.find(' ', ts);
				if (ts != std::string::npos && te != std::string::npos && te <= vt)
					f.width = V2PTypeWidth(line.substr(ts, te - ts));
				size_t se = vt + prefix.size();
				while (se < line.size() && (isalnum(line[se]) || line[se] == '_'))
					se++;
				f.sem = line.substr(vt + prefix.size(), se - (vt + prefix.size()));
				const size_t lp = line.find("[[user(locn");
				if (f.width && !f.sem.empty() && lp != std::string::npos)
				{
					f.locn = atoi(line.c_str() + lp + 11);
					f.lineStart = pos;
					f.lineEnd = nl;
					out.push_back(std::move(f));
				}
			}
			pos = nl + 1;
		}
		return true;
	}
} // namespace

// p5 launch228: DXBC translator renames the DX9 vertex-color semantics on
// one side of the interface: VS outputs carry COLOR/COLOR0/1/2 while PS
// inputs read TEXCOORD10/11/12 (and the ffp path already aliases via
// MapFfpInputSemantic). Pure name matching misses the pair and "adds" a
// zero-filled VS output — every such PS then multiplies vertex color by 0
// (rain stubs painted accum/albedo black, launch224-227 black-world hunt).
static std::string V2PSemAlias(const std::string& s)
{
	if (s == "TEXCOORD10" || s == "COLOR")
		return "COLOR0";
	if (s == "TEXCOORD11")
		return "COLOR1";
	if (s == "TEXCOORD12")
		return "COLOR2";
	return s;
}

bool MtlAlignV2PStages(const MtlStageRefl& vs, const MtlStageRefl& ps, MtlStageRefl& outVs,
                       MtlStageRefl& outPs, std::string& error)
{
	error.clear();
	if (vs.msl.empty() || ps.msl.empty() || vs.entry.empty() || ps.entry.empty())
		return false;
	std::vector<V2PField> vf, pf;
	if (!ParseV2PStruct(vs.msl, "main0_out", "out_var_", vf))
		return false;
	if (!ParseV2PStruct(ps.msl, "main0_in", "in_var_", pf))
		return false;

	std::map<std::string, size_t> vmap; // VS semantic -> field index
	int maxLocn = -1;
	for (size_t i = 0; i < vf.size(); i++)
	{
		vmap[V2PSemAlias(vf[i].sem)] = i;
		if (vf[i].locn > maxLocn)
			maxLocn = vf[i].locn;
	}

	bool need = false;
	std::vector<int> psTarget(pf.size(), -1); // remapped locn per PS input
	std::vector<int> vsTarget(vf.size());    // final width per VS output field
	std::vector<int> psWiden(pf.size(), 0);  // PS input widen target (0 = none)
	std::vector<std::tuple<std::string, int, int>>
		added; // new VS outputs: semantic, locn, width
	for (size_t i = 0; i < vf.size(); i++)
		vsTarget[i] = vf[i].width;
	for (size_t i = 0; i < pf.size(); i++)
	{
		const V2PField& p = pf[i];
		const auto it = vmap.find(V2PSemAlias(p.sem));
		if (it == vmap.end())
		{
			added.emplace_back(p.sem, ++maxLocn, p.width);
			psTarget[i] = maxLocn;
			need = true;
			continue;
		}
		const V2PField& v = vf[it->second];
		if (p.width > vsTarget[it->second])
		{
			vsTarget[it->second] = p.width;
			need = true;
		}
		else if (p.width < v.width)
		{
			psWiden[i] = v.width;
			need = true;
		}
		psTarget[i] = v.locn;
		if (v.locn != p.locn)
			need = true;
	}
	if (!need)
		return false;

	// --- VS MSL surgery ---
	std::string vsMsl;
	{
		// Struct: widen narrow fields (type token -> float4) + append missing
		// outputs, rebuilt sequentially so line offsets stay valid.
		const size_t shV = vs.msl.find("struct main0_out");
		if (shV == std::string::npos)
			return false;
		const size_t ob = vs.msl.find('{', shV);
		const size_t cb = ob == std::string::npos ? std::string::npos : vs.msl.find('}', ob);
		if (cb == std::string::npos)
			return false;
		vsMsl.reserve(vs.msl.size() + 256);
		vsMsl.append(vs.msl, 0, ob + 1);
		size_t pos = ob + 1;
		for (size_t fi = 0; fi < vf.size(); fi++)
		{
			const V2PField& f = vf[fi];
			vsMsl.append(vs.msl, pos, f.lineStart - pos);
			std::string line = vs.msl.substr(f.lineStart, f.lineEnd - f.lineStart);
			if (vsTarget[fi] > f.width)
			{
				const size_t ts = line.find_first_not_of(" \t");
				const size_t te = line.find(' ', ts);
				line.replace(ts, te - ts, "float" + std::to_string(vsTarget[fi]));
			}
			vsMsl.append(line);
			pos = f.lineEnd;
		}
		vsMsl.append(vs.msl, pos, cb - pos); // struct tail (gl_Position etc.)
		for (const auto& a : added)
			vsMsl += "\n    float" + std::to_string(std::get<2>(a)) + " out_var_" + std::get<0>(a) +
			         " [[user(locn" + std::to_string(std::get<1>(a)) + ")]];";
		vsMsl.append(vs.msl, cb, vs.msl.size() - cb);
		// Zero-write the added outputs right after the entry's out-init.
		const std::string init = "main0_out out = {};";
		size_t ip = vsMsl.find(init);
		if (ip == std::string::npos)
		{
			error = "V2P: out-init not found in " + vs.name;
			return false;
		}
		ip += init.size();
		std::string zeros;
		for (const auto& a : added)
			zeros += "\n    out.out_var_" + std::get<0>(a) + " = float" +
			         std::to_string(std::get<2>(a)) + "(0.0);";
		vsMsl.insert(ip, zeros);
		// Wrap whole-vector writes of widened fields: floatN expr -> floatM.
		for (size_t i = 0; i < vf.size(); i++)
		{
			if (vsTarget[i] == vf[i].width)
				continue;
			const std::string lhs = "out.out_var_" + vf[i].sem + " = ";
			size_t from = 0;
			int pad = vsTarget[i] - vf[i].width;
			const std::string ctor = "float" + std::to_string(vsTarget[i]) + "(";
			std::string padded;
			padded.reserve(vsMsl.size());
			size_t hit;
			while ((hit = vsMsl.find(lhs, from)) != std::string::npos)
			{
				size_t semi = vsMsl.find(';', hit);
				if (semi == std::string::npos)
					break;
				padded.append(vsMsl, from, lhs.size() + (hit - from));
				padded += ctor;
				padded.append(vsMsl, hit + lhs.size(), semi - (hit + lhs.size()));
				for (int z = 0; z < pad; z++)
					padded += ", 0.0";
				padded += ")";
				from = semi;
			}
			padded.append(vsMsl, from, vsMsl.size() - from);
			vsMsl.swap(padded);
		}
	}

	// --- PS MSL surgery: remap input locns + widen narrow inputs ---
	std::string psMsl;
	{
		psMsl.reserve(ps.msl.size() + 128);
		struct V2PShadow
		{
			std::string name; // in_var_TEXCOORD0
			int width;        // original (narrow) component count
		};
		std::vector<V2PShadow> shadows;
		size_t pos = 0;
		for (size_t i = 0; i < pf.size(); i++)
		{
			const V2PField& f = pf[i];
			const bool remap = psTarget[i] >= 0 && psTarget[i] != f.locn;
			if (!remap && !psWiden[i])
				continue;
			psMsl.append(ps.msl, pos, f.lineStart - pos);
			std::string line = ps.msl.substr(f.lineStart, f.lineEnd - f.lineStart);
			if (remap)
			{
				const std::string oldL = "[[user(locn" + std::to_string(f.locn) + ")]]";
				const size_t lp = line.find(oldL);
				if (lp != std::string::npos)
					line.replace(lp, oldL.size(), "[[user(locn" + std::to_string(psTarget[i]) + ")]]");
			}
			if (psWiden[i])
			{
				const size_t ts = line.find_first_not_of(" \t");
				const size_t te = line.find(' ', ts);
				line.replace(ts, te - ts, "float" + std::to_string(psWiden[i]));
				shadows.push_back({std::string("in_var_") + f.sem, f.width});
			}
			psMsl.append(line);
			pos = f.lineEnd;
		}
		psMsl.append(ps.msl, pos, ps.msl.size() - pos);

		if (!shadows.empty())
		{
			// Main body only: SPIRV-Cross emits helper functions before the
			// entry, so restrict rewriting to after the fragment entry brace.
			const size_t fp = psMsl.find("fragment ");
			const size_t fb = fp == std::string::npos ? std::string::npos : psMsl.find('{', fp);
			if (fb == std::string::npos)
			{
				error = "V2P: fragment entry not found in " + ps.name;
				return false;
			}
			static const char* const kSwizzle[5] = {"", ".x", ".xy", ".xyz", ".xyzw"};
			std::string decls;
			for (const V2PShadow& s : shadows)
			{
				const std::string use = "in." + s.name;
				size_t from = fb + 1;
				size_t hit;
				while ((hit = psMsl.find(use, from)) != std::string::npos)
				{
					const size_t after = hit + use.size();
					if (after < psMsl.size() && (isalnum(psMsl[after]) || psMsl[after] == '_'))
					{
						from = after; // longer identifier (e.g. ..._1) - skip
						continue;
					}
					psMsl.replace(hit, use.size(), s.name);
					from = hit + s.name.size();
				}
				decls += "\n    float" + std::to_string(s.width) + " " + s.name + " = in." + s.name +
				         kSwizzle[s.width] + ";";
			}
			psMsl.insert(fb + 1, decls);
		}
	}

	// p5 diag helper: dump a source string for offline analysis (failure only,
	// keyed by BOTH stage names so repeated pairs don't overwrite).
	auto v2pDump = [](const std::string& tag, const std::string& vsn, const std::string& psn,
	                  const std::string& src) {
		std::string dump = "/tmp/v2px_" + tag + "_" + vsn + "__" + psn + ".metal";
		for (size_t i = 5; i < dump.size(); i++)
			if (dump[i] == '/' || dump[i] == ' ')
				dump[i] = '_';
		if (FILE* fp = fopen(dump.c_str(), "wb"))
		{
			fwrite(src.data(), 1, src.size(), fp);
			fclose(fp);
		}
	};
	// p5 DIAG (launch107): dump the FINAL aligned MSL of the first pairs for
	// offline VS/PS pairing verification (XR_METAL_DUMPMSL=1).
	// launch109: restrict to deffer geometry pairs — the menu stub pairs filled
	// the old cap of 8 and the real dead pairs never got dumped.
	static int s_dumpN = 0;
	static int s_dumpD = 0; // launch163: separate budget for the terrain _d pairs
	const bool isD = ps.name.find("_d") != std::string::npos ||
	                 vs.name.find("_d") != std::string::npos;
	if (getenv("XR_METAL_DUMPMSL") &&
	    ((isD && s_dumpD < 40) || (!isD && s_dumpN < 40)) &&
	    (ps.name.find("deffer") != std::string::npos || ps.name.find("postprocess") != std::string::npos))
	{
		if (isD)
			s_dumpD++;
		else
			s_dumpN++;
		std::string dp = "/tmp/msldump_" + vs.name + "__" + ps.name;
		for (size_t i = 5; i < dp.size(); i++)
			if (!(isalnum(dp[i]) || dp[i] == '.' || dp[i] == '_' || dp[i] == '-'))
				dp[i] = '_';
		if (FILE* fp = fopen((dp + ".vs.metal").c_str(), "wb"))
		{
			fwrite(vsMsl.data(), 1, vsMsl.size(), fp);
			fclose(fp);
		}
		if (FILE* fp = fopen((dp + ".ps.metal").c_str(), "wb"))
		{
			fwrite(psMsl.data(), 1, psMsl.size(), fp);
			fclose(fp);
		}
	}
	id<MTLFunction> fnV =
		CreateFunction([NSString stringWithUTF8String:vsMsl.c_str()], vs.entry.c_str(),
		               (vs.name + "|v2p").c_str(), error);
	if (!fnV)
	{
		v2pDump("v2pFAILvs", vs.name, ps.name, vsMsl);
		v2pDump("v2pINvs", vs.name, ps.name, vs.msl);
		return false;
	}
	id<MTLFunction> fnP =
		CreateFunction([NSString stringWithUTF8String:psMsl.c_str()], ps.entry.c_str(),
		               (ps.name + "|v2p").c_str(), error);
	if (!fnP)
	{
		v2pDump("v2pFAILps", vs.name, ps.name, psMsl);
		v2pDump("v2pINps", vs.name, ps.name, ps.msl);
		return false;
	}

	outVs = vs;
	outVs.function = (__bridge_retained void*)fnV; // RC#4 — retain
	outVs.msl = std::move(vsMsl);
	outVs.name += "|v2p";
	outPs = ps;
	outPs.function = (__bridge_retained void*)fnP; // RC#4 — retain
	outPs.msl = std::move(psMsl);
	outPs.name += "|v2p";
	for (size_t i = 0; i < pf.size(); i++)
	{
		if (psTarget[i] < 0)
			continue;
		for (auto& in : outPs.inputs)
			if (in.semantic == pf[i].sem)
				in.attribute = (uint32_t)psTarget[i];
	}
	size_t nRemap = 0;
	for (size_t i = 0; i < pf.size(); i++)
		if (psTarget[i] >= 0 && psTarget[i] != pf[i].locn)
			nRemap++;
	size_t nWiden = 0;
	for (size_t i = 0; i < vf.size(); i++)
		if (vsTarget[i] != vf[i].width)
			nWiden++;
	for (size_t i = 0; i < pf.size(); i++)
		if (psWiden[i])
			nWiden++;
	fprintf(stderr, "- xrMetal V2P aligned pair %s + %s: remaps=%u added=%u widened=%u\n",
	        vs.name.c_str(), ps.name.c_str(), (unsigned)nRemap, (unsigned)added.size(),
	        (unsigned)nWiden);
	fflush(stderr);
	return true;
}

MtlShaderPair* MtlMakeShaderPair(const char* name)
{
	auto* pair = new MtlShaderPair();
	pair->name = name ? name : "?";
	return pair;
}
} // namespace xray::render::RENDER_NAMESPACE
