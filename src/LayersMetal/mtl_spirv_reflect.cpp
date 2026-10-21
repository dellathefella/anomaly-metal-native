// mtl_spirv_reflect.cpp — SPIR-V reflection + entry-semantic scan (p5).

#include "mtl_spirv_reflect.h"

#include <spirv_cross/spirv_cross.hpp>
#include <spirv_cross/spirv_msl.hpp>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <regex>

namespace xray::metal
{

namespace
{

	std::string StripComments(const std::string& s)
	{
		std::string out;
		out.reserve(s.size());
		size_t i = 0;
		while (i < s.size())
		{
			if (s[i] == '/' && i + 1 < s.size() && s[i + 1] == '/')
			{
				while (i < s.size() && s[i] != '\n')
					i++;
				continue; // the newline itself is kept on the next iteration
			}
			if (s[i] == '/' && i + 1 < s.size() && s[i + 1] == '*')
			{
				const auto end = s.find("*/", i + 2);
				i = end == std::string::npos ? s.size() : end + 2;
				continue;
			}
			out += s[i++];
		}
		return out;
	}

	std::string UpperSem(std::string sem)
	{
		for (auto& c : sem)
			c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
		return sem;
	}

	// Extract `: SEM` tokens (in order) from a declaration body, skipping SV_*.
	std::vector<std::string> SemTokens(const std::string& body)
	{
		static const std::regex semRe(R"(:\s*([A-Za-z_][A-Za-z0-9_]*))");
		std::vector<std::string> out;
		for (auto it = std::sregex_iterator(body.begin(), body.end(), semRe); it != std::sregex_iterator(); ++it)
		{
			std::string sem = UpperSem((*it)[1].str());
			if (sem.rfind("SV_", 0) == 0)
				continue;
			out.push_back(sem);
		}
		return out;
	}

} // namespace

	std::vector<std::string> CollectInputSemantics(const std::string& hlslIn, const std::string& entry)
	{
		const std::string hlsl = StripComments(hlslIn);

		// Locate "ENTRY (" and capture the balanced parameter list.
		const std::regex entryRe(R"(([\w:]+\s+)+)" + entry + R"(\s*\()");
		std::smatch m;
		std::string::const_iterator from = hlsl.begin();
		const std::string::const_iterator end = hlsl.end();
		std::string body;
		while (std::regex_search(from, end, m, entryRe))
		{
			auto p = m.suffix().first; // just after '('
			int depth = 1;
			auto q = p;
			while (q != end && depth > 0)
			{
				if (*q == '(')
					depth++;
				else if (*q == ')')
					depth--;
				if (depth > 0)
					q++;
			}
			body.assign(p, q);
			from = p;
			if (!body.empty())
				break;
		}
		if (body.empty())
			return {};

		// Flat parameter list: semantics inline.
		if (body.find(':') != std::string::npos)
			return SemTokens(body);

		// Struct parameter: resolve the struct definition.
		std::smatch pm;
		if (!std::regex_search(body, pm, std::regex(R"(([A-Za-z_][A-Za-z0-9_]*)\s*[A-Za-z_][A-Za-z0-9_]*\s*$)")))
			return {};
		const std::string structName = pm[1].str();
		const std::regex structRe(R"((struct|class)\s+)" + structName + R"(\s*(?::\s*\w+\s*)?\{([^}]*)\})");
		if (!std::regex_search(hlsl, m, structRe))
			return {};
		return SemTokens(m[2].str());
	}

