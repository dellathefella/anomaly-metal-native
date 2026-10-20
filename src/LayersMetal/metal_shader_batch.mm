// metal_shader_batch.mm — validate a DX9-era shader corpus through the exact
// runtime pipeline the Metal renderer will use:
//
//   .ps/.vs -> TranslateDx9Shader -> DXC (in-process) -> SPIRV-Cross -> MSL
//           -> newLibraryWithSource (on-device MSL validation)
//
// Usage: metal_shader_batch [shaderRoot] [report.tsv] [nameFilter]
// shaderRoot defaults to the searge-coc r2 tree (Anomaly-lineage shaders).
// nameFilter, if given, restricts processing to files whose path contains it.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mtl_dx9_translate.h"
#include "mtl_shader_compiler.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#ifndef DXC_PATH
#define DXC_PATH "/Users/jdella/Desktop/anomaly-metal-native/repos/dxc/build-mac/bin/dxc"
#endif
#ifndef DXCOMPILER_PATH
#define DXCOMPILER_PATH "/Users/jdella/Desktop/anomaly-metal-native/repos/dxc/build-mac/lib/libdxcompiler.dylib"
#endif
#ifndef XR_METAL_CORPUS_DIR
#define XR_METAL_CORPUS_DIR "/Users/jdella/Desktop/anomaly-metal-native/repos/searge-coc/res/gamedata/shaders/r2"
#endif

namespace fs = std::filesystem;

namespace
{

	struct Row
	{
		std::string file;
		const char* status;
		std::string detail;
	};

	std::string ReadFile(const std::string& p)
	{
		std::ifstream f(p, std::ios::binary);
		std::ostringstream ss;
		ss << f.rdbuf();
		return ss.str();
	}

	std::string FirstLine(const std::string& s)
	{
		auto nl = s.find('\n');
		std::string l = nl == std::string::npos ? s : s.substr(0, nl);
		auto start = l.find_first_not_of(" \t\r");
		return start == std::string::npos ? std::string() : l.substr(start);
	}

	// First line containing "error:" (DXC emits warnings before errors);
	// falls back to the first line.
	std::string ErrorLine(const std::string& s)
	{
		std::istringstream in(s);
		std::string line;
		std::string first;
		while (std::getline(in, line))
		{
			if (first.empty())
				first = FirstLine(line);
			if (line.find("error:") != std::string::npos)
				return FirstLine(line);
		}
		return first;
	}

} // namespace

