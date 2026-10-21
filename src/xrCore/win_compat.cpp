// win_compat.cpp — POSIX implementations of the Win32 file-mapping surface.

#include "stdafx.h"

#ifndef XR_PLATFORM_WINDOWS

#include <mutex>
#include <unordered_map>
#include <mach-o/dyld.h>

thread_local int xr_win_last_error = 0;

// ---------------------------------------------------------------------------
// Command line capture
// ---------------------------------------------------------------------------
static char g_command_line_storage[8192] = { 0 };

void xr_set_command_line(int argc, char** argv)
{
    g_command_line_storage[0] = 0;
    size_t off = 0;
    for (int i = 0; i < argc && off + 1 < sizeof(g_command_line_storage); ++i)
    {
        int n = snprintf(g_command_line_storage + off, sizeof(g_command_line_storage) - off,
                         i ? " %s" : "%s", argv[i]);
        if (n < 0)
            break;
        off += (size_t)n;
    }
}

char* xr_GetCommandLine()
{
    return g_command_line_storage;
}

unsigned long xr_GetModuleFileNameCompat(void* /*module*/, char* buf, unsigned long sz)
{
    uint32_t len = sz > 0 ? sz - 1 : 0;
    if (_NSGetExecutablePath(buf, &len) != 0)
    {
        snprintf(buf, sz, ".");
        return 0;
    }
    buf[len < sz ? len : sz - 1] = 0;
    return (unsigned long)strlen(buf);
}

HANDLE xr_CreateFileA(LPCSTR name, unsigned long access, unsigned long share, void*,
                      unsigned long disposition, unsigned long flags, HANDLE attrs)
{
    char conv[XR_WIN_PATH_BUF];
    xr_win_conv_path(conv, name);
    name = conv;
    int flags_posix = 0;
    switch (disposition)
    {
    case OPEN_EXISTING: flags_posix = O_RDWR; break;
    case OPEN_ALWAYS: flags_posix = O_RDWR | O_CREAT; break;
    case CREATE_ALWAYS: flags_posix = O_RDWR | O_CREAT | O_TRUNC; break;
    case CREATE_NEW: flags_posix = O_RDWR | O_CREAT | O_EXCL; break;
    default: flags_posix = O_RDWR; break;
    }
    if ((access & GENERIC_WRITE) == 0)
        flags_posix = (flags_posix & ~O_RDWR) | O_RDONLY;
    if ((access & GENERIC_WRITE) && (access & GENERIC_READ))
        flags_posix |= O_RDWR;

    int fd = ::open(name, flags_posix, 0644);
    if (fd < 0)
    {
        xr_win_last_error = errno;
        return INVALID_HANDLE_VALUE;
    }
    xr_win_file* f = new xr_win_file{ 0x58526631, fd, false };
    return (HANDLE)f;
}

unsigned long xr_GetFileSize(HANDLE h, unsigned long* high)
{
    if (h == INVALID_HANDLE_VALUE)
        return 0xFFFFFFFFUL;
    xr_win_file* f = (xr_win_file*)h;
    struct stat st;
    if (fstat(f->fd, &st) != 0)
    {
        xr_win_last_error = errno;
        return 0xFFFFFFFFUL;
    }
    if (high)
        *high = (unsigned long)((uint64_t)st.st_size >> 32);
    return (unsigned long)(st.st_size & 0xFFFFFFFFULL);
}

HANDLE xr_CreateFileMappingA(HANDLE file, void*, unsigned long prot, unsigned long maxhi,
                             unsigned long maxlo, LPCSTR name)
{
    if (file == INVALID_HANDLE_VALUE)
        return INVALID_HANDLE_VALUE;
    xr_win_file* f = (xr_win_file*)file;
    int p = PROT_READ;
    if (prot & (PAGE_READWRITE | PAGE_WRITECOPY))
        p |= PROT_WRITE;
    xr_win_map* m = new xr_win_map{ 0x58526d31, f->fd, p, false };
    return (HANDLE)m;
}

namespace
{
std::mutex g_mapping_lock;
std::unordered_map<const void*, size_t> g_mappings;
}

