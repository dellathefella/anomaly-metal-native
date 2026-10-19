// ModuleLookup.hpp — POSIX (macOS) stand-in for OpenXRay's module-lookup
// helper, needed by the ported GL renderer (p4). The monolith already carries
// LoadLibrary/GetProcAddress shims on top of dlopen; this mirrors that with
// the small XRay::ModuleHandle surface the renderer includes.
#pragma once

#include <dlfcn.h>
#include <memory>

namespace XRay
{
class ModuleHandle
{
	void* handle;
	bool dontUnload;

public:
	ModuleHandle(const bool dontUnload = false) : handle(nullptr), dontUnload(dontUnload)
	{
	}

	ModuleHandle(pcstr moduleName, bool dontUnload = false) : handle(nullptr), dontUnload(dontUnload)
	{
		Open(moduleName);
	}

	~ModuleHandle()
	{
		Close();
	}

	void* Open(pcstr moduleName)
	{
		handle = dlopen(moduleName, RTLD_LAZY | RTLD_GLOBAL);
		return handle;
	}

	void Close()
	{
		if (handle && !dontUnload)
			dlclose(handle);
		handle = nullptr;
	}

	bool IsLoaded() const
	{
		return handle != nullptr;
	}

	void* operator()() const
	{
		return handle;
	}

	void* GetProcAddress(pcstr procName) const
	{
		return handle ? dlsym(handle, procName) : nullptr;
	}
};

using Module = std::unique_ptr<ModuleHandle>;

inline Module LoadModule(bool dontUnload = false)
{
	return std::make_unique<ModuleHandle>(dontUnload);
}

inline Module LoadModule(pcstr moduleName, bool dontUnload = false)
{
	return std::make_unique<ModuleHandle>(moduleName, dontUnload);
}
} // namespace XRay
