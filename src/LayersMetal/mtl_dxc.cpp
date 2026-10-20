// mtl_dxc.cpp — in-process DXC via dlopen + the DXC C API (COM-style).
//
// Non-Windows dxcapi.h routes through WinAdapter.h COM shims; with clang's
// -fms-extensions (global engine flag) __uuidof resolves natively via
// __declspec(uuid()) forward declarations. Interfaces are pure-virtual
// structs, so direct vtable calls work; __stdcall is a no-op on arm64.

#include "mtl_dxc.h"

#include <dlfcn.h>

#include <cstring>
#include <cstdio>
#include <cstdlib>

#include "dxc/dxcapi.h"

namespace xray::metal::detail
{

	DxcSession::~DxcSession()
	{
		if (m_compiler)
			static_cast<IDxcCompiler3*>(m_compiler)->Release();
		if (m_utils)
			static_cast<IDxcUtils*>(m_utils)->Release();
		if (m_lib)
			dlclose(m_lib);
	}

	bool DxcSession::Init(const std::vector<std::string>& dylibPaths, std::string& loadError)
	{
		for (const std::string& p : dylibPaths)
		{
			if (p.empty())
				continue;
			void* h = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
			if (!h)
				continue;
			void* create = dlsym(h, "DxcCreateInstance");
			if (!create)
			{
				dlclose(h);
				continue;
			}
			m_lib = h;
			m_createInstance = create;
			break;
		}
		if (!m_lib)
		{
			loadError = "no loadable libdxcompiler.dylib";
			return false;
		}

		auto create = reinterpret_cast<DxcCreateInstanceProc>(m_createInstance);
		HRESULT hr = create(CLSID_DxcUtils, __uuidof(IDxcUtils), &m_utils);
		if (FAILED(hr) || !m_utils)
		{
			loadError = "DxcCreateInstance(CLSID_DxcUtils) failed";
			return false;
		}
		hr = create(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), &m_compiler);
		if (FAILED(hr) || !m_compiler)
		{
			loadError = "DxcCreateInstance(CLSID_DxcCompiler) failed";
			return false;
		}
		return true;
	}

	static std::string WideToAscii(const wchar_t* w, size_t n)
	{
		std::string out;
		out.reserve(n);
		for (size_t i = 0; i < n; i++)
			out.push_back(w[i] < 0x80 ? static_cast<char>(w[i]) : '?');
		return out;
	}

	bool DxcSession::CompileToSpirv(const std::string& hlsl, const std::string& entry, ShaderStage stage,
	                                std::vector<uint32_t>& spirv, std::string& messages, std::string& error)
	{
		auto* utils = static_cast<IDxcUtils*>(m_utils);
		auto* compiler = static_cast<IDxcCompiler3*>(m_compiler);
		if (!utils || !compiler)
		{
			error = "dxc session not initialized";
			return false;
		}

		IDxcBlobEncoding* srcBlob = nullptr;
		HRESULT hr = utils->CreateBlobFromPinned(hlsl.data(), static_cast<UINT32>(hlsl.size()), 0, &srcBlob);
		if (FAILED(hr) || !srcBlob)
		{
			error = "dxc: CreateBlobFromPinned failed";
			return false;
		}

		// DXC arguments are LPCWSTR; on POSIX wchar_t is 4 bytes and DXC treats
		// them as wide (UTF-32) — plain-ASCII literals convert losslessly.
		const wchar_t* target = stage == ShaderStage::Vertex ? L"vs_6_0"
		                      : stage == ShaderStage::Pixel ? L"ps_6_0"
		                                                    : L"cs_6_0";
		std::wstring wentry;
		wentry.reserve(entry.size());
		for (char c : entry)
			wentry.push_back(static_cast<wchar_t>(static_cast<unsigned char>(c)));

		std::vector<LPCWSTR> args = {
			L"-E", wentry.c_str(),
			L"-T", target,
			L"-spirv",
			L"-O1",
		};

		DxcBuffer srcBuf;
		srcBuf.Ptr = srcBlob->GetBufferPointer();
		srcBuf.Size = srcBlob->GetBufferSize();
		srcBuf.Encoding = 0;

		IDxcResult* result = nullptr;
		hr = compiler->Compile(&srcBuf, args.data(), static_cast<UINT32>(args.size()), nullptr,
		                       __uuidof(IDxcResult), reinterpret_cast<void**>(&result));
		srcBlob->Release();
		if (FAILED(hr) || !result)
		{
			error = "dxc: IDxcCompiler3::Compile failed";
			return false;
		}

		HRESULT status = S_OK;
		result->GetStatus(&status);

		// Diagnostics: prefer UTF-8, fall back to wide.
		IDxcBlobUtf8* errUtf8 = nullptr;
		if (SUCCEEDED(result->GetOutput(DXC_OUT_ERRORS, __uuidof(IDxcBlobUtf8),
		                                reinterpret_cast<void**>(&errUtf8), nullptr)) && errUtf8)
		{
			messages.assign(static_cast<const char*>(errUtf8->GetBufferPointer()), errUtf8->GetBufferSize());
			errUtf8->Release();
		}
		else
		{
			IDxcBlobWide* errWide = nullptr;
			if (SUCCEEDED(result->GetOutput(DXC_OUT_ERRORS, __uuidof(IDxcBlobWide),
			                                reinterpret_cast<void**>(&errWide), nullptr)) && errWide)
			{
				messages = WideToAscii(static_cast<const wchar_t*>(errWide->GetBufferPointer()),
				                       static_cast<size_t>(errWide->GetStringLength()));
				errWide->Release();
			}
		}

		if (FAILED(status))
		{
			result->Release();
			error = "dxc compile error (see messages)";
			return false;
		}

		IDxcBlob* obj = nullptr;
		hr = result->GetOutput(DXC_OUT_OBJECT, __uuidof(IDxcBlob), reinterpret_cast<void**>(&obj), nullptr);
		result->Release();
		if (FAILED(hr) || !obj)
		{
			error = "dxc: no SPIR-V output blob";
			return false;
		}

		const uint8_t* bytes = static_cast<const uint8_t*>(obj->GetBufferPointer());
		const size_t n = obj->GetBufferSize();
		if (n < 4 || (n % 4) != 0)
		{
			obj->Release();
			error = "dxc: short SPIR-V blob";
			return false;
		}
		spirv.resize(n / 4);
		std::memcpy(spirv.data(), bytes, n); // copy BEFORE the blob is released
		obj->Release();
		if (spirv[0] != 0x07230203u)
		{
			const uint32_t w = spirv[0];
			char hexbuf[32];
			std::snprintf(hexbuf, sizeof(hexbuf), "%02x %02x %02x %02x",
			              w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff);
			error = std::string("dxc: bad SPIR-V magic (first bytes: ") + hexbuf + ", size " + std::to_string(n) + ")";
			if (const char* dump = std::getenv("DXC_DUMP_PATH")) // debug aid
			{
				FILE* f = std::fopen(dump, "wb");
				if (f)
				{
					std::fwrite(spirv.data(), 1, n, f);
					std::fclose(f);
				}
			}
			return false;
		}
		return true;
	}

} // namespace xray::metal::detail
