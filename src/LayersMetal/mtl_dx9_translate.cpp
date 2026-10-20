// mtl_dx9_translate.cpp — DX9-era XRay HLSL -> SM6 source rewriting.
// Textual, line-oriented: the corpus is machine-generated-clean (one
// declaration per line, guarded includes), which keeps the translator small.

#include "mtl_dx9_translate.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>

namespace fs = std::filesystem;

namespace xray::metal
{

	namespace
	{

		std::string ReadFile(const std::string& p)
		{
			std::ifstream f(p, std::ios::binary);
			if (!f)
				return {};
			std::ostringstream ss;
			ss << f.rdbuf();
			return ss.str();
		}

		std::string DirOf(const std::string& p)
		{
			const auto pos = p.find_last_of("/\\");
			return pos == std::string::npos ? std::string(".") : p.substr(0, pos);
		}

		std::string NormSlashes(std::string s)
		{
			for (auto& c : s)
				if (c == '\\')
					c = '/';
			return s;
		}

		struct Ctx
		{
			std::vector<std::string> includeDirs;
			std::vector<std::string> stack; // include cycle guard
			std::vector<std::string>* notes = nullptr;
			bool ok = true;
			std::string firstError;
			void Fail(const std::string& msg)
			{
				if (ok)
				{
					ok = false;
					firstError = msg;
				}
			}
		};

		std::string ExpandIncludes(const std::string& src, const std::string& path, Ctx& ctx, int depth)
		{
			if (depth > 24)
			{
				ctx.Fail("include depth exceeded at " + path);
				return {};
			}
			ctx.stack.push_back(path);

			static const std::regex incRe(R"(^\s*#\s*include\s*([\"<])([^\">]+)[\">])");
			std::istringstream in(src);
			std::string line, out;
			int lineNo = 0;
			const std::string dir = DirOf(path);

			while (std::getline(in, line))
			{
				lineNo++;
				std::smatch m;
				if (std::regex_search(line, m, incRe))
				{
					const std::string name = NormSlashes(m[2].str());
					std::string found;
					std::vector<std::string> bases;
					bases.push_back(dir);
					for (const auto& d : ctx.includeDirs)
						bases.push_back(d);
					for (const auto& b : bases)
					{
						std::error_code ec;
						const fs::path cand = fs::path(b) / name;
						if (fs::exists(cand, ec))
						{
							found = cand.string();
							break;
						}
					}
					if (found.empty())
					{
						ctx.Fail("missing include '" + m[2].str() + "' (" + path + ":" + std::to_string(lineNo) + ")");
						out += line;
						out += '\n';
						continue;
					}
					if (std::find(ctx.stack.begin(), ctx.stack.end(), found) != ctx.stack.end())
					{
						// Re-entrant include; #ifndef guards make elision safe.
						ctx.notes->push_back("elided cyclic include " + found);
						out += "\n#line " + std::to_string(lineNo + 1) + " \"" + path + "\"\n";
						continue;
					}
					const std::string inc = ReadFile(found);
					if (inc.empty())
					{
						ctx.Fail("unreadable include " + found);
						out += line;
						out += '\n';
						continue;
					}
					const std::string exp = ExpandIncludes(inc, found, ctx, depth + 1);
					if (!ctx.ok)
						return {};
					out += "\n#line 1 \"" + NormSlashes(found) + "\"\n";
					out += exp;
					out += "\n#line " + std::to_string(lineNo + 1) + " \"" + NormSlashes(path) + "\"\n";
					continue;
				}
				out += line;
				out += '\n';
			}
			ctx.stack.pop_back();
			return out;
		}

