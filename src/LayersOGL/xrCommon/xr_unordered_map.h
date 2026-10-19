#pragma once
// p4 GL-renderer port shim: OpenXRay's xrCommon/xr_unordered_map.h on top of
// the monolith's own STL allocator (xalloc, xrCore/_stl_extensions.h).

#include <unordered_map>

#include "xrCore/_stl_extensions.h"

template <typename K, class V, class Hasher = std::hash<K>, class Traits = std::equal_to<K>,
          typename allocator = xalloc<std::pair<const K, V>>>
using xr_unordered_map = std::unordered_map<K, V, Hasher, Traits, allocator>;
