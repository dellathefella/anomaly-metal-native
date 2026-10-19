// win_compat.h — POSIX (macOS) compatibility layer for Win32 primitives used
// by monolith-era X-Ray code. Complements Common/PlatformApple.inl (which
// already provides basic types, Sleep, _splitpath, safe strings, etc.) and is
// included from the POSIX branch of xrCore_platform.h.
//
// Design rule: keep Win32 call sites intact in engine code; implement the
// small set of APIs they actually use here.

#pragma once

#ifdef XR_PLATFORM_POSIX

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <pthread.h>
#include <malloc/malloc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Remaining basic types
// ---------------------------------------------------------------------------
#ifndef BYTE
typedef unsigned char BYTE;
#endif
typedef BYTE* LPBYTE;
typedef int64_t LONGLONG;

#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#endif
#ifndef INVALID_FILE_ATTRIBUTES
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)
#endif

typedef LARGE_INTEGER* PLARGE_INTEGER;

struct FILETIME
{
    uint32_t dwLowDateTime;
    uint32_t dwHighDateTime;
};

struct SYSTEMTIME
{
    WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
};

typedef const void* LPCVOID;

// ---------------------------------------------------------------------------
// Critical sections (recursive, matching CRITICAL_SECTION semantics)
// ---------------------------------------------------------------------------
typedef pthread_mutex_t CRITICAL_SECTION;

inline void InitializeCriticalSection(CRITICAL_SECTION* cs)
{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(cs, &attr);
    pthread_mutexattr_destroy(&attr);
}
inline void InitializeCriticalSectionAndSpinCount(CRITICAL_SECTION* cs, unsigned) { InitializeCriticalSection(cs); }
inline void DeleteCriticalSection(CRITICAL_SECTION* cs) { pthread_mutex_destroy(cs); }
inline void EnterCriticalSection(CRITICAL_SECTION* cs) { pthread_mutex_lock(cs); }
inline void LeaveCriticalSection(CRITICAL_SECTION* cs) { pthread_mutex_unlock(cs); }
inline BOOL TryEnterCriticalSection(CRITICAL_SECTION* cs) { return pthread_mutex_trylock(cs) == 0; }

// ---------------------------------------------------------------------------
// Events / waits
// ---------------------------------------------------------------------------
struct xr_win_event
{
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    bool signaled;
    bool manual_reset;
};

inline HANDLE CreateEventA(void*, BOOL manual_reset, BOOL initial, void*)
{
    xr_win_event* ev = new xr_win_event;
    pthread_mutex_init(&ev->mtx, NULL);
    pthread_cond_init(&ev->cond, NULL);
    ev->signaled = initial != FALSE;
    ev->manual_reset = manual_reset != FALSE;
    return (HANDLE)ev;
}
#define CreateEventW CreateEventA
#define CreateEvent CreateEventA

inline BOOL SetEvent(HANDLE h)
{
    xr_win_event* ev = (xr_win_event*)h;
    pthread_mutex_lock(&ev->mtx);
    ev->signaled = true;
    if (ev->manual_reset)
        pthread_cond_broadcast(&ev->cond);
    else
        pthread_cond_signal(&ev->cond);
    pthread_mutex_unlock(&ev->mtx);
    return TRUE;
}

inline BOOL ResetEvent(HANDLE h)
{
    xr_win_event* ev = (xr_win_event*)h;
    pthread_mutex_lock(&ev->mtx);
    ev->signaled = false;
    pthread_mutex_unlock(&ev->mtx);
    return TRUE;
}

inline BOOL PulseEvent(HANDLE h) { return ResetEvent(h); }

inline void CloseEventShim(HANDLE h)
{
    xr_win_event* ev = (xr_win_event*)h;
    pthread_cond_destroy(&ev->cond);
    pthread_mutex_destroy(&ev->mtx);
    delete ev;
}