LPVOID xr_MapViewOfFile(HANDLE map, unsigned long access, unsigned long offhi,
                        unsigned long offlo, size_t size)
{
    if (!map || map == INVALID_HANDLE_VALUE)
        return nullptr;
    xr_win_map* m = (xr_win_map*)map;

    struct stat st;
    if (fstat(m->fd, &st) != 0)
    {
        xr_win_last_error = errno;
        return nullptr;
    }
    size_t len = size ? size : (size_t)st.st_size;
    if (len == 0)
    {
        // mmap rejects zero-length mappings
        return nullptr;
    }

    int prot = m->prot;
    if (access == FILE_MAP_READ)
        prot = PROT_READ;
    if ((access & PROT_WRITE) && !(m->prot & PROT_WRITE))
        prot &= ~PROT_WRITE;

    // offhi:offlo must be a multiple of the host page size (the engine aligns
    // with dwAllocationGranularity, which we report as the page size).
    off_t off = ((off_t)offhi << 32) | (off_t)offlo;
    void* addr = mmap(nullptr, len, prot, MAP_SHARED, m->fd, off);
    if (addr == MAP_FAILED)
    {
        xr_win_last_error = errno;
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> guard(g_mapping_lock);
        g_mappings[addr] = len;
    }
    return (LPVOID)addr;
}

BOOL xr_UnmapViewOfFile(LPCVOID addr)
{
    if (!addr)
        return FALSE;
    size_t len = 0;
    {
        std::lock_guard<std::mutex> guard(g_mapping_lock);
        auto it = g_mappings.find(addr);
        if (it != g_mappings.end())
        {
            len = it->second;
            g_mappings.erase(it);
        }
    }
    if (len == 0)
        return FALSE;
    return munmap(const_cast<void*>(addr), len) == 0 ? TRUE : FALSE;
}

BOOL FlushViewOfFile(LPCVOID addr, size_t len)
{
    if (!addr)
        return FALSE;
    if (len == 0)
    {
        std::lock_guard<std::mutex> guard(g_mapping_lock);
        auto it = g_mappings.find(addr);
        if (it == g_mappings.end())
            return FALSE;
        len = it->second;
    }
    return msync(const_cast<void*>(addr), len, MS_SYNC) == 0 ? TRUE : FALSE;
}

BOOL xr_CloseHandle(HANDLE h)
{
    if (h == INVALID_HANDLE_VALUE || !h)
        return FALSE;
    uint32_t magic = *(uint32_t*)h;
    if (magic == 0x58526631) // 'XRf1' file handle owns the fd
    {
        xr_win_file* f = (xr_win_file*)h;
        if (!f->closed)
        {
            ::close(f->fd);
            f->closed = true;
        }
        delete f;
    }
    else if (magic == 0x58526d31) // 'XRm1' map handle borrows the fd
    {
        xr_win_map* m = (xr_win_map*)h;
        m->closed = true;
        delete m;
    }
    else if (magic == 0x58527431) // 'XRt1' thread handle
    {
        xr_win_thread* t = (xr_win_thread*)h;
        if (!t->joined)
        {
            pthread_join(t->thr, nullptr);
            t->joined = true;
        }
        delete t;
    }
    return TRUE;
}

unsigned long xr_GetFileAttributesA(LPCSTR path)
{
    char conv[XR_WIN_PATH_BUF];
    xr_win_conv_path(conv, path);
    struct stat st;
    if (stat(conv, &st) != 0)
    {
        xr_win_last_error = errno;
        return 0xFFFFFFFFUL; // INVALID_FILE_ATTRIBUTES
    }
    unsigned long attr = FILE_ATTRIBUTE_NORMAL;
    if (S_ISDIR(st.st_mode))
        attr = FILE_ATTRIBUTE_DIRECTORY;
    else if ((st.st_mode & S_IWUSR) == 0)
        attr = FILE_ATTRIBUTE_READONLY;
    return attr;
}

BOOL xr_SetFileAttributesA(LPCSTR path, unsigned long attr)
{
    // FS hands us Windows-style virtual paths ("dir\\file"); POSIX syscalls
    // need forward slashes or stat/chmod silently fail (cfg_save regression).
    char fixed[MAX_PATH];
    strncpy(fixed, path, sizeof(fixed) - 1);
    fixed[sizeof(fixed) - 1] = 0;
    for (char* p = fixed; *p; ++p)
        if (*p == '\\')
            *p = '/';
    struct stat st;
    if (stat(fixed, &st) != 0)
        return FALSE;
    mode_t mode = st.st_mode;
    if (attr & FILE_ATTRIBUTE_READONLY)
        mode &= ~(S_IWUSR | S_IWGRP | S_IWOTH);
    else
        mode |= S_IWUSR;
    return chmod(fixed, mode) == 0 ? TRUE : FALSE;
}

#endif // !XR_PLATFORM_WINDOWS
