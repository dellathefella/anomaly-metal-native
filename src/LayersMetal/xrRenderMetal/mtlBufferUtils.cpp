// mtlBufferUtils.cpp — buffer classes + decl helpers on the Metal substrate
// (mirror of glBufferUtils.cpp). Handles are borrowed id<MTLBuffer> void*s
// owned by the device arena; Metal shared-storage buffers are CPU-mapped for
// their lifetime, so Map() returns contents+offset and Unmap() is a no-op —
// EXCEPT on dynamic stream buffers, which emulate DX9 dynamic-orphan
// semantics by rotating backing storage on flush (see below).
#include "stdafx.h"
#include "Layers/xrRender/BufferUtils.h"

#include <FlexibleVertexFormat.h>

#include <unordered_map>
#include <vector>

#include "mtlHW.h" // CHW::MtlDev facade

// launch302: DX9 dynamic-stream orphaning.
//
// _VertexStream/_IndexStream are single D3DUSAGE_DYNAMIC buffers that the
// engine wraps (mPosition=0) on flush and rewrites while earlier frames are
// still in flight. A DX9 driver silently orphans such a buffer on
// Lock(DISCARD); Metal does not — the CPU overwrites data in-flight CBs are
// reading, and release Metal responds by discarding the affected draws
// (root cause of the black world: launch299/300/301 — draws landed only
// under full GPU drain or the validation layer's implicit sync).
//
// Fix: on Map(flush=true) rotate to a backing buffer whose last CPU write is
// older than any CB can still be in flight (kStreamLag frames; the present
// path bounds the backlog to maximumDrawableCount+1). Geometry records bake
// the stream's BASE handle at startup (hGeom.create(..., Vertex.Buffer())),
// so the pass manager resolves base → current slot at encode time via
// MtlStreamBufferCurrent(); rotation is invisible to cached handles.
uint64_t g_mtlStreamFrameGen = 0; // bumped once per frame (MtlFrameBegin)

namespace
{
using xray::render::RENDER_NAMESPACE::HW;

struct MtlStreamSlot
{
    void* buf;
    uint64_t gen; // frame gen of the most recent CPU write
};

struct MtlStreamRing
{
    void* base = nullptr; // stable handle (slot 0), registry key for binds
    void* cur = nullptr;  // slot the CPU is currently writing
    size_t size = 0;
    std::vector<MtlStreamSlot> slots;
};

// In-flight CBs are bounded (present drains at cap); 8 frames is comfortably
// beyond maximumDrawableCount+1+1, so a slot idle that long has no reader.
constexpr uint64_t kStreamLag = 8;
constexpr size_t kStreamMaxSlots = 16; // 16x4MB VB worst case — lazy, ~4 used

std::unordered_map<const void*, MtlStreamRing>
    g_streamRings;                                     // stream object -> ring
std::unordered_map<void*, MtlStreamRing*> g_streamBase; // base handle -> ring

void StreamRegister(const void* key, void* firstBuf, size_t size)
{
    MtlStreamRing& ring = g_streamRings[key];
    ring.base = firstBuf;
    ring.cur = firstBuf;
    ring.size = size;
    ring.slots.push_back({firstBuf, 0});
    g_streamBase[firstBuf] = &ring;
}

void* StreamRotate(const void* key)
{
    auto it = g_streamRings.find(key);
    if (it == g_streamRings.end())
        return nullptr;
    MtlStreamRing& ring = it->second;
    const uint64_t gen = g_mtlStreamFrameGen;
    MtlStreamSlot* best = nullptr;
    for (MtlStreamSlot& s : ring.slots)
        if (s.gen + kStreamLag <= gen && (!best || s.gen < best->gen))
            best = &s;
    if (!best && ring.slots.size() < kStreamMaxSlots)
    {
        void* b = HW.MtlDev.NewBuffer(static_cast<u32>(ring.size));
        if (b)
        {
            ring.slots.push_back({b, 0});
            best = &ring.slots.back();
        }
    }
    if (!best) // pathological: every slot busy — oldest (old single-buffer behavior)
        for (MtlStreamSlot& s : ring.slots)
            if (!best || s.gen < best->gen)
                best = &s;
    if (!best)
        return nullptr;
    best->gen = gen;
    ring.cur = best->buf;
    return ring.cur;
}

void StreamUnregister(const void* key)
{
    auto it = g_streamRings.find(key);
    if (it == g_streamRings.end())
        return;
    g_streamBase.erase(it->second.base);
    for (MtlStreamSlot& s : it->second.slots)
        HW.MtlDev.ReleaseResource(s.buf);
    g_streamRings.erase(it);
}
} // namespace

