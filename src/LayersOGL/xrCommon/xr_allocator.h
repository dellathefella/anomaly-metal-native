#pragma once
// p4 GL-renderer port shim: OpenXRay's xrCommon/xr_static_allocator.h (alias of dev's
// static xalloc). FixedMap calls allocate/construct/deallocate statically on
// the type, so this mirrors dev's xrCore/Memory/xalloc.h statics on top of the
// monolith's xr_malloc family.
#include <cstddef>
#include <new>
#include <utility>

#include "xrCore/_stl_extensions.h" // xalloc, xr_alloc, xr_malloc/xr_free

template <class T>
class xr_static_allocator
{
public:
	typedef T value_type;
	typedef T* pointer;
	typedef std::size_t size_type;

	static pointer allocate(const size_type n, const void* /*hint*/ = nullptr)
	{
		return xr_alloc<T>(n);
	}

	static void deallocate(pointer p, const size_type /*n*/) { xr_free(p); }
	static void deallocate(void* p, const size_type /*n*/) { xr_free(p); }

	template <class U, class... Args>
	static void construct(U* ptr, Args&&... args)
	{
		new (ptr) U(std::forward<Args>(args)...);
	}

	template <class U>
	static void destroy(U* p)
	{
		p->~U();
	}

	static constexpr size_type max_size() { return size_type(-1) / sizeof(T); }
};
