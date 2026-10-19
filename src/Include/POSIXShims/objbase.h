// objbase.h — POSIX (macOS) shim for the OLE base header. The engine only
// pulls it in transitively (COM allocators are unused; see the COM shims in
// xrCore/win_compat.h and the DirectPlay stub).
#ifndef XR_POSIX_OBJBASE_H
#define XR_POSIX_OBJBASE_H

// COM apartment init — no-op shims (OpenAL device enumeration calls these).
#ifndef COINIT_MULTITHREADED
#define COINIT_MULTITHREADED 0x0
#define COINIT_APARTMENTTHREADED 0x2
inline HRESULT CoInitializeEx(void*, unsigned int) { return 0; }
inline void CoUninitialize() {}
#endif

#endif // XR_POSIX_OBJBASE_H