		// sampler2D/samplerCUBE NAME [: register(sN)] ; -> Texture on unique tN.
		std::string RewriteSamplers(const std::string& src, Ctx& ctx)
		{
			static const std::regex declRe(
				R"(^(\s*)(?:uniform\s+)?(sampler2D|sampler3D|sampler1D|samplerCUBE|sampler)(?![0-9A-Za-z_])\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*register\s*\(\s*(?:[pP][sS]\s*,\s*|[vV][sS]\s*,\s*)?[sS]\s*(\d+)\s*\))?\s*(=\s*sampler_state\s*\{[^}]*\}\s*)?;\s*$)");
			static const std::regex anySamplerRe(R"((^|[^\w])sampler(2D|3D|1D|CUBE)?(?![0-9A-Za-z_]))");
			std::istringstream in(src);
			std::string line, out;
			std::set<int> usedT;
			int nextT = 0;
			int lineNo = 0;

			while (std::getline(in, line))
			{
				lineNo++;
				// Declarations may carry a trailing // comment; match against
				// the code portion and re-append the comment afterwards.
				std::string code = line, comment;
				const auto cpos = code.find("//");
				if (cpos != std::string::npos)
				{
					comment = code.substr(cpos);
					code.erase(cpos);
				}
				std::smatch m;
				if (std::regex_match(code, m, declRe))
				{
					const std::string kind = m[2].str();
					const char* texType = kind == "sampler3D"      ? "Texture3D<float4> "
					                      : kind == "sampler1D"    ? "Texture1D<float4> "
					                      : kind == "samplerCUBE"  ? "TextureCube<float4> "
					                                             : "Texture2D<float4> "; // sampler2D + DX7 'sampler'
					const std::string name = m[3];
					// libc++ std::regex can report the outer optional group as
					// matched with the nested digit capture unset — guard it.
					int t = nextT;
					if (m[4].matched && m[5].matched && !m[5].str().empty())
					{
						try
						{
							t = std::stoi(m[5].str());
						}
						catch (const std::exception&)
						{
							ctx.Fail("bad register() index on sampler '" + name + "'");
							return out;
						}
					}
					while (usedT.count(t))
						t++;
					usedT.insert(t);
					if (!m[4].matched && t >= nextT)
						nextT = t + 1;
					code = m[1].str() + texType + name + " : register(t" + std::to_string(t) + ");";
					if (m[6].matched)
						ctx.notes->push_back("sampler_state init on '" + name + "' dropped (default sampler used)");
					line = code + comment;
				}
				else if (std::regex_search(code, anySamplerRe))
					ctx.Fail("unhandled sampler declaration (line " + std::to_string(lineNo) + "): " + code);
				out += line;
				out += '\n';
			}
			return out;
		}

		// DX9 c-register bindings on globals: binding layout is the backend's
		// problem (constant buffer packing), and DXC rejects the syntax.
		void StripCRegisters(std::string& body, Ctx& ctx)
		{
			static const std::regex cReg(R"(\s*:\s*register\s*\(\s*[cC]\s*\d+\s*\))");
			std::string out;
			std::string rest = body;
			for (;;)
			{
				std::smatch m;
				if (!std::regex_search(rest, m, cReg))
				{
					out += rest;
					break;
				}
				out.append(rest, 0, m.position());
				rest.erase(0, m.position() + m.length());
				ctx.notes->push_back("stripped DX9 c-register binding");
			}
			body.swap(out);
		}

		// Identifier-aware token call rewrite: "tex2D (" -> "_tex2D(" but never
		// inside another identifier. DX9 corpus style pads the call name, so
		// whitespace before '(' is allowed; the '(' is the right boundary.
		void ReplaceToken(std::string& s, const std::string& from, const std::string& to)
		{
			size_t pos = 0;
			while ((pos = s.find(from, pos)) != std::string::npos)
			{
				const bool boundaryOk = pos == 0 || !(std::isalnum(static_cast<unsigned char>(s[pos - 1])) || s[pos - 1] == '_');
				size_t p = pos + from.size();
				while (p < s.size() && (s[p] == ' ' || s[p] == '\t'))
					p++;
				if (boundaryOk && p < s.size() && s[p] == '(')
				{
					s.replace(pos, p - pos, to);
					pos += to.size();
				}
				else
					pos += from.size();
			}
		}

		// Identifier-aware word rewrite with both-side boundaries (no paren
		// requirement): used for DXC-reserved identifiers used by the corpus.
		void ReplaceWord(std::string& s, const std::string& from, const std::string& to)
		{
			size_t pos = 0;
			while ((pos = s.find(from, pos)) != std::string::npos)
			{
				const bool leftOk = pos == 0 ||
				                    !(std::isalnum(static_cast<unsigned char>(s[pos - 1])) || s[pos - 1] == '_');
				const size_t after = pos + from.size();
				const bool rightOk = after >= s.size() ||
				                     !(std::isalnum(static_cast<unsigned char>(s[after])) || s[after] == '_');
				if (leftOk && rightOk)
				{
					s.replace(pos, from.size(), to);
					pos += to.size();
				}
				else
					pos = after;
			}
		}

