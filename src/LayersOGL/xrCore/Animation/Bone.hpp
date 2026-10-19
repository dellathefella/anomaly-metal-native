#pragma once
// p4 GL-renderer port shim: OpenXRay moved the bone model (CBoneInstance,
// CBoneData, SBoneShape, vertBonedNW, EBoneCallbackType, BI_NONE ...) to
// xrCore/Animation; the monolith keeps the identical types in xrEngine/bone.h.
#include "xrEngine/bone.h"