int main(int argc, char** argv)
{
	@autoreleasepool
	{
		const std::string root = argc > 1 ? argv[1] : XR_METAL_CORPUS_DIR;
		const std::string reportPath = argc > 2 ? argv[2] : "/tmp/metal_shader_batch.tsv";
		const char* filter = argc > 3 ? argv[3] : nullptr; // substring triage filter

		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (!device)
		{
			printf("FAIL: no Metal device\n");
			return 2;
		}

		xray::metal::MetalShaderCompiler sh;
		if (!sh.Init({DXCOMPILER_PATH}, DXC_PATH, "/tmp/xrmetal_batch_cache") || !sh.HasInProcessDxc())
		{
			printf("FAIL: shader compiler init (in-process DXC unavailable)\n");
			return 2;
		}

		// include search: shader root itself + the tree above it
		// (so "shared\\common.h" resolves from an r2/ corpus).
		std::vector<std::string> includeDirs;
		includeDirs.push_back(root);
		std::error_code ec;
		includeDirs.push_back(fs::path(root).parent_path().string());

		std::vector<std::string> files;
		for (const auto& entry : fs::recursive_directory_iterator(root, fs::directory_options::skip_permission_denied, ec))
		{
			if (ec)
				break;
			std::error_code fec;
			if (!entry.is_regular_file(fec) || fec)
				continue;
			// Skip Searge's scratch/experimental sub-tree.
			bool inTest = false;
			for (auto it = entry.path().begin(), e = entry.path().end(); it != e; ++it)
				if (it->string() == "test")
					inTest = true;
			if (inTest)
				continue;
			const std::string ext = entry.path().extension().string();
			if (ext == ".ps" || ext == ".vs")
				files.push_back(entry.path().string());
		}
		std::sort(files.begin(), files.end());

		printf("== metal_shader_batch: %zu shaders from %s (backend %s) ==\n", files.size(), root.c_str(),
		       sh.DxcBackendName());

		std::vector<Row> rows;
		int mslOk = 0, dxcFail = 0, transFail = 0, mslFail = 0;

		for (const std::string& f : files)
		{
			if (filter && f.find(filter) == std::string::npos)
				continue;
			const auto stage = fs::path(f).extension() == ".vs" ? xray::metal::ShaderStage::Vertex
			                                                    : xray::metal::ShaderStage::Pixel;
			Row row{f, "OK", {}};

			const std::string src = ReadFile(f);
			xray::metal::Dx9Translation tr = xray::metal::TranslateDx9Shader(src, f, stage, includeDirs);
			if (!tr.ok)
			{
				row.status = "TRANS_FAIL";
				row.detail = tr.error;
				transFail++;
				rows.push_back(std::move(row));
				continue;
			}

			// Entry point: XRay shader scripts bind by name; most define
			// 'main', others a stem-derived or profile-suffixed variant
			// (main_ps_1_1 / main_ps_3_0 / ssao_blur_ps). Discover candidates
			// from the source; helpers (calc_ssao) must NOT qualify, so only
			// names *starting* with main/stem count.
			const std::string stem = fs::path(f).stem().string();
			std::vector<std::string> entries{"main", stem + (stage == xray::metal::ShaderStage::Pixel ? "_ps" : "_vs"),
			                                 stem};
			{
				static const std::regex fnRe(R"(([A-Za-z_][A-Za-z0-9_]*)\s*\()");
				auto begin = std::sregex_iterator(tr.hlsl.begin(), tr.hlsl.end(), fnRe);
				auto end = std::sregex_iterator();
				for (auto it = begin; it != end; ++it)
				{
					const std::string name = (*it)[1].str();
					const bool mainish = name.compare(0, 4, "main") == 0 ||
					                     (!stem.empty() && name.compare(0, stem.size(), stem) == 0);
					if (mainish && std::find(entries.begin(), entries.end(), name) == entries.end())
						entries.push_back(name);
				}
			}

			// Compile every candidate entry; keep the first diagnostic that is
			// more informative than a bare 'entry not found'.
			auto attempt = [&](const xray::metal::Dx9Translation& t, const std::vector<std::string>& defines,
			                   xray::metal::ShaderCompileResult& comp, std::string& usedEntry, std::string& realMsg)
			{
				for (const std::string& e : entries)
				{
					comp = sh.Compile(t.hlsl, e, stage, /*applyCompatShim=*/false, defines);
					if (comp.ok)
					{
						usedEntry = e;
						return true;
					}
					if (realMsg.empty() && comp.messages.find("missing entry point definition") == std::string::npos)
						realMsg = ErrorLine(!comp.messages.empty() ? comp.messages : comp.error);
				}
				return false;
			};

			xray::metal::ShaderCompileResult comp;
			std::string usedEntry, realMsg;
			if (!attempt(tr, {}, comp, usedEntry, realMsg))
			{
				// DX9 COLOR* semantics on PS inputs: retry mapping them to
				// high TEXCOORD slots instead of SV_TARGET.
				if (realMsg.find("invalid usage of semantic 'SV_TARGET") != std::string::npos ||
				    realMsg.find("invalid usage of semantic 'COLOR") != std::string::npos)
				{
					xray::metal::Dx9TranslateOptions opts;
					opts.colorInputsAsTexcoord = true;
					auto tr2 = xray::metal::TranslateDx9Shader(src, f, stage, includeDirs, opts);
					if (tr2.ok)
					{
						std::string msg2;
						if (attempt(tr2, {}, comp, usedEntry, msg2))
						{
							tr = std::move(tr2);
							realMsg.clear();
						}
						else if (!msg2.empty())
							realMsg = msg2;
					}
				}
				// Script-injected defines (USE_SUNMASK / SKIN_* come from the
				// .compile/.pass scripts at runtime): retry with a set when
				// identifiers are missing or every entry candidate was behind
				// an #ifdef.
				else if (realMsg.find("undeclared identifier") != std::string::npos || realMsg.empty())
				{
					static const std::vector<std::string> scriptDefines = {"USE_SUNMASK",     "USE_SUNFILTER",
					                                                       "USE_R2_STATIC_SUN", "USE_STATIC_FLASH",
					                                                       "SKIN_NONE",         "SSAO_QUALITY=3"};
					std::string msg2;
					if (!attempt(tr, scriptDefines, comp, usedEntry, msg2))
					{
						if (!msg2.empty())
							realMsg = msg2;
					}
					else
						realMsg.clear();
				}
			}

			if (!comp.ok)
			{
				row.status = "DXC_FAIL";
				row.detail = !realMsg.empty() ? realMsg : ErrorLine(!comp.messages.empty() ? comp.messages : comp.error);
				dxcFail++;
				if (filter)
					printf("== %s full messages ==\n%s\n", fs::path(f).filename().string().c_str(), comp.messages.c_str());
			}
			else
			{
				// On-device MSL validation: SPIRV-Cross keeps the entry
				// name (MSL-reserved 'main' is renamed to main0).
				@autoreleasepool
				{
					NSError* nserr = nil;
					id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:comp.msl.c_str()]
					                                        options:nil
					                                          error:&nserr];
					id<MTLFunction> fn = nil;
					if (lib)
					{
						fn = [lib newFunctionWithName:[NSString stringWithUTF8String:usedEntry.c_str()]];
						if (!fn)
							fn = [lib newFunctionWithName:@"main"];
						if (!fn)
							fn = [lib newFunctionWithName:@"main0"];
					}
					if (lib && fn)
					{
						row.status = "MSL_OK";
						mslOk++;
					}
					else
					{
						row.status = "MSL_FAIL";
						row.detail = FirstLine(nserr ? nserr.localizedDescription.UTF8String : "no main function");
						mslFail++;
					}
				}
			}
			rows.push_back(std::move(row));
		}

		printf("BATCH_SUMMARY total=%zu msl_ok=%d dxc_fail=%d trans_fail=%d msl_fail=%d\n", files.size(), mslOk,
		       dxcFail, transFail, mslFail);

		int shown = 0;
		std::map<std::string, std::pair<int, std::string>> byDetail; // detail -> (count, first file)
		for (const Row& r : rows)
		{
			if (std::string(r.status).find("OK") != std::string::npos)
				continue;
			auto& e = byDetail[r.detail];
			if (!e.first++)
				e.second = r.file;
		}
		for (const auto& [detail, info] : byDetail)
		{
			if (shown++ < 40)
				printf("  x%-4d %s | %s\n", info.first, fs::path(info.second).filename().string().c_str(),
				       detail.c_str());
		}

		std::ofstream rep(reportPath, std::ios::binary);
		rep << "file\tstatus\tdetail\n";
		for (const Row& r : rows)
			rep << r.file << '\t' << r.status << '\t' << r.detail << '\n';
		printf("report: %s\n", reportPath.c_str());

		return mslOk > 0 ? 0 : 1;
	}
}
