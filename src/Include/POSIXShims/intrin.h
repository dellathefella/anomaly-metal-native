// intrin.h — POSIX (macOS) shim for MSVC's <intrin.h>.
// clang's own intrin.h is Windows-only (on other platforms it
// #include_next's to a system intrin.h that does not exist on macOS).
// Provide the handful of MSVC compiler intrinsics the engine references.
#ifndef XR_POSIX_INTRIN_H
#define XR_POSIX_INTRIN_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Bit scans (xr_object.cpp / memory allocators)
#ifndef _BitScanForward
static inline unsigned char _BitScanForward(unsigned long* Index, unsigned long Mask)
{
    if (!Mask)
        return 0;
    *Index = (unsigned long)__builtin_ctzl(Mask);
    return 1;
}
#endif
#ifndef _BitScanReverse
static inline unsigned char _BitScanReverse(unsigned long* Index, unsigned long Mask)
{
    if (!Mask)
        return 0;
    *Index = (unsigned long)(63 - __builtin_clzl(Mask));
    return 1;
}
#endif
#ifndef _BitScanForward64
static inline unsigned char _BitScanForward64(unsigned long* Index, unsigned long long Mask)
{
    if (!Mask)
        return 0;
    *Index = (unsigned long)__builtin_ctzll(Mask);
    return 1;
}
#endif
#ifndef _BitScanReverse64
static inline unsigned char _BitScanReverse64(unsigned long* Index, unsigned long long Mask)
{
    if (!Mask)
        return 0;
    *Index = (unsigned long)(63 - __builtin_clzll(Mask));
    return 1;
}
#endif

// Time-stamp counter substitute (monotonic nanoseconds)
#ifndef __rdtsc
static inline unsigned long long __rdtsc(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ull + (unsigned long long)ts.tv_nsec;
}
#endif
#ifndef __rdtscp
static inline unsigned long long __rdtscp(unsigned long*) { return __rdtsc(); }
#endif

// Compiler barrier
#ifndef _ReadBarrier
#define _ReadBarrier __atomic_thread_fence(__ATOMIC_ACQUIRE)
#endif
#ifndef _WriteBarrier
#define _WriteBarrier __atomic_thread_fence(__ATOMIC_RELEASE)
#endif
#ifndef _ReadWriteBarrier
#define _ReadWriteBarrier __atomic_thread_fence(__ATOMIC_SEQ_CST)
#endif

#endif // XR_POSIX_INTRIN_H