		const char* kPrelude =
			"// xrRenderMetal DX9 compatibility prelude\n"
			"SamplerState xrDefaultSampler : register(s0);\n"
			"float4 _tex2D(Texture2D<float4> t, float2 uv) { return t.Sample(xrDefaultSampler, uv); }\n"
			"float4 _tex2D(Texture2D<float4> t, float2 uv, float bias) { return t.SampleBias(xrDefaultSampler, uv, bias); }\n"
			"float4 _tex2D(Texture2D<float4> t, float2 uv, float2 ddx, float2 ddy) { return t.SampleGrad(xrDefaultSampler, uv, ddx, ddy); }\n"
			"float4 _tex2Dproj(Texture2D<float4> t, float4 c) { return t.Sample(xrDefaultSampler, c.xy / c.w); }\n"
			"float4 _tex2Dlod(Texture2D<float4> t, float4 c) { return t.SampleLevel(xrDefaultSampler, c.xy, c.w); }\n"
			"float4 _texCUBE(TextureCube<float4> t, float3 d) { return t.Sample(xrDefaultSampler, d); }\n"
			"float4 _tex1D(Texture1D<float4> t, float u) { return t.Sample(xrDefaultSampler, u); }\n"
			"float4 _tex3D(Texture3D<float4> t, float3 uvw) { return t.Sample(xrDefaultSampler, uvw); }\n"
			"float4 _tex3Dlod(Texture3D<float4> t, float4 c) { return t.SampleLevel(xrDefaultSampler, c.xyz, c.w); }\n";

	} // namespace