	bool ReflectSpirv(const std::vector<uint32_t>& spirv, const std::vector<std::string>& inputSemantics,
	                  ShaderReflection& out, std::string& error)
	{
		if (spirv.size() < 5 || spirv[0] != 0x07230203u)
		{
			error = "reflect: bad SPIR-V";
			return false;
		}
		try
		{
			spirv_cross::CompilerMSL comp(spirv);
			// compile() first: populates the combined image-sampler split that
			// DXC's sampler2D declarations produce.
			comp.compile();
			auto res = comp.get_shader_resources();

			// --- cbuffer (the $Globals image) -------------------------------
			// DXC assigns $Globals an arbitrary binding (observed 29 — the
			// DX9 translator's register remapping), while our MSL emission
			// always places the first uniform buffer at buffer(0) (the stage
			// constant slot BindDraw fills). Take the FIRST uniform buffer;
			// DX9-translated shaders carry exactly one.
			for (const auto& ub : res.uniform_buffers)
			{
				const auto& type = comp.get_type(ub.base_type_id);
				out.cbufferSize = static_cast<uint32_t>(comp.get_declared_struct_size(type));
				for (uint32_t mem = 0; mem < type.member_types.size(); mem++)
				{
					ReflectionUniform u;
					u.name = comp.get_member_name(type.self, mem);
					const auto br = u.name.find('[');
					if (br != std::string::npos)
						u.name.erase(br);
					u.offset = comp.get_member_decoration(type.self, mem, spv::DecorationOffset);
					const auto& mt = comp.get_type(type.member_types[mem]);
					u.size = static_cast<uint32_t>(comp.get_declared_struct_member_size(type, mem));
					if (!mt.array.empty() && mt.array[0] > 0)
					{
						uint32_t count = 1;
						for (uint32_t d = 0; d < mt.array.size(); d++)
						{
							if (mt.array[d] == 0)
								continue;
							count *= mt.array[d];
						}
						u.elements = count;
						u.stride = u.size / count; // first-dim stride
					}
					else
					{
						u.elements = 1;
						u.stride = 0;
					}
					u.baseType = mt.basetype == spirv_cross::SPIRType::Boolean
					                 ? 2
					                 : (mt.basetype == spirv_cross::SPIRType::Int ||
					                    mt.basetype == spirv_cross::SPIRType::UInt)
					                       ? 1
					                       : 0;
					// SPIR-V matrix: vecsize = vector length, columns = count.
					// DXC -Zpr decorates members MatrixRowMajor; the image
					// layout matches the engine's row-major Fmatrix memcpy.
					u.cols = mt.columns > 1 ? static_cast<uint32_t>(mt.columns) : 1;
					u.rows = static_cast<uint32_t>(mt.vecsize);
					if (u.cols == 1)
						u.rows = std::min<uint32_t>(4, u.rows); // plain vector
					out.uniforms.push_back(std::move(u));
				}
				break; // first uniform buffer == the stage $Globals image
			}

			// --- textures + samplers ----------------------------------------
			// MSL emission (SPIRV-Cross, use_native_bindings=false) assigns
			// PER-CLASS SEQUENTIAL indices — buffer(0..), texture(0..),
			// sampler(0..) in declaration order. DXC's SPIR-V bindings are
			// shifted ($Globals observed at 29, t0..t2 at 29..31) and must
			// never be used as engine stages (they poisoned i_Sampler:
			// 's_noise -> stage 31' instead of 2). Mirror MSL's own numbering:
			// rank within each class. The translator emits mirrored
			// register(tN)/register(sN) pairs, so the image's rank doubles as
			// its sampler's index and equals the DX9 stage whenever the
			// declaration order matches the DX9 stage order (always for the
			// unregistered DX9 tree; self-consistent otherwise).
			uint32_t texRank = 0;
			for (const auto& img : res.separate_images)
			{
				ReflectionResource r;
				r.name = img.name;
				r.textureSlot = texRank;
				r.samplerSlot = texRank; // mirrored register pair
				r.isSamplerOnly = false;
				out.resources.push_back(std::move(r));
				texRank++;
			}
			for (const auto& img : res.sampled_images)
			{
				// combined variables that survived the split unpaired
				bool paired = false;
				for (const auto& r : out.resources)
					if (r.name == img.name && !r.isSamplerOnly)
					{
						paired = true;
						break;
					}
				if (paired)
					continue;
				ReflectionResource r;
				r.name = img.name;
				r.textureSlot = texRank;
				r.samplerSlot = texRank;
				r.isSamplerOnly = false;
				out.resources.push_back(std::move(r));
				texRank++;
			}
			uint32_t sampRank = 0;
			for (const auto& smp : res.separate_samplers)
			{
				ReflectionResource r;
				r.name = smp.name;
				r.textureSlot = UINT32_MAX;
				r.samplerSlot = sampRank++;
				r.isSamplerOnly = true;
				out.resources.push_back(std::move(r));
			}

			// --- VS inputs: Location == [[attribute(N)]] == declaration order --
			std::vector<std::pair<uint32_t, const spirv_cross::Resource*>> inSorted;
			for (const auto& in : res.stage_inputs)
				inSorted.emplace_back(comp.get_decoration(in.id, spv::DecorationLocation), &in);
			std::sort(inSorted.begin(), inSorted.end(),
			          [](const auto& a, const auto& b) { return a.first < b.first; });
			for (const auto& [attr, in] : inSorted)
			{
				ReflectionInput i;
				i.attribute = attr;
				const auto& t = comp.get_type(in->type_id);
				i.isMatrixRow = t.columns > 1;
				i.components = static_cast<uint32_t>(t.vecsize);
				i.semantic = attr < inputSemantics.size() ? inputSemantics[attr] : std::string();
				if (i.semantic.empty())
					i.semantic = in->name; // fallback: spirv-cross variable name
				out.inputs.push_back(std::move(i));
			}
		}
		catch (const std::exception& e)
		{
			error = std::string("reflect: ") + e.what();
			return false;
		}
		return true;
	}

} // namespace xray::metal
