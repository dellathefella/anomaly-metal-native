#include <stdio.h>
#include <cstring>
#include <stdlib.h> // for malloc
#include <unistd.h> // for rmdir
#include <sys/fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/param.h>
#include <sys/syslimits.h> // for PATH_MAX
#include <errno.h>
#include <stdarg.h>
#include <ctype.h>
#include <limits.h> // for PAGESIZE...
#include <math.h>
#include <sched.h>

#include <algorithm> // for min max
#include <stddef.h>

#include <string>
#include <pthread.h>
#include <fcntl.h>
#include <sys/mman.h> // for mmap / munmap
#include <dirent.h>
#include <utime.h>
#include <ctime>

#include <xlocale.h> // for locale_t

#define _LINUX // for GameSpy

#define MAX_PATH PATH_MAX + 1

#define WINAPI

#define _copysign copysign

#define _cdecl //__attribute__((cdecl))

#define __cdecl _cdecl
#define __stdcall
#define __fastcall

#define __pragma(...) _Pragma(#__VA_ARGS__)
#define CALLBACK

#define __except(X) catch(X)

#define GetCurrentProcessId getpid

inline void Sleep(int ms)
{
    usleep(ms * 1000);
}

inline void _splitpath(const char* path, // Path Input
        char* drive, // Drive     : Output
        char* dir, // Directory : Output
        char* fname, // Filename  : Output
        char* ext // Extension : Output
        )
{
    if(!path)
        return;

    const char *p, *end;

    if(drive)
        strcpy(drive, "");

    end = NULL;
    for(p = path; *p; p++)
        if(*p == '/' || *p == '\\')
            end = p + 1;

    if(end)
    {
        if(dir)
        {
            memcpy(dir, path, end - path);
            dir[end - path] = 0;
        }
        path = end;
    }
    else if(dir)
        dir[0] = 0;

    end = strchr(path, '.');

    if(!end)
        end = p;

    if(fname)
    {
        memcpy(fname, path, end - path);
        fname[end - path] = 0;
    }

    if(ext)
        strcpy(ext, end);
}

#include <iostream>
inline void OutputDebugString(const char *str) // for linux debugger
{
    std::cerr << str;
}

inline unsigned long GetLastError()
{
    return 0;
}

inline int GetExceptionCode()
{
    return 0;
}

inline void convert_path_separators(char * path);

#include <inttypes.h>
typedef int32_t BOOL;
typedef uint16_t WORD;
typedef uint32_t DWORD;
typedef int32_t LONG;
#ifndef _LIBRAW_TYPES_H
typedef int64_t INT64;
typedef uint64_t UINT64;
#endif

typedef char* LPSTR;
typedef char* PSTR;
typedef char* LPTSTR;
typedef const char* LPCSTR;
typedef const char* LPCTSTR;
typedef unsigned int UINT;
// Win32 64-bit time/integers — union form so .QuadPart/.LowPart work
// (anonymous members rely on -fms-extensions, as everywhere in this port).
typedef union _LARGE_INTEGER
{
    struct
    {
        unsigned long LowPart;
        long HighPart;
    };
    long long QuadPart;
} LARGE_INTEGER;
typedef union _ULARGE_INTEGER
{
    struct
    {
        unsigned long LowPart;
        unsigned long HighPart;
    };
    unsigned long long QuadPart;
} ULARGE_INTEGER;

typedef struct _EXCEPTION_POINTERS {
} EXCEPTION_POINTERS, *PEXCEPTION_POINTERS;

#if defined(XR_ARCHITECTURE_X64) || defined(XR_ARCHITECTURE_ARM64) || defined(XR_ARCHITECTURE_E2K)
typedef int64_t INT_PTR;
typedef uint64_t UINT_PTR;
typedef int64_t LONG_PTR;
#else
typedef int INT_PTR;
typedef unsigned int UINT_PTR;
typedef long LONG_PTR;
#endif

typedef void* HANDLE;
typedef void* HMODULE;
typedef void* PVOID;
typedef void* LPVOID;
#if defined(XR_ARCHITECTURE_PPC64)
typedef LONG_PTR WPARAM;
#else
typedef UINT_PTR WPARAM;
#endif
typedef LONG_PTR LPARAM;
typedef long HRESULT;
typedef long LRESULT;
typedef void* HWND;
typedef void* HDC;

