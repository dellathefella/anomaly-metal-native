// malloc.h — POSIX (macOS) shim for MSVC's <malloc.h>.
#ifndef XR_POSIX_MALLOC_H
#define XR_POSIX_MALLOC_H

#include <stdlib.h>
#include <malloc/malloc.h>
#include <string.h> // bzero/bcopy historically lived here on MSVC

#ifndef _malloca
#define _malloca(s) alloca(s)
#endif
#ifndef _freea
#define _freea(p) ((void)0)
#endif

#endif // XR_POSIX_MALLOC_H
