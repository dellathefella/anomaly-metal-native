#pragma once
// In-process DXC: dlopen libdxcompiler.dylib + DxcCreateInstance (DXC C API).
// Isolated in its own TU because dxcapi.h drags in WinAdapter.h Windows-compat
// macros (FAILED, GUID shims, __uuidof emulation) that must NOT leak into
// Objective-C++/Metal translation units or the engine's stdafx world.

#include "mtl_shader_compiler.h"

namespace xray::metal::detail
{

	class DxcSession
	{
	public:
		DxcSession() = default;
		~DxcSession();
		DxcSession(const DxcSession&) = delete;
		DxcSession& operator=(const DxcSession&) = delete;

		// dlopen candidates in order; on success creates IDxcUtils + IDxcCompiler3.
		bool Init(const std::vector<std::string>& dylibPaths, std::string& loadError);
		bool Ready() const { return m_compiler != nullptr; }

		bool CompileToSpirv(const std::string& hlsl, const std::string& entry, ShaderStage stage,
		                    const std::vector<std::string>& defines, std::vector<uint32_t>& spirv, std::string& messages,
		                    std::string& error);

	private:
		void* m_lib = nullptr;           // dlopen handle
		void* m_createInstance = nullptr; // DxcCreateInstanceProc
		void* m_utils = nullptr;         // IDxcUtils*
		void* m_compiler = nullptr;      // IDxcCompiler3*
	};

} // namespace xray::metal::detail