typedef struct _RECT {
    long left;
    long top;
    long right;
    long bottom;
} RECT, *PRECT;

typedef struct tagPOINT {
    long x;
    long y;
} POINT, *PPOINT, *LPPOINT;

#define WM_USER 0x0400

#define TRUE true
#define FALSE false
// NONE deliberately NOT defined here: it collides with enum members
// (game_sv_artefacthunt.h ARTEFACT_STATE::NONE) and nothing in the POSIX
// shim layer uses it.
#define CONST const

typedef dirent DirEntryType;

#define _O_WRONLY O_WRONLY
#define _O_RDONLY O_RDONLY
#define _O_TRUNC O_TRUNC
#define _O_CREAT O_CREAT
#define _S_IWRITE S_IWRITE
#define _S_IREAD S_IREAD
#define _O_BINARY 0
#define O_BINARY 0
#define O_SEQUENTIAL 0
#define SH_DENYWR 0

#if __has_include(<SDL_stdinc.h>)
#include <SDL_stdinc.h>
#define itoa SDL_itoa
#define _itoa_s SDL_itoa
#else
#define itoa(...) do { static_assert(false, "SDL_stdinc.h is missing"); } while (false)
#define _itoa_s(...) do { static_assert(false, "SDL_stdinc.h is missing"); } while (false)
#endif

#define _stricmp stricmp
#define strcmpi stricmp
#define lstrcpy strcpy
#define stricmp strcasecmp
#define strupr SDL_strupr
// error code numbers from original MS strcpy_s return value
inline int strcpy_s(char *dest, size_t num, const char *source)
{
    if(!dest)
        return EINVAL;

    if(0 == num)
    {
        dest[0] = '\0';
        return ERANGE;
    }

    if(!source)
    {
        dest[0] = '\0';
        return EINVAL;
    }

    size_t i;
    for(i = 0; i < num; i++)
    {
        if((dest[i] = source[i]) == '\0')
            return 0;
    }
    dest[0] = '\0';
    return ERANGE;
}

template <size_t num>
inline int strcpy_s(char (&dest)[num], const char *source) { return strcpy_s(dest, num, source); }

#ifndef _TRUNCATE
#define _TRUNCATE ((size_t)-1)
#endif
inline int strncpy_s(char * dest, size_t dst_size, const char * source, size_t num)
{
    if (!dest || (0 == dst_size))
        return EINVAL;

    if(0 == num)
    {
        dest[0] = '\0';
        return 0;
    }

    if (!source)
    {
        dest[0] = '\0';
        return EINVAL;
    }

    size_t i, end;
    if(num < dst_size)
        end = num;
    else
        end = dst_size - 1;

    for(i = 0; i < end && source[i]; i++)
        dest[i] = source[i];

    if(!source[i] || end == num)
    {
        dest[i] = '\0';
        return 0;
    }

    dest[0] = '\0';

    return EINVAL;
}

template <size_t dst_sz>
inline int strncpy_s(char (&dest)[dst_sz], const char * source, size_t num) { return strncpy_s(dest, dst_sz, source, num); }

inline int strcat_s(char * dest, size_t num, const char * source)
{
    if(!dest)
        return EINVAL;

    if(!source)
    {
        dest[0] = '\0';
        return EINVAL;
    }

    size_t i, j;
    for(i = 0; i < num; i++)
    {
        if(dest[i] == '\0')
        {
            for(j = 0; (j + i) < num; j++)
            {
                if((dest[j + i] = source[j]) == '\0')
                    return 0;
            }
        }
    }

    dest[0] = '\0';
    return ERANGE;
}

inline int strncat_s(char * dest, size_t num, const char * source, size_t count)
{
    if (!dest || !source)
        return EINVAL;

    size_t i, j;
    for(i = 0; i < num; i++)
    {
        if(dest[i] == '\0')
        {
            for(j = 0; (j + i) < num; j++)
            {
                if(j == count || (dest[j + i] = source[j]) == '\0')
                {
                    dest[j + i] = '\0';
                    return 0;
                }
            }
        }
    }

    return ERANGE;
}