enum : unsigned long
{
    WAIT_OBJECT_0 = 0,
    WAIT_TIMEOUT = 0x00000102L,
    WAIT_FAILED = 0xFFFFFFFFL,
    XR_INFINITE = 0xFFFFFFFF
};

inline unsigned long WaitForSingleObject(HANDLE h, unsigned long ms)
{
    xr_win_event* ev = (xr_win_event*)h;
    pthread_mutex_lock(&ev->mtx);
    if (!ev->signaled && ms == XR_INFINITE)
    {
        while (!ev->signaled)
            pthread_cond_wait(&ev->cond, &ev->mtx);
    }
    else if (!ev->signaled)
    {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += ms / 1000;
        ts.tv_nsec += (long)(ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        int rc = 0;
        while (!ev->signaled && rc == 0)
            rc = pthread_cond_timedwait(&ev->cond, &ev->mtx, &ts);
        if (!ev->signaled)
        {
            pthread_mutex_unlock(&ev->mtx);
            return WAIT_TIMEOUT;
        }
    }
    if (!ev->manual_reset)
        ev->signaled = false;
    pthread_mutex_unlock(&ev->mtx);
    return WAIT_OBJECT_0;
}

inline unsigned long WaitForMultipleObjects(unsigned long, HANDLE*, BOOL, unsigned long) { return WAIT_OBJECT_0; }

// ---------------------------------------------------------------------------
// Interlocked operations
// ---------------------------------------------------------------------------
inline LONG InterlockedIncrement(volatile LONG* p) { return __sync_add_and_fetch(p, 1); }
inline LONG InterlockedDecrement(volatile LONG* p) { return __sync_sub_and_fetch(p, 1); }
inline LONG InterlockedExchange(volatile LONG* p, LONG v) { return __sync_lock_test_and_set(p, v); }
inline LONG InterlockedExchangeAdd(volatile LONG* p, LONG v) { return __sync_fetch_and_add(p, v); }
inline LONG InterlockedCompareExchange(volatile LONG* p, LONG xchg, LONG compar)
{
    return __sync_val_compare_and_swap(p, compar, xchg);
}
inline void* InterlockedExchangePointer(void* volatile* p, void* v) { return __sync_lock_test_and_set(p, v); }
inline void* InterlockedCompareExchangePointer(void* volatile* p, void* xchg, void* compar)
{
    return __sync_val_compare_and_swap(p, compar, xchg);
}

// ---------------------------------------------------------------------------
// Memory helpers
// ---------------------------------------------------------------------------
#ifndef MoveMemory
#define MoveMemory(dst, src, n) memmove((dst), (src), (n))
#endif
#ifndef FillMemory
#define FillMemory(dst, n, v) memset((dst), (v), (n))
#endif
#ifndef RtlZeroMemory
#define RtlZeroMemory(dst, n) memset((dst), 0, (n))
#endif
inline void* SecureZeroMemoryCompat(void* p, size_t n)
{
    memset(p, 0, n);
    __asm__ __volatile__("" ::"r"(p) : "memory");
    return p;
}
#define SecureZeroMemory SecureZeroMemoryCompat
#ifndef IsBadReadPtr
#define IsBadReadPtr(p, s) (false)
#endif
#ifndef IsBadWritePtr
#define IsBadWritePtr(p, s) (false)
#endif

inline void* AlignedMallocCompat(size_t size, size_t align)
{
    void* p = nullptr;
    size_t aligned = (size + align - 1) & ~(align - 1);
    if (align < sizeof(void*))
        align = sizeof(void*);
    if (posix_memalign(&p, align, aligned) != 0)
        return nullptr;
    return p;
}
#ifndef _aligned_malloc
#define _aligned_malloc AlignedMallocCompat
#endif
#ifndef _aligned_free
#define _aligned_free free
#endif
inline size_t _aligned_msize_compat(void* p, size_t align, unsigned flags)
{
	(void)align;
	(void)flags;
	return malloc_size(p);
}
#ifndef _aligned_msize
#define _aligned_msize _aligned_msize_compat
#endif
inline void* _aligned_realloc_compat(void* p, size_t size, size_t align)
{
	if (!p)
		return _aligned_malloc(size, align);
	void* np = _aligned_malloc(size, align);
	if (!np)
		return nullptr;
	size_t old = malloc_size(p);
	memcpy(np, p, old < size ? old : size);
	_aligned_free(p);
	return np;
}
#ifndef _aligned_realloc
#define _aligned_realloc _aligned_realloc_compat
#endif
#ifndef _msize
#define _msize malloc_size
#endif
#ifndef _expand
#define _expand(p, s) realloc((p), (s))
#endif

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------
inline void QueryPerformanceFrequency(LARGE_INTEGER* f) { *f = 1000000000LL; }
inline void QueryPerformanceCounter(LARGE_INTEGER* c)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    *c = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

inline unsigned long GetTickCount()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
#ifndef timeGetTime
#define timeGetTime GetTickCount
#endif

struct xr_timeb
{
    unsigned long time;
    unsigned short millitm;
    short timezone;
    short dstflag;
};
#ifndef _timeb
#define _timeb xr_timeb
#endif
inline void _ftime(struct xr_timeb* t)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    t->time = (unsigned long)tv.tv_sec;
    t->millitm = (unsigned short)(tv.tv_usec / 1000);
    t->timezone = 0;
    t->dstflag = 0;
}
inline void _ftime64(struct xr_timeb* t) { _ftime(t); }

