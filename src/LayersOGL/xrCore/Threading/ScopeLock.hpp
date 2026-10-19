#pragma once
// p4 shim: dev moved Lock/ScopeLock into xrCore/Threading/; the monolith keeps
// them at xrCore root. Same classes, same Enter()/Leave() API.
#include "xrCore/ScopeLock.hpp"
