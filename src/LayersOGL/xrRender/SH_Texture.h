#pragma once

#include "xrCore/xr_resource.h"

class CAviPlayerCustom;
class ENGINE_API CTheoraSurface;

namespace xray::render::RENDER_NAMESPACE
{
#if defined(USE_METAL)
// Texture dimension tag (mirrors GL's GLenum desc; mtlTexture.cpp's
// texture_load returns it, CTexture::desc stores it, apply paths switch on it).
enum mtl_tex_dim : u32
{
    mtd2D = 0,
    mtd3D = 1,
    mtdCube = 2,
    mtd2DArray = 3
};
#endif
class ECORE_API CTexture : public xr_resource_named
{
public:
    enum	MaxTextures
    {
        //	Actually these values are 128
        mtMaxPixelShaderTextures = 16,
        mtMaxVertexShaderTextures = 4,
        mtMaxGeometryShaderTextures = 16,
#ifdef USE_DX11
        mtMaxHullShaderTextures = 16,
        mtMaxDomainShaderTextures = 16,
        mtMaxComputeShaderTextures = 16,
#endif
        mtMaxCombinedShaderTextures =
        mtMaxPixelShaderTextures
        + mtMaxVertexShaderTextures
        + mtMaxGeometryShaderTextures
#ifdef USE_DX11
        + mtMaxHullShaderTextures
        + mtMaxDomainShaderTextures
        + mtMaxComputeShaderTextures
#endif
    };

#if defined(USE_DX11)
    //	Since DX11 allows up to 128 unique textures,
    //	distance between enum values should be at leas 128
    enum ResourceShaderType //	Don't change this since it's hardware-dependent
    {
        rstPixel = 0,
        // Default texture offset
        rstVertex = D3DVERTEXTEXTURESAMPLER0,
        rstGeometry = rstVertex + 256,
        rstHull = rstGeometry + 256,
        rstDomain = rstHull + 256,
        rstCompute = rstDomain + 256,
        rstInvalid = rstCompute + 256
    };
#elif defined(USE_OGL) || defined(USE_METAL)
    //	Since OGL/Metal doesn't differentiate between stages,
    //	distance between enum values should be the max for that stage.
    enum ResourceShaderType
    {
        rstPixel = 0,	//	Default texture offset
        rstVertex = rstPixel + mtMaxPixelShaderTextures,
        rstGeometry = rstVertex + mtMaxVertexShaderTextures,
    };
#else
#   error No graphics API selected or enabled!
#endif

public:
    void apply_load(CBackend& cmd_list, u32 stage);
    void apply_theora(CBackend& cmd_list, u32 stage);
    void apply_avi(CBackend& cmd_list, u32 stage) const;
    void apply_seq(CBackend& cmd_list, u32 stage);
    void apply_normal(CBackend& cmd_list, u32 stage) const;

    void set_slice(int slice);

    void Preload();
    void Load();
    void PostLoad();
    void Unload();
    // void Apply(u32 dwStage);

#if defined(USE_DX11)
    void surface_set(ID3DBaseTexture* surf);
    [[nodiscard]] ID3DBaseTexture* surface_get() const;
#elif defined(USE_OGL)
    void surface_set(GLenum target, GLuint surf);
    [[nodiscard]] GLuint surface_get() const;
    void size_set(u32 width, u32 height)
    {
        m_loaded_width = width;
        m_loaded_height = height;
    }
#elif defined(USE_METAL)
    // p5 Metal: surf = id<MTLTexture> (bridged, owned by the texture itself)
    void surface_set(void* surf);
    [[nodiscard]] void* surface_get() const;
    void size_set(u32 width, u32 height)
    {
        m_loaded_width = width;
        m_loaded_height = height;
    }
#else
#   error No graphics API selected or enabled!
#endif

    [[nodiscard]] BOOL isUser() const
    {
        return flags.bUser;
    }

    u32 get_Width()
    {
        desc_enshure();
        return m_width;
    }

    u32 get_Height()
    {
        desc_enshure();
        return m_height;
    }

