// mtl_shader_compiler.cpp — HLSL -> SPIR-V -> MSL orchestration with a
// hash-keyed on-disk cache. DXC in-process (mtl_dxc.cpp) is the primary
// backend; the dxc CLI is a fallback. SPIR-V -> MSL runs in-process via
// SPIRV-Cross (CompilerMSL).

#include "mtl_shader_compiler.h"
#include "mtl_dxc.h"

#include <spirv_cross/spirv_cross.hpp>
#include <spirv_cross/spirv_msl.hpp>

#include <atomic>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <system_error>

#ifndef _WIN32
#include <unistd.h>
#endif

namespace fs = std::filesystem;

namespace xray::metal
{

	struct MetalShaderCompiler::Impl
	{
		detail::DxcSession dxc;
		std::string dxcExe;   // CLI fallback path ("" = unavailable)
		std::string cacheDir; // "" = cache disabled
	};

	MetalShaderCompiler::MetalShaderCompiler()
		: m_impl(std::make_unique<Impl>())
	{
	}

	MetalShaderCompiler::~MetalShaderCompiler() = default;

	bool MetalShaderCompiler::Init(std::vector<std::string> dxcompilerPaths, std::string dxcExe, std::string cacheDir)
	{
		m_impl->dxcExe = std::move(dxcExe);
		m_impl->cacheDir = std::move(cacheDir);

		std::string err;
		m_impl->dxc.Init(dxcompilerPaths, err); // in-process is preferred, CLI acceptable

		if (!m_impl->cacheDir.empty())
		{
			std::error_code ec;
			fs::create_directories(m_impl->cacheDir, ec);
		}
		return m_impl->dxc.Ready() || !m_impl->dxcExe.empty();
	}

	bool MetalShaderCompiler::HasInProcessDxc() const
	{
		return m_impl->dxc.Ready();
	}

	const char* MetalShaderCompiler::DxcBackendName() const
	{
		return m_impl->dxc.Ready() ? "dxc-inprocess" : "dxc-cli";
	}

	const char* MetalShaderCompiler::StageName(ShaderStage s)
	{
		switch (s)
		{
		case ShaderStage::Vertex: return "vs";
		case ShaderStage::Pixel: return "ps";
		case ShaderStage::Compute: return "cs";
		}
		return "?";
	}

	// DX9-era HLSL -> SM6 source rewrite. The Anomaly/XRay shader token variety
	// is small, so targeted textual replacement covers the corpus (bump maps,
	// sky, UI stubs). Extend the table as real shaders demand it.
	std::string MetalShaderCompiler::ApplyCompatShim(const std::string& in)
	{
		static const std::pair<const char*, const char*> repl[] = {
			{ "sampler2D", "Texture2D<float4>" },
			{ "samplerCUBE", "TextureCube<float4>" },
			{ "sampler_state", "SamplerState" },
			{ "tex2D", "Sample" },
			{ "tex2Dproj", "SampleProj" },
			{ "texCUBE", "SampleCube" },
		};
		std::string s = in;
		for (const auto& r : repl)
		{
			size_t pos = 0;
			const std::string from = r.first, to = r.second;
			while ((pos = s.find(from, pos)) != std::string::npos)
			{
				s.replace(pos, from.size(), to);
				pos += to.size();
			}
		}
		return s;
	}

	// SPIR-V -> MSL via SPIRV-Cross, in-process.
	static bool SpirvToMsl(const std::vector<uint32_t>& spirv, std::string& msl, std::string& error)
	{
		try
		{
			spirv_cross::CompilerMSL comp(spirv);
			spirv_cross::CompilerMSL::Options opts;
			opts.set_msl_version(2, 1);
			opts.platform = spirv_cross::CompilerMSL::Options::macOS;
			comp.set_msl_options(opts);
			msl = comp.compile();
		}
		catch (const std::exception& e)
		{
			error = std::string("spirv-cross: ") + e.what();
			return false;
		}
		return true;
	}