inline void FillSystemTime(SYSTEMTIME* st, bool local)
{
    time_t t = time(NULL);
    struct tm tmv;
    if (local)
        localtime_r(&t, &tmv);
    else
        gmtime_r(&t, &tmv);
    st->wYear = (WORD)(tmv.tm_year + 1900);
    st->wMonth = (WORD)(tmv.tm_mon + 1);
    st->wDay = (WORD)tmv.tm_mday;
    st->wDayOfWeek = (WORD)tmv.tm_wday;
    st->wHour = (WORD)tmv.tm_hour;
    st->wMinute = (WORD)tmv.tm_min;
    st->wSecond = (WORD)tmv.tm_sec;
    st->wMilliseconds = 0;
}
inline void GetSystemTime(SYSTEMTIME* st) { FillSystemTime(st, false); }
inline void GetLocalTime(SYSTEMTIME* st) { FillSystemTime(st, true); }

// ---------------------------------------------------------------------------
// Process / thread priorities
// ---------------------------------------------------------------------------
#ifndef GetCurrentProcess
inline HANDLE GetCurrentProcessShim() { return (HANDLE)(intptr_t)getpid(); }
#define GetCurrentProcess GetCurrentProcessShim
#endif

#define THREAD_PRIORITY_LOWEST -2
#define THREAD_PRIORITY_BELOW_NORMAL -1
#define THREAD_PRIORITY_NORMAL 0
#define THREAD_PRIORITY_ABOVE_NORMAL 1
#define THREAD_PRIORITY_HIGHEST 2
#define THREAD_PRIORITY_TIME_CRITICAL 3
#define CREATE_SUSPENDED 0x00000004

// ---------------------------------------------------------------------------
// Last error (GetLastError is provided by PlatformApple.inl via errno)
// ---------------------------------------------------------------------------
extern thread_local int xr_win_last_error;
inline void SetLastError(unsigned long e) { xr_win_last_error = (int)e; }

