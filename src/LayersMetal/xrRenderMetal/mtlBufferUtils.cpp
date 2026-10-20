// mtlBufferUtils.cpp — buffer classes + decl helpers on the Metal substrate
// (mirror of glBufferUtils.cpp). Handles are borrowed id<MTLBuffer> void*s
// owned by the device arena; Metal shared-storage buffers are CPU-mapped for
// their lifetime, so Map() just returns contents+offset and Unmap() is a
// no-op (no GL-style orphaning — the engine's ring discipline is the pass
// manager's job for dynamic streams).
#include "stdafx.h"
#include "Layers/xrRender/BufferUtils.h"

#include <FlexibleVertexFormat.h>

#include "mtlHW.h" // CHW::MtlDev facade

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
    AddRef();
}

void VertexStreamBuffer::Destroy()
{
    DestroyMetalBuffer(m_DeviceBuffer);
}

void* VertexStreamBuffer::Map(size_t offset, size_t size, bool flush /*= false*/)
{
    VERIFY(m_DeviceBuffer);
    (void)flush; // shared storage: no orphaning model
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
    AddRef();
}

void IndexStreamBuffer::Destroy()
{
    DestroyMetalBuffer(m_DeviceBuffer);
}

void* IndexStreamBuffer::Map(size_t offset, size_t size, bool flush /*= false*/)
{
    VERIFY(m_DeviceBuffer);
    (void)flush;
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
