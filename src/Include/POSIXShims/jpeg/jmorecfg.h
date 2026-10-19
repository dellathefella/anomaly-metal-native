#pragma once
// POSIX shim: cximage includes <jpeg/jmorecfg.h>; brew jpeg-turbo provides it
// flat. jpeglib.h must come first (libjpeg header pairing).
#include <jpeglib.h>
#include_next <jmorecfg.h>
