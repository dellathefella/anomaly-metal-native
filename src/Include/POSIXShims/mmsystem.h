// mmsystem.h — POSIX (macOS) shim. timeGetTime is provided by xrCore's
// win_compat (GetTickCount-based); multimedia timers are unused by the engine
// core beyond that.
#ifndef XR_POSIX_MMSYSTEM_H
#define XR_POSIX_MMSYSTEM_H

#ifndef TIMERR_NOERROR
#define TIMERR_NOERROR 0
#endif
#ifndef TIME_KILL_SYNCHRONOUS
#define TIME_KILL_SYNCHRONOUS 0x0100
#endif

typedef unsigned int MMRESULT_MMSYSTEM;

#endif // XR_POSIX_MMSYSTEM_H