// Bind-time resolution for baked stream handles (mtlRuntime.mm EmitDraw).
// Non-stream handles (static/staging buffers) pass through untouched.
void* MtlStreamBufferCurrent(void* handle)
{
    if (!handle)
        return handle;
    auto it = g_streamBase.find(handle);
    return it != g_streamBase.end() ? it->second->cur : handle;
}

namespace xray::render::RENDER_NAMESPACE
{
u32 GetFVFVertexSize(u32 FVF)
{
    return static_cast<u32>(::FVF::ComputeVertexSize(FVF));
}

u32 GetDeclVertexSize(const VertexElement* decl, u32 Stream)
{
    return static_cast<u32>(::FVF::ComputeVertexSize(decl, Stream));
}

u32 GetDeclLength(const VertexElement* decl)
{
    return static_cast<u32>(::FVF::GetDeclLength(decl));
}

void ConvertVertexDeclaration(const VertexElement* dxdecl, SDeclaration* decl)
{
    // Metal: the pass manager derives the MTLVertexDescriptor per draw from
    // decl->dcl_code + the bound VS's attribute reflection (mtlRuntime.mm).
    // Nothing device-side to bind eagerly (unlike GL's VAO-era call).
    (void)dxdecl;
    (void)decl;
}

void SetMetalVertexPointer(SDeclaration* decl, u32 baseOffset)
{
    // Kept for the BufferUtils.h contract; layout binding happens at draw
    // time (ResolvePipeline). baseOffset (StartVertex) rides on the draw.
    (void)decl;
    (void)baseOffset;
}

// --- helpers ------------------------------------------------------------------
static inline void* CreateMetalBuffer(const void* pData, u32 dataSize)
{
    if (dataSize == 0)
        dataSize = 16; // Metal rejects zero-length buffers
    void* buf = HW.MtlDev.NewBuffer(dataSize);
    if (buf && pData)
        std::memcpy(HW.MtlDev.BufferContents(buf), pData, dataSize);
    return buf;
}

static inline void DestroyMetalBuffer(void*& buf)
{
    if (buf)
    {
        HW.MtlDev.ReleaseResource(buf);
        buf = nullptr;
    }
}

//-----------------------------------------------------------------------------
VertexStagingBuffer::~VertexStagingBuffer()
{
    Destroy();
}

void VertexStagingBuffer::Create(size_t size, bool allowReadBack /*= false*/)
{
    m_Size = size;
    m_AllowReadBack = allowReadBack;

    m_HostBuffer = xr_alloc<u8>(size);
    AddRef();
}

bool VertexStagingBuffer::IsValid() const
{
    return !!m_DeviceBuffer;
}

void* VertexStagingBuffer::Map(size_t offset /*= 0*/, size_t size /*= 0*/, bool read /*= false*/)
{
    VERIFY2(m_HostBuffer, "Buffer wasn't created or already discarded");
    VERIFY2(!read || m_AllowReadBack, "Can't read from write only buffer");
    VERIFY2((size + offset) <= m_Size, "Map region is too large");

    return static_cast<u8*>(m_HostBuffer) + offset;
}

void VertexStagingBuffer::Unmap(bool doFlush /*= false*/)
{
    if (!doFlush)
        return;

    VERIFY2(!m_DeviceBuffer, "Attempting to upload buffer twice");
    VERIFY(m_HostBuffer && m_Size);

    // Upload data to the device
    m_DeviceBuffer = CreateMetalBuffer(m_HostBuffer, (u32)m_Size);

    if (!m_AllowReadBack)
        DiscardHostBuffer();
}

VertexBufferHandle VertexStagingBuffer::GetBufferHandle() const
{
    return m_DeviceBuffer;
}

void VertexStagingBuffer::Destroy()
{
    DiscardHostBuffer();
    m_Size = 0;
    DestroyMetalBuffer(m_DeviceBuffer);
}

void VertexStagingBuffer::DiscardHostBuffer()
{
    if (m_HostBuffer)
        xr_free(m_HostBuffer);
}

size_t VertexStagingBuffer::GetSystemMemoryUsage() const
{
    return m_HostBuffer ? m_Size : 0;
}

size_t VertexStagingBuffer::GetVideoMemoryUsage() const
{
    return m_DeviceBuffer ? m_Size : 0;
}

//-----------------------------------------------------------------------------
IndexStagingBuffer::~IndexStagingBuffer()
{
    Destroy();
}

void IndexStagingBuffer::Create(size_t size, bool allowReadBack /*= false*/, bool /*managed = true*/)
{
    m_Size = size;
    m_AllowReadBack = allowReadBack;

    m_HostBuffer = xr_alloc<u8>(size);
    AddRef();
}

bool IndexStagingBuffer::IsValid() const
{
    return !!m_DeviceBuffer;
}

void* IndexStagingBuffer::Map(size_t offset /*= 0*/, size_t size /*= 0*/, bool read /*= false*/)
{
    VERIFY2(m_HostBuffer, "Buffer wasn't created or already discarded");
    VERIFY2(!read || m_AllowReadBack, "Can't read from write only buffer");
    VERIFY2((size + offset) <= m_Size, "Map region is too large");

    return static_cast<u8*>(m_HostBuffer) + offset;
}

void IndexStagingBuffer::Unmap(bool doFlush /*= false*/)
{
    if (!doFlush)
        return;

    VERIFY2(!m_DeviceBuffer, "Attempting to upload buffer twice");
    VERIFY(m_HostBuffer && m_Size);

    m_DeviceBuffer = CreateMetalBuffer(m_HostBuffer, (u32)m_Size);

    if (!m_AllowReadBack)
        DiscardHostBuffer();
}

IndexBufferHandle IndexStagingBuffer::GetBufferHandle() const
{
    return m_DeviceBuffer;
}

void IndexStagingBuffer::Destroy()
{
    DiscardHostBuffer();
    m_Size = 0;
    DestroyMetalBuffer(m_DeviceBuffer);
}

void IndexStagingBuffer::DiscardHostBuffer()
{
    if (m_HostBuffer)
        xr_free(m_HostBuffer);
}

size_t IndexStagingBuffer::GetSystemMemoryUsage() const
{
    return m_HostBuffer ? m_Size : 0;
}

size_t IndexStagingBuffer::GetVideoMemoryUsage() const
{
    return m_DeviceBuffer ? m_Size : 0;
}

//-----------------------------------------------------------------------------
VertexStreamBuffer::~VertexStreamBuffer()
{
    Destroy();
}

void VertexStreamBuffer::Create(size_t size)
{
    m_DeviceBuffer = CreateMetalBuffer(nullptr, (u32)size);
    if (m_DeviceBuffer)
        StreamRegister(this, m_DeviceBuffer, size);
    AddRef();
}

void VertexStreamBuffer::Destroy()
{
    StreamUnregister(this); // frees every slot (slot 0 == m_DeviceBuffer)
    m_DeviceBuffer = nullptr;
}

void* VertexStreamBuffer::Map(size_t offset, size_t size, bool flush /*= false*/)
{
    VERIFY(m_DeviceBuffer);
    if (flush)
    {
        // DX9 DISCARD semantics: hand out storage no in-flight CB reads.
        if (void* rotated = StreamRotate(this))
            m_DeviceBuffer = rotated;
    }
    u8* base = (u8*)HW.MtlDev.BufferContents(m_DeviceBuffer);
    VERIFY(offset + size <= HW.MtlDev.BufferSize(m_DeviceBuffer));
    return base + offset;
}

void VertexStreamBuffer::Unmap()
{
    // Shared-storage writes are visible to the next command buffer.
}

bool VertexStreamBuffer::IsValid() const
{
    return !!m_DeviceBuffer;
}

//-----------------------------------------------------------------------------
IndexStreamBuffer::~IndexStreamBuffer()
{
    Destroy();
}

void IndexStreamBuffer::Create(size_t size)
{
    m_DeviceBuffer = CreateMetalBuffer(nullptr, (u32)size);
    if (m_DeviceBuffer)
        StreamRegister(this, m_DeviceBuffer, size);
    AddRef();
}

void IndexStreamBuffer::Destroy()
{
    StreamUnregister(this); // frees every slot (slot 0 == m_DeviceBuffer)
    m_DeviceBuffer = nullptr;
}

void* IndexStreamBuffer::Map(size_t offset, size_t size, bool flush /*= false*/)
{
    VERIFY(m_DeviceBuffer);
    if (flush)
    {
        if (void* rotated = StreamRotate(this))
            m_DeviceBuffer = rotated;
    }
    u8* base = (u8*)HW.MtlDev.BufferContents(m_DeviceBuffer);
    VERIFY(offset + size <= HW.MtlDev.BufferSize(m_DeviceBuffer));
    return base + offset;
}

void IndexStreamBuffer::Unmap()
{
}

bool IndexStreamBuffer::IsValid() const
{
    return !!m_DeviceBuffer;
}
} // namespace xray::render::RENDER_NAMESPACE
