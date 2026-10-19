#pragma once
// p4: forward to the monolith's own guarded defs header — identical consts and
// BlendSVec typedefs; the monolith Include/xrRender chain pulls that copy into
// the same TUs, so a second definition here would be a redefinition error.
#include "../../Layers/xrRender/KinematicAnimatedDefs.h"