	Dx9Translation TranslateDx9Shader(const std::string& source, const std::string& sourcePath, ShaderStage stage,
	                                   const std::vector<std::string>& includeDirs, const Dx9TranslateOptions& opts)
	{
		Dx9Translation res;
		Ctx ctx;
		ctx.includeDirs = includeDirs;
		ctx.notes = &res.notes;

		std::string body = ExpandIncludes(source, sourcePath, ctx, 0);
		if (!ctx.ok)
		{
			res.error = ctx.firstError;
			return res;
		}
		body = RewriteSamplers(body, ctx);
		if (!ctx.ok)
		{
			res.error = ctx.firstError;
			return res;
		}
		StripCRegisters(body, ctx);

		ReplaceToken(body, "tex2Dlod", "_tex2Dlod");
		ReplaceToken(body, "tex2Dproj", "_tex2Dproj");
		ReplaceToken(body, "tex2D", "_tex2D");
		ReplaceToken(body, "tex3Dlod", "_tex3Dlod");
		ReplaceToken(body, "tex3D", "_tex3D");
		ReplaceToken(body, "texCUBE", "_texCUBE");
		ReplaceToken(body, "tex1D", "_tex1D");

		// DXC reserves 'point' (point-sampling operator); the corpus uses it
		// as a plain parameter name.
		ReplaceWord(body, "point", "xr_point");

		// DXC forbids non-scalar ternary conditions (fxc evaluated them
		// component-wise); rewrite `(vec CMP x) ? a : b` to select(), which is
		// component-wise. Only parenthesised comparison conditions match, so
		// ordinary scalar control-flow ternaries are left alone.
		body = std::regex_replace(body, std::regex(R"(\(([^()]*[<>=!][^()]*)\)\s*\?\s*([^?:;()]+?)\s*:\s*([^?:;()]+?)\s*(?=[;,)]))"),
		                          "select(($1), $2, $3)");

		// DX9 system semantics on PS outputs: COLOR<N> -> SV_TARGET<N>. When
		// COLOR* is used on PS *inputs* (reading a prior MRT pass) the caller
		// retries with colorInputsAsTexcoord. The DX9 fixed-function FOG
		// semantic becomes a plain user semantic (R7 computes fog itself).
		if (stage == ShaderStage::Pixel)
		{
			if (opts.colorInputsAsTexcoord)
			{
				// Classify structs by how this file uses them: as a function
				// PARAMETER type -> DX11 PS input (COLOR* illegal -> high
				// TEXCOORD slots), as a RETURN type -> output (SV_TARGET).
				// COLOR semantics outside struct blocks are function outputs.
				std::set<std::string> structs, inputS, outputS;
				static const std::regex structDef(R"(struct\s+([A-Za-z_]\w*))");
				{
					auto a = std::sregex_iterator(body.begin(), body.end(), structDef);
					for (const auto b = std::sregex_iterator(); a != b; ++a)
						structs.insert((*a)[1].str());
				}
				static const std::regex paramUse(R"([,(]\s*([A-Za-z_]\w*)\s+[A-Za-z_]\w*\s*(?:\[\s*\d+\s*\])?\s*[),])");
				{
					auto a = std::sregex_iterator(body.begin(), body.end(), paramUse);
					for (const auto b = std::sregex_iterator(); a != b; ++a)
						if (structs.count((*a)[1].str()))
							inputS.insert((*a)[1].str());
				}
				static const std::regex retUse(R"(^\s*([A-Za-z_]\w*)\s+[A-Za-z_]\w*\s*\()");
				{
					std::istringstream si(body);
					std::string l;
					while (std::getline(si, l))
					{
						std::smatch mm;
						if (std::regex_search(l, mm, retUse) && structs.count(mm[1].str()))
							outputS.insert(mm[1].str());
					}
				}
				const auto mapColors = [](std::string& s, bool asTexcoord)
				{
					if (asTexcoord)
					{
						s = std::regex_replace(s, std::regex(R"(:\s*COLOR0\b)"), ": TEXCOORD10");
						s = std::regex_replace(s, std::regex(R"(:\s*COLOR1\b)"), ": TEXCOORD11");
						s = std::regex_replace(s, std::regex(R"(:\s*COLOR2\b)"), ": TEXCOORD12");
						s = std::regex_replace(s, std::regex(R"(:\s*COLOR\b)"), ": TEXCOORD10");
					}
					else
						s = std::regex_replace(s, std::regex(R"(:\s*COLOR(\d*))"), ": SV_TARGET$1");
				};
				static const std::regex structHead(R"(struct\s+([A-Za-z_]\w*))");
				// COLOR semantics in entry-function parameter lists are PS inputs.
				const std::string stem = [&sourcePath]
				{
					auto slash = sourcePath.find_last_of("/\\");
					std::string base = slash == std::string::npos ? sourcePath : sourcePath.substr(slash + 1);
					auto dot = base.find_last_of('.');
					return dot == std::string::npos ? base : base.substr(0, dot);
				}();
				static const std::regex fnOpen(R"(([A-Za-z_][A-Za-z0-9_]*)\s*\()");
				std::vector<std::pair<size_t, size_t>> paramSpans; // [open, close]
				{
					auto a = std::sregex_iterator(body.begin(), body.end(), fnOpen);
					for (const auto b = std::sregex_iterator(); a != b; ++a)
					{
						const std::string nm = (*a)[1].str();
						if (!(nm.compare(0, 4, "main") == 0 || (!stem.empty() && nm.compare(0, stem.size(), stem) == 0)))
							continue;
						size_t open = static_cast<size_t>(a->position(0)) + nm.size();
						while (open < body.size() && body[open] != '(')
							open++;
						int depth = 0;
						size_t close = open;
						for (; close < body.size(); ++close)
						{
							if (body[close] == '(')
								depth++;
							else if (body[close] == ')')
							{
								depth--;
								if (!depth)
									break;
							}
						}
						if (close > open)
							paramSpans.emplace_back(open, close);
					}
				}
				for (auto it = paramSpans.rbegin(); it != paramSpans.rend(); ++it)
				{
					std::string span = body.substr(it->first, it->second - it->first + 1);
					mapColors(span, true);
					body.replace(it->first, it->second - it->first + 1, span);
				}
				std::string walked;
				size_t i = 0;
				for (;;)
				{
					std::smatch m;
					const std::string sub = body.substr(i);
					if (!std::regex_search(sub, m, structHead))
					{
						walked += sub;
						break;
					}
					const std::string name = m[1].str();
					const size_t absName = i + static_cast<size_t>(m.position(1));
					const size_t brace = body.find('{', absName);
					if (brace == std::string::npos)
					{
						walked += sub;
						break;
					}
					int depth = 0;
					size_t j = brace;
					for (; j < body.size(); ++j)
					{
						if (body[j] == '{')
							depth++;
						else if (body[j] == '}')
						{
							depth--;
							if (!depth)
								break;
						}
					}
					std::string blk = body.substr(brace, j - brace + 1);
					mapColors(blk, inputS.count(name) && !outputS.count(name));
					walked.append(body, i, brace - i);
					walked += blk;
					i = j + 1;
				}
				body.swap(walked);
				mapColors(body, false); // leftover COLOR semantics (function outputs)
			}
			else
				body = std::regex_replace(body, std::regex(R"(:\s*COLOR(\d*))"), ": SV_TARGET$1");
		}
		body = std::regex_replace(body, std::regex(R"(:\s*FOG\b)"), ": xrFog");

		std::ostringstream out;
		out << kPrelude << "\n#line 1 \"" << NormSlashes(sourcePath) << "\"\n" << body;
		res.hlsl = out.str();
		res.ok = true;
		return res;
	}

} // namespace xray::metal
