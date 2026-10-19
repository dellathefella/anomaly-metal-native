#pragma once
// POSIX shim: cximage includes <jpeg/jpeglib.h>; brew jpeg-turbo provides it
// flat. libjpeg's headers need the C stdio/stddef context first.
#include <stdio.h>
#include <stddef.h>
#include_next <jpeglib.h>
