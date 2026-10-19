// process.h — POSIX (macOS) shim for MSVC's <process.h>.
// The engine only needs the low-level spawn/getpid surface; process helpers
// come from <unistd.h>.
#ifndef XR_POSIX_PROCESS_H
#define XR_POSIX_PROCESS_H

#include <unistd.h>

#ifndef _getpid
#define _getpid getpid
#endif
#ifndef _getcwd
#define _getcwd getcwd
#endif
#ifndef _chdir
#define _chdir chdir
#endif

// MSVC spawn modes (unused by the port; kept for source compatibility)
#define _P_WAIT 0
#define _P_NOWAIT 1
#define _P_OVERLAY 2
#define _P_NOWAITO 3
#define _P_DETACH 4

#endif // XR_POSIX_PROCESS_H