// ---------------------------------------------------------------------------
// File mapping API (CreateFile / CreateFileMapping / MapViewOfFile)
// ---------------------------------------------------------------------------
#define GENERIC_READ 0x80000000UL
#define GENERIC_WRITE 0x40000000UL
#define FILE_SHARE_READ 0x00000001UL
#define FILE_SHARE_WRITE 0x00000002UL
#define OPEN_EXISTING 3
#define OPEN_ALWAYS 4
#define CREATE_ALWAYS 2
#define CREATE_NEW 1
#define FILE_ATTRIBUTE_READONLY 0x00000001UL
#define FILE_ATTRIBUTE_DIRECTORY 0x00000010UL
#define FILE_ATTRIBUTE_NORMAL 0x00000080UL
#define PAGE_READONLY 0x02
#define PAGE_READWRITE 0x04
#define PAGE_WRITECOPY 0x08
#define SEC_COMMIT 0x8000000
#define FILE_MAP_READ PROT_READ
#define FILE_MAP_WRITE PROT_WRITE
#define FILE_MAP_ALL_ACCESS (PROT_READ | PROT_WRITE)

struct xr_win_file
{
    uint32_t magic; // 'XRf1'
    int fd;
    bool closed;
};
struct xr_win_map
{
    uint32_t magic; // 'XRm1'
    int fd; // borrowed (owned by the file handle)
    int prot;
    bool closed;
};

HANDLE xr_CreateFileA(LPCSTR name, unsigned long access, unsigned long share, void*,
                      unsigned long disposition, unsigned long flags, HANDLE attrs);
#ifndef CreateFileA
#define CreateFileA xr_CreateFileA
#endif
#ifndef CreateFile
#define CreateFile xr_CreateFileA
#endif
unsigned long xr_GetFileSize(HANDLE h, unsigned long* high);
#ifndef GetFileSize
#define GetFileSize xr_GetFileSize
#endif
HANDLE xr_CreateFileMappingA(HANDLE file, void*, unsigned long prot, unsigned long maxhi,
                             unsigned long maxlo, LPCSTR name);
#ifndef CreateFileMappingA
#define CreateFileMappingA xr_CreateFileMappingA
#endif
#ifndef CreateFileMapping
#define CreateFileMapping xr_CreateFileMappingA
#endif
LPVOID xr_MapViewOfFile(HANDLE map, unsigned long access, unsigned long offhi,
                        unsigned long offlo, size_t size);
#ifndef MapViewOfFile
#define MapViewOfFile xr_MapViewOfFile
#endif
BOOL xr_UnmapViewOfFile(LPCVOID addr);
#ifndef UnmapViewOfFile
#define UnmapViewOfFile xr_UnmapViewOfFile
#endif
BOOL xr_CloseHandle(HANDLE h);
#ifndef CloseHandle
#define CloseHandle xr_CloseHandle
#endif
BOOL FlushViewOfFile(LPCVOID addr, size_t len);

// ---------------------------------------------------------------------------
// Path separator conversion: the engine carries Windows-style paths with
// backslashes internally; every OS boundary call converts to POSIX slashes.
// ---------------------------------------------------------------------------
#define XR_WIN_PATH_BUF 4096
inline void xr_win_conv_path(char* dst, const char* src)
{
    size_t i = 0;
    for (; src[i] != '\0' && i + 1 < XR_WIN_PATH_BUF; ++i)
        dst[i] = (src[i] == '\\') ? '/' : src[i];
    dst[i] = '\0';
}

// ---------------------------------------------------------------------------
// Handle-based file I/O (ReadFile / SetFilePointer on CreateFile handles)
// ---------------------------------------------------------------------------
#define FILE_BEGIN 0
#define FILE_CURRENT 1
#define FILE_END 2
#define INVALID_SET_FILE_POINTER ((DWORD)-1)
#define FILE_FLAG_NO_BUFFERING 0x20000000UL
#define FILE_FLAG_SEQUENTIAL_SCAN 0x08000000UL
#define FILE_FLAG_RANDOM_ACCESS 0x10000000UL