    void video_Sync(u32 _time) { m_play_time = _time; }
    void video_Play(BOOL looped, u32 _time = 0xFFFFFFFF);
    void video_Pause(BOOL state) const;
    void video_Stop() const;
    [[nodiscard]] BOOL video_IsPlaying() const;

    CTexture();
    virtual ~CTexture();

#if defined(USE_DX11)
    ID3DShaderResourceView* get_SRView() const { return m_pSRView; }
#endif

#if defined(USE_DX11)
    ImTextureID GetImTextureID()
    {
        if (!flags.bLoaded)
            Load();
        return reinterpret_cast<ImTextureID>(m_pSRView);
    }
#elif defined(USE_OGL)
    ImTextureID GetImTextureID()
    {
        if (!flags.bLoaded)
            Load();
        return static_cast<ImTextureID>(pSurface);
    }
#elif defined(USE_METAL)
    ImTextureID GetImTextureID()
    {
        if (!flags.bLoaded)
            Load();
        return reinterpret_cast<ImTextureID>(pSurface);
    }
#else
#   error No graphics API selected or enabled!
#endif

private:
    [[nodiscard]] BOOL desc_valid() const
    {
        return pSurface == desc_cache;
    }

    void desc_enshure()
    {
        if (!desc_valid())
            desc_update();
    }

    void desc_update();
#if defined(USE_OGL) || defined(USE_METAL)
    u32 m_loaded_width{}, m_loaded_height{}; // recorded at creation, WebGL cannot query texture levels
#endif
#if defined(USE_DX11)
    void Apply(CBackend& cmd_list, u32 dwStage) const;
    D3D_USAGE GetUsage();
#endif

    //	Class data
public: //	Public class members (must be encapsulated further)
    struct
    {
        u32 bLoaded : 1;
        u32 bUser : 1;
        u32 seqCycles : 1;
        u32 MemoryUsage : 28;
    } flags;

    fastdelegate::FastDelegate2<CBackend&,u32> bind;

    CAviPlayerCustom* pAVI;
    CTheoraSurface* pTheora;
    float m_material;
    shared_str m_bumpmap;

    union
    {
        u32 m_play_time; // sync theora time
        u32 seqMSPF; // Sequence data milliseconds per frame
    };

    int curr_slice{ -1 };
    int last_slice{ -1 };

private:
#if defined(USE_DX11)
    ID3DBaseTexture* pSurface{};
    ID3DBaseTexture* pTempSurface{};
    // Sequence data
    xr_vector<ID3DBaseTexture*> seqDATA;

    // Description
    u32 m_width;
    u32 m_height;
    ID3DBaseTexture* desc_cache;
    D3D_TEXTURE2D_DESC desc;
#elif defined(USE_OGL)
    GLuint pSurface;
    GLuint pBuffer;
    // Sequence data
    xr_vector<GLuint> seqDATA;
    // Description
    GLint m_width;
    GLint m_height;
    GLuint desc_cache;
    GLenum desc;
#elif defined(USE_METAL)
    void* pSurface{}; // id<MTLTexture>, owned by this texture (device arena)
    void* pBuffer{};
    // Sequence data
    xr_vector<void*> seqDATA;
    // Description
    u32 m_width{};
    u32 m_height{};
    void* desc_cache{};
    // Texture "target" tag (dimension) — mirrors GL's GLenum desc; values
    // from the namespace-scope mtl_tex_dim above.
    u32 desc{ mtd2D };
#else
#   error No graphics API selected or enabled!
#endif

#if defined(USE_DX11)
    ID3DShaderResourceView* m_pSRView{ nullptr };
    ID3DShaderResourceView* srv_all{ nullptr };
    xr_vector<ID3DShaderResourceView*> srv_per_slice;
    // Sequence view data
    xr_vector<ID3DShaderResourceView*> m_seqSRView;
#endif
};

struct resptrcode_texture : public resptr_base<CTexture>
{
    void create(LPCSTR _name);
    void destroy() { _set(nullptr); }
    shared_str bump_get() { return _get()->m_bumpmap; }
    bool bump_exist() { return 0 != bump_get().size(); }
};

typedef resptr_core<CTexture, resptrcode_texture> ref_texture;
} // namespace xray::render::RENDER_NAMESPACE