	// CLI fallback: shell out to the dxc executable. Used only when the
	// libdxcompiler dylib is unavailable (dev convenience, not the shipping path).
	static bool SpirvViaCli(const std::string& dxcExe, const std::string& hlsl, const std::string& entry,
	                        ShaderStage stage, const std::vector<std::string>& defines, std::vector<uint32_t>& spirv,
	                        std::string& messages, std::string& error)
	{
		std::error_code ec;
		fs::path tmp = fs::temp_directory_path(ec);
		if (ec)
		{
			error = "no temp dir";
			return false;
		}
		static std::atomic<unsigned> counter{0};
		const std::string stem = "xrmetal_" + std::to_string(static_cast<long>(getpid())) + "_" + std::to_string(counter++);
		fs::path hlslPath = tmp / (stem + ".hlsl");
		fs::path spvPath = tmp / (stem + ".spv");

		{
			std::ofstream f(hlslPath, std::ios::binary);
			f.write(hlsl.data(), static_cast<std::streamsize>(hlsl.size()));
		}

		std::string cmd = "\"" + dxcExe + "\" -T " + MetalShaderCompiler::StageName(stage) + "_6_0 -E " + entry +
		                  " -spirv -O1";
		for (const std::string& d : defines)
			cmd += " -D " + d;
		cmd += " -Fo \"" + spvPath.string() + "\" \"" + hlslPath.string() + "\" 2>&1";
		const int rc = std::system(cmd.c_str());

		std::string bytes;
		{
			std::ifstream f(spvPath, std::ios::binary);
			std::ostringstream ss;
			ss << f.rdbuf();
			bytes = ss.str();
		}
		std::error_code rmec;
		fs::remove(hlslPath, rmec);
		fs::remove(spvPath, rmec);

		if (rc != 0 || bytes.size() < 4 || (bytes.size() % 4) != 0)
		{
			error = "dxc-cli: compile failed (exit " + std::to_string(rc) + ")";
			return false;
		}
		spirv.resize(bytes.size() / 4);
		std::memcpy(spirv.data(), bytes.data(), bytes.size());
		if (spirv[0] != 0x07230203u)
		{
			error = "dxc-cli: bad SPIR-V magic";
			return false;
		}
		return true;
	}

	ShaderCompileResult MetalShaderCompiler::Compile(const std::string& hlslIn, const std::string& entry, ShaderStage stage,
	                                                 bool applyCompatShim, const std::vector<std::string>& defines)
	{
		ShaderCompileResult res;
		const std::string hlsl = applyCompatShim ? ApplyCompatShim(hlslIn) : hlslIn;

		// Cache key: FNV-1a over a format tag + stage + entry + defines + final
		// source. Bumping the tag invalidates every entry after pipeline changes.
		fs::path cacheFile;
		if (!m_impl->cacheDir.empty())
		{
			uint64_t h = 1469598103934665603ull;
			auto feed = [&h](const char* p, size_t n)
			{
				for (size_t i = 0; i < n; i++)
				{
					h ^= static_cast<uint8_t>(p[i]);
					h *= 1099511628211ull;
				}
			};
			std::string defStr;
			for (const std::string& d : defines)
			{
				defStr += d;
				defStr += ';';
			}
			const std::string tag = std::string("xrmetal-msl2.1|") + StageName(stage) + "|" + entry + "|" + defStr + "|";
			feed(tag.data(), tag.size());
			feed(hlsl.data(), hlsl.size());
			char hex[17];
			std::snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(h));
			cacheFile = fs::path(m_impl->cacheDir) / (hex + std::string(".msl"));

			std::ifstream in(cacheFile, std::ios::binary);
			if (in)
			{
				std::ostringstream ss;
				ss << in.rdbuf();
				res.msl = ss.str();
				res.fromCache = !res.msl.empty();
				res.ok = res.fromCache;
				if (!res.ok)
					res.error = "empty shader-cache entry";
				return res;
			}
		}

		std::vector<uint32_t> spirv;
		if (m_impl->dxc.Ready())
		{
			if (!m_impl->dxc.CompileToSpirv(hlsl, entry, stage, defines, spirv, res.messages, res.error))
				return res;
		}
		else if (!m_impl->dxcExe.empty())
		{
			if (!SpirvViaCli(m_impl->dxcExe, hlsl, entry, stage, defines, spirv, res.messages, res.error))
				return res;
		}
		else
		{
			res.error = "no DXC backend available";
			return res;
		}

		if (!SpirvToMsl(spirv, res.msl, res.error))
			return res;

		if (!cacheFile.empty())
		{
			std::ofstream out(cacheFile, std::ios::binary);
			out.write(res.msl.data(), static_cast<std::streamsize>(res.msl.size()));
		}
		res.ok = true;
		return res;
	}

} // namespace xray::metal