inline BOOL ReadFileCompat(HANDLE h, void* buf, uint32_t to_read, uint32_t* read_now, void*)
{
    if (!h || h == INVALID_HANDLE_VALUE)
        return FALSE;
    xr_win_file* f = (xr_win_file*)h;
    ssize_t got = ::read(f->fd, buf, to_read);
    if (read_now)
        *read_now = got < 0 ? 0 : (uint32_t)got;
    if (got < 0)
    {
        xr_win_last_error = errno;
        return FALSE;
    }
    return TRUE;
}
#ifndef ReadFile
#define ReadFile ReadFileCompat
#endif

inline BOOL WriteFileCompat(HANDLE h, const void* buf, uint32_t to_write, uint32_t* written, void*)
{
    if (!h || h == INVALID_HANDLE_VALUE)
        return FALSE;
    xr_win_file* f = (xr_win_file*)h;
    ssize_t put = ::write(f->fd, buf, to_write);
    if (written)
        *written = put < 0 ? 0 : (uint32_t)put;
    if (put < 0)
    {
        xr_win_last_error = errno;
        return FALSE;
    }
    return TRUE;
}
#ifndef WriteFile
#define WriteFile WriteFileCompat
#endif

inline unsigned long SetFilePointerCompat(HANDLE h, long dist, void* hi, unsigned long origin)
{
    if (!h || h == INVALID_HANDLE_VALUE)
        return INVALID_SET_FILE_POINTER;
    xr_win_file* f = (xr_win_file*)h;
    int whence = SEEK_SET;
    if (origin == FILE_CURRENT)
        whence = SEEK_CUR;
    else if (origin == FILE_END)
        whence = SEEK_END;
    off_t pos = ::lseek(f->fd, (off_t)dist, whence);
    if (pos == (off_t)-1)
    {
        xr_win_last_error = errno;
        return INVALID_SET_FILE_POINTER;
    }
    if (hi)
        *(unsigned long*)hi = (unsigned long)((uint64_t)pos >> 32);
    return (unsigned long)(pos & 0xFFFFFFFFULL);
}
#ifndef SetFilePointer
#define SetFilePointer SetFilePointerCompat
#endif

inline BOOL SetFilePointerExCompat(HANDLE h, int64_t dist, int64_t* out, unsigned long origin)
{
    if (!h || h == INVALID_HANDLE_VALUE)
        return FALSE;
    xr_win_file* f = (xr_win_file*)h;
    int whence = SEEK_SET;
    if (origin == FILE_CURRENT)
        whence = SEEK_CUR;
    else if (origin == FILE_END)
        whence = SEEK_END;
    off_t pos = ::lseek(f->fd, (off_t)dist, whence);
    if (pos == (off_t)-1)
        return FALSE;
    if (out)
        *out = pos;
    return TRUE;
}
#ifndef SetFilePointerEx
#define SetFilePointerEx SetFilePointerExCompat
#endif

// ---------------------------------------------------------------------------
// System info
// ---------------------------------------------------------------------------
struct SYSTEM_INFO
{
    unsigned long dwAllocationGranularity;
    unsigned long dwPageSize;
    unsigned long dwNumberOfProcessors;
};

inline void GetSystemInfo(SYSTEM_INFO* si)
{
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0)
        page = getpagesize();
    si->dwPageSize = (unsigned long)page;
    si->dwAllocationGranularity = (unsigned long)page;
    int ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
    si->dwNumberOfProcessors = (unsigned long)(ncpu > 0 ? ncpu : 1);
}
#define GetNativeSystemInfo GetSystemInfo

// ---------------------------------------------------------------------------
// File attributes
// ---------------------------------------------------------------------------
unsigned long xr_GetFileAttributesA(LPCSTR path);
#define GetFileAttributesA xr_GetFileAttributesA
#define GetFileAttributes xr_GetFileAttributesA
BOOL xr_SetFileAttributesA(LPCSTR path, unsigned long attr);
#define SetFileAttributesA xr_SetFileAttributesA
#define SetFileAttributes xr_SetFileAttributesA

