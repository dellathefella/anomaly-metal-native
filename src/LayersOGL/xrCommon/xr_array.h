#pragma once
// p4 GL-renderer port shim: OpenXRay's xrCommon/xr_array.h — it is std::array
// under the xr spelling.

#include <array>

template <class T, std::size_t N>
using xr_array = std::array<T, N>;
