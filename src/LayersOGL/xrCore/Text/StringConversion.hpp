#pragma once
// p4 shim: the monolith already provides the identical multibyte helper
// surface (mbhMulti2Wide, Is*Character predicates, MAX_MB_CHARS) through
// xrEngine/MbHelpers.h. Dev's own copies collide with those (BOOL vs bool
// return types), so this header only maps dev's spellings onto them.
#include "xrEngine/MbHelpers.h"

typedef wide_char xr_wide_char; // Don't replace it with wchar_t, it won't work correctly, I don't know why.
