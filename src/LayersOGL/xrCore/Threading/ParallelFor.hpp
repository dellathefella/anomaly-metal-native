#pragma once
// p4 GL-renderer port shim: dev's xrCore/Threading/ParallelFor.hpp.
// Sequential execution: the callback receives the full range once.
#include <cstddef>
#include <iterator>

template <class T>
class TaskRange
{
	T m_begin{};
	T m_end{};

public:
	constexpr TaskRange() = default;
	constexpr TaskRange(T begin, T end) : m_begin(begin), m_end(end) {}

	constexpr T begin() const { return m_begin; }
	constexpr T end() const { return m_end; }
	constexpr T size() const { return m_end - m_begin; }
};

template <class Range, class Fn>
void xr_parallel_for(Range&& range, Fn&& fn)
{
	fn(range);
}