// ---------------------------------------------------------------------------
// CRT shims
// ---------------------------------------------------------------------------
#ifndef _sys_errlist
#define _sys_errlist sys_errlist
#endif
#ifndef _tzset
#define _tzset tzset
#endif
#ifndef filelength
#define filelength _filelength
#endif
#ifndef _stat
#define _stat stat
#endif
#ifndef _stati64
#define _stati64 stat
#endif
#ifndef _strtoui64
#define _strtoui64 strtoull
#endif
#ifndef _atoi64
#define _atoi64 atoll
#endif
#ifndef _strlwr
#define _strlwr strlwr
#endif

inline char* _i64toa_s_compat(long long v, char* buf, size_t sz, int radix)
{
    if (radix == 10)
        snprintf(buf, sz, "%lld", v);
    else
        snprintf(buf, sz, "%lld", v); // legacy call sites only use radix 10
    return buf;
}
inline char* _ui64toa_s_compat(unsigned long long v, char* buf, size_t sz, int radix)
{
    if (radix == 10)
        snprintf(buf, sz, "%llu", v);
    else
        snprintf(buf, sz, "%llu", v);
    return buf;
}
#ifndef _i64toa_s
#define _i64toa_s(v, b, sz, r) _i64toa_s_compat((v), (b), (sz), (r))
#endif
#ifndef _ui64toa_s
#define _ui64toa_s(v, b, sz, r) _ui64toa_s_compat((v), (b), (sz), (r))
#endif

inline void _strdate_compat(char* buf)
{
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(buf, 9, "%m/%d/%y", &tmv);
}
inline void _strtime_compat(char* buf)
{
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(buf, 9, "%H:%M:%S", &tmv);
}
#ifndef _strdate
#define _strdate _strdate_compat
#endif
#ifndef _strtime
#define _strtime _strtime_compat
#endif

// ---------------------------------------------------------------------------
// Dynamic loading
// ---------------------------------------------------------------------------
#include <dlfcn.h>
#define LOAD_WITH_ALTERED_SEARCH_PATH 0x8
#ifndef GetModuleHandleA
#define GetModuleHandleA(name) (name ? dlopen(name, RTLD_LAZY | RTLD_NOLOAD) : dlopen(NULL, RTLD_LAZY))
#endif
#ifndef GetModuleHandle
#define GetModuleHandle GetModuleHandleA
#endif
#ifndef GetModuleHandleW
#define GetModuleHandleW GetModuleHandleA
#endif
#ifndef LoadLibraryA
#define LoadLibraryA(p) dlopen(p, RTLD_LAZY)
#endif
#ifndef LoadLibrary
#define LoadLibrary LoadLibraryA
#endif
#ifndef LoadLibraryExA
#define LoadLibraryExA(p, h, f) dlopen(p, RTLD_LAZY)
#endif
#ifndef FreeLibrary
#define FreeLibrary(h) dlclose(h)
#endif
#define DLL_PROCESS_ATTACH 1
#define DLL_THREAD_ATTACH 2
#define DLL_THREAD_DETACH 3
#define DLL_PROCESS_DETACH 0

// ---------------------------------------------------------------------------
// Sockets (BSD)
// ---------------------------------------------------------------------------
#ifndef closesocket
#define closesocket close
#endif
typedef int WSADATA;
inline int WSAStartup(unsigned short, WSADATA*) { return 0; }
inline int WSACleanup() { return 0; }
#ifndef WSAGetLastError
#define WSAGetLastError() errno
#endif
#define WSAENOTSOCK EBADF
#define SOCKET_ERROR (-1)
#ifndef SO_DONTLINGER
#define SO_DONTLINGER (int)(~SO_LINGER)
#endif

