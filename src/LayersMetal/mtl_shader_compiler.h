#pragma once
// Runtime shader compiler for the native Metal renderer (p5).
//
//   HLSL -> SPIR-V (DXC) -> MSL (SPIRV-Cross), plus a hash-keyed on-disk cache.
//
// DXC prefers the in-process path (dlopen libdxcompiler.dylib, DXC C API);
// when that library is not available it falls back to the dxc CLI. The output
// is MSL *source text*; turning it into MTLLibrary/MTLFunction is the caller's
// job on the Objective-C++ side. Keeping Metal out of this header means no
// WinAdapter.h COM macros ever leak into .mm translation units.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace xray::metal
{

	enum class ShaderStage
	{
		Vertex,
		Pixel,
		Compute,
	};

	struct ShaderCompileResult
	{
		bool ok = false;
		bool fromCache = false;
		std::string msl;      // Metal Shading Language source (valid when ok)
		std::string messages; // DXC diagnostics (warnings/errors), may be empty
		std::string error;    // short failure reason (when !ok)
	};

	class MetalShaderCompiler
	{
	public:
		MetalShaderCompiler();
		~MetalShaderCompiler();
		MetalShaderCompiler(const MetalShaderCompiler&) = delete;
		MetalShaderCompiler& operator=(const MetalShaderCompiler&) = delete;

		// dxcompilerPaths: candidate paths for libdxcompiler.dylib (in-process DXC).
		// dxcExe: dxc CLI used when no in-process DXC loaded (may be empty).
		// cacheDir: directory for the hash-keyed MSL cache (empty disables it).
		// Returns false only when NO backend at all is usable.
		bool Init(std::vector<std::string> dxcompilerPaths, std::string dxcExe, std::string cacheDir);

		bool HasInProcessDxc() const;
		const char* DxcBackendName() const; // "dxc-inprocess" | "dxc-cli"

		ShaderCompileResult Compile(const std::string& hlsl, const std::string& entry, ShaderStage stage,
		                            bool applyCompatShim = true, const std::vector<std::string>& defines = {});

		// Renderer path: compile WITHOUT the on-disk MSL cache (the renderer
		// keeps its own cache with serialized reflection alongside) and hand
		// back the SPIR-V so the caller can reflect it. Requires in-process DXC.
		bool CompileWithSpirv(const std::string& hlsl, const std::string& entry, ShaderStage stage,
		                      const std::vector<std::string>& defines, ShaderCompileResult& res,
		                      std::vector<uint32_t>& spirvOut);

		// SPIR-V -> MSL (in-process SPIRV-Cross). Exposed for the renderer path
		// which already holds the SPIR-V from CompileWithSpirv.
		static bool SpirvToMsl(const std::vector<uint32_t>& spirv, std::string& msl, std::string& error);

		// DX9-era HLSL -> SM6 source rewrite (Anomaly-era token set is small and
		// textual). Pure function; exposed for tests and tooling.
		static std::string ApplyCompatShim(const std::string& src);
		static const char* StageName(ShaderStage s);

	private:
		struct Impl;
		std::unique_ptr<Impl> m_impl;
	};

} // namespace xray::metal