#define _vsnprintf vsnprintf
inline int vsnprintf_s(char* buffer, size_t size, size_t, const char* format, va_list list)
{
    //TODO add bound check
    return vsnprintf(buffer, size, format, list);
}
// MSVC secure vsprintf_s has a 4-arg form and a 3-arg form (size inferred from
// the buffer template); overloads cover both call shapes.
inline int xr_vsprintf_s_impl(char* dest, size_t, const char* format, va_list args)
{
    return vsprintf(dest, format, args);
}
inline int xr_vsprintf_s_impl(char* dest, const char* format, va_list args)
{
    return vsprintf(dest, format, args);
}
#define vsprintf_s xr_vsprintf_s_impl
#define _snprintf snprintf
// sprintf_s: 4-arg form (dest, size, fmt, ...) and the template form with
// inferred array size (dest, fmt, ...) — both map onto vsnprintf.
inline int xr_sprintf_s_impl(char* dest, size_t size, const char* format, ...)
{
    va_list args;
    va_start(args, format);
    int r = vsnprintf(dest, size, format, args);
    va_end(args);
    return r;
}
template <size_t N>
inline int xr_sprintf_s_impl(char (&dest)[N], const char* format, ...)
{
    va_list args;
    va_start(args, format);
    int r = vsnprintf(dest, N, format, args);
    va_end(args);
    return r;
}
#define sprintf_s xr_sprintf_s_impl
#define sscanf_s sscanf
//#define GetProcAddress(handle, name) dlsym(handle, name)
#define _chdir chdir
#define _strnicmp strnicmp
#define strnicmp strncasecmp
#define _getcwd getcwd
#define _snwprintf swprintf
#define swprintf_s swprintf
#define wcsicmp _wcsicmp
#define _wcsicmp wcscmp
#define _tempnam tempnam
inline int xr_open_conv(const char* path, int flags, mode_t mode = 0644)
{
    char conv[4096];
    size_t i = 0;
    for (; path[i] && i + 1 < sizeof(conv); ++i)
        conv[i] = (path[i] == '\\') ? '/' : path[i];
    conv[i] = 0;
    return open(conv, flags, mode);
}
inline int xr_access_conv(const char* path, int mode)
{
    char conv[4096];
    size_t i = 0;
    for (; path[i] && i + 1 < sizeof(conv); ++i)
        conv[i] = (path[i] == '\\') ? '/' : path[i];
    conv[i] = 0;
    return access(conv, mode);
}
// Engine paths carry Windows separators; convert before handing them to libc.
inline FILE* xr_fopen_conv(const char* path, const char* mode)
{
    char conv[4096];
    size_t i = 0;
    for (; path[i] && i + 1 < sizeof(conv); ++i)
        conv[i] = (path[i] == '\\') ? '/' : path[i];
    conv[i] = 0;
    return fopen(conv, mode);
}
#define _access xr_access_conv
#define _open xr_open_conv
#define _close close
// _sopen(path, oflag, shflag [, pmode]): the share flag is meaningless on
// POSIX; the upstream `#define _sopen open` passed it as the file mode.
inline int xr_sopen_conv(const char* path, int flags, int /*shflag*/, int mode = 0644)
{
    char conv[4096];
    size_t i = 0;
    for (; path[i] && i + 1 < sizeof(conv); ++i)
        conv[i] = (path[i] == '\\') ? '/' : path[i];
    conv[i] = 0;
    return open(conv, flags, mode);
}
#define _sopen xr_sopen_conv
#define _utime utime
#define _utimbuf utimbuf
// MSVC semantics: errno_t result (0 == success) and the fd stored in *handle.
// The upstream OpenXRay macro dropped the fd and returned the fd as the error
// code, which inverted the success check and left *handle uninitialized.
#define _sopen_s(handle, filename, ...) \
	((*(handle) = xr_open_conv((filename), O_RDONLY)) < 0 ? errno : 0)