// ---------------------------------------------------------------------------
// Misc UI stubs
// ---------------------------------------------------------------------------
inline int MessageBoxCompat(void*, const char* text, const char* caption, unsigned int)
{
    if (caption)
        fprintf(stderr, "[MessageBox] %s: %s\n", caption, text ? text : "");
    else if (text)
        fprintf(stderr, "[MessageBox] %s\n", text);
    return 0;
}
#define MessageBoxA MessageBoxCompat
#define MessageBox MessageBoxCompat
#define MB_OK 0
#define MB_ICONERROR 0
#define MB_ICONWARNING 0
#define MB_SYSTEMMODAL 0
#define MB_DEFBUTTON1 0
#define MB_SETFOREGROUND 0
#define MB_CANCELTRYCONTINUE 0
#define IDOK 1
#define IDCANCEL 2
#define IDTRYAGAIN 10
#define IDCONTINUE 11
#ifndef IDOK
#endif

inline void ShowCursorCompat(BOOL) {}
#ifndef ShowCursor
#define ShowCursor ShowCursorCompat
#endif
inline void* GetActiveWindowCompat() { return nullptr; }
#ifndef GetActiveWindow
#define GetActiveWindow GetActiveWindowCompat
#endif
inline BOOL ShowWindowCompat(void*, int) { return TRUE; }
#ifndef ShowWindow
#define ShowWindow ShowWindowCompat
#endif
inline void* GetTopWindowCompat(void*) { return nullptr; }
#ifndef GetTopWindow
#define GetTopWindow GetTopWindowCompat
#endif
#ifndef SW_FORCEMINIMIZE
#define SW_FORCEMINIMIZE 11
#endif
inline void TerminateProcessCompat(void*, unsigned int code)
{
    fflush(nullptr);
    _exit((int)code);
}
#ifndef TerminateProcess
#define TerminateProcess TerminateProcessCompat
#endif
inline BOOL IsDebuggerPresentCompat() { return FALSE; }
#ifndef IsDebuggerPresent
#define IsDebuggerPresent IsDebuggerPresentCompat
#endif

// ---------------------------------------------------------------------------
// Command line (populated by the SDL entry point via xr_set_command_line)
// ---------------------------------------------------------------------------
void xr_set_command_line(int argc, char** argv);
LPCSTR xr_GetCommandLine();
#ifndef GetCommandLine
#define GetCommandLine xr_GetCommandLine
#endif

// ---------------------------------------------------------------------------
// Process environment
// ---------------------------------------------------------------------------
inline unsigned long GetUserNameCompat(char* buf, uint32_t* sz)
{
    const char* u = getlogin();
    if (!u || !*u)
        u = getenv("USER");
    if (!u)
        u = "player";
    snprintf(buf, *sz, "%s", u);
    *sz = (unsigned long)strlen(buf);
    return TRUE;
}
#ifndef GetUserName
#define GetUserName GetUserNameCompat
#endif

inline unsigned long GetComputerNameCompat(char* buf, uint32_t* sz)
{
    if (gethostname(buf, *sz) != 0)
        snprintf(buf, *sz, "localhost");
    *sz = (unsigned long)strlen(buf);
    return TRUE;
}
#ifndef GetComputerName
#define GetComputerName GetComputerNameCompat
#endif

inline unsigned long GetCurrentDirectoryCompat(uint32_t sz, char* buf)
{
    return getcwd(buf, sz) ? (unsigned long)strlen(buf) : 0;
}
#ifndef GetCurrentDirectory
#define GetCurrentDirectory GetCurrentDirectoryCompat
#endif

inline BOOL SetCurrentDirectoryCompat(LPCSTR p) { return chdir(p) == 0 ? TRUE : FALSE; }
#ifndef SetCurrentDirectory
#define SetCurrentDirectory SetCurrentDirectoryCompat
#endif

unsigned long xr_GetModuleFileNameCompat(void* module, char* buf, unsigned long sz);
#ifndef GetModuleFileName
#define GetModuleFileName xr_GetModuleFileNameCompat
#endif

#endif // XR_PLATFORM_POSIX
