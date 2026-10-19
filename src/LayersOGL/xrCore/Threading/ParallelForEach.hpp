#pragma once
// p4 GL-renderer port shim: dev's xrCore/Threading/ParallelForEach.hpp.
// Sequential per-element execution.
#include <utility>

template <class Container, class Fn>
void xr_parallel_for_each(Container&& container, Fn&& fn)
{
	for (auto&& item : container)
		fn(item);
}