inline int _filelength(int fd)
{
    struct stat file_info;
    ::fstat(fd, &file_info);
    return file_info.st_size;
}
#define _fdopen fdopen
inline int _rmdir(const char *path)
{
    char* conv_fn = strdup(path);
    convert_path_separators(conv_fn);
    int result = rmdir(conv_fn);
    free(conv_fn);
    return result;
}
#define _write write
#define _strupr strupr
#define _read xr_read
#define _set_new_handler std::set_new_handler
#define _finite isfinite
inline int _mkdir(const char *dir)
{
    char conv[4096];
    size_t i = 0;
    for (; dir[i] && i + 1 < sizeof(conv); ++i)
        conv[i] = (dir[i] == '\\') ? '/' : dir[i];
    conv[i] = 0;
    return mkdir(conv, S_IRWXU);
}

#define _wtoi(arg) wcstol(arg, NULL, 10)
#define _wtoi64(arg) wcstoll(arg, NULL, 10)
#undef min
#undef max
#define __max(a, b) std::max(a, b)
#define __min(a, b) std::min(a, b)

#define _locale_t locale_t
#define _isalpha_l isalpha_l
#define _create_locale(category, arg) newlocale(category, arg, (locale_t) 0)

#define ZeroMemory(p, sz) memset((p), 0, (sz))
#define CopyMemory(d, s, n) memcpy(d, s, n)

#define RGB(r,g,b) ( ((DWORD)(uint8_t)r)|((DWORD)((uint8_t)g)<<8)|((DWORD)((uint8_t)b)<<16) )
#define SUCCEEDED(hr) (((HRESULT)(hr)) >= 0)
#define FAILED(hr) (((HRESULT)(hr)) < 0)
#define S_OK 0x00000000
#define S_FALSE 0x10000000
#define E_FAIL 0x80004005

#define _MAX_DRIVE	3
#define _MAX_DIR	256
#define _MAX_FNAME	256
#define _MAX_EXT	256

typedef DWORD           FOURCC;

typedef struct _AVIINDEXENTRY {
    DWORD	ckid;
    DWORD	dwFlags;
    DWORD	dwChunkOffset;
    DWORD	dwChunkLength;
} AVIINDEXENTRY;

typedef void *HIC;

inline BOOL SwitchToThread() { return (0 == sched_yield()); }

template <typename T>
decltype(auto) do_nothing(const T& obj)
{
    return obj;
}

// p4: Windows-parity case-insensitive virtual FS. Anomaly configs carry
// mixed-case includes (e.g. mp\SoundMessages\...) that must match the
// lowercase archive listings. macOS default volumes are case-insensitive
// APFS, so the lowercased paths still open on disk. (xr_strlwr has
// char*/xr_string/shared_str overloads; every xr_fs_strlwr call site passes
// a mutable buffer.)
#define xr_fs_strlwr(str) xr_strlwr(str)
#define xr_fs_nostrlwr(str) xr_strlwr(str)

/// For backward compability of FS, for real filesystem delimiter set to back
inline void restore_path_separators(char * path)
{
    while (char* sep = strchr(path, '/')) *sep = '\\'; //
}

inline void convert_path_separators(char * path)
{
    while (char* sep = strchr(path, '\\')) *sep = '/';
}

inline int xr_unlink(const char *path)
{
    char* conv_fn = strdup(path);
    convert_path_separators(conv_fn);
    int result = unlink(conv_fn);
    free(conv_fn);
    return result;
}

inline tm* localtime_safe(const time_t *time, struct tm* result){ return localtime_r(time, result); }

#define xr_strerror(errno, buffer, bufferSize) strerror_r(errno, buffer, sizeof(buffer))

using xrpid_t = pid_t;

// This is a drop-in replacement for calls to linux 'read' function. We use this because unlike other OSes
// Linux 'read' function can return less then the requested number of bytes and might need to be called multiple times.
// Apart from this, it behaves exactly as you would expect and matches the other OSes implementation.
// See also: https://www.man7.org/linux/man-pages/man2/read.2.html
inline ssize_t xr_read(int file_handle, void *buffer, size_t count)
{
    ssize_t total_r_bytes = 0;
    do
    {
        const ssize_t r_bytes =
            read(file_handle, reinterpret_cast<unsigned char*>(buffer) + total_r_bytes, count - total_r_bytes);

        // Check for error
        if (r_bytes == -1)
            return -1;

        // Check for EOF otherwise we would loop indefinitely
        if (r_bytes == 0)
            return total_r_bytes;

        total_r_bytes += r_bytes;
    } while (static_cast<size_t>(total_r_bytes) < count);

    return total_r_bytes;
}
