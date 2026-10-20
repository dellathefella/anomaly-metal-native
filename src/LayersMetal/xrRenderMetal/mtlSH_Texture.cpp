// mtlSH_Texture.cpp — CTexture on the Metal substrate (p5 t2).
// Mirror of glSH_Texture.cpp with the Metal binding model: apply_* records
// stage -> texture into the pass manager's stage table
// (MtlRecordTextureStage/mtlRuntime.mm); the actual setFragmentTexture /
// setVertexTexture happens per-draw from shader reflection. Video updates
// upload BGRA bytes through the substrate (BGRA8 video textures, no swizzle).
// Plain C++: every device call goes through the substrate facade.
#include "stdafx.h"
#pragma hdrstop

#include "Layers/xrRender/ResourceManager.h"
#include "xrEngine/xrTheora_Surface.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "Layers/xrRenderMetal/mtlRuntime.h"
#include "Layers/xrRenderMetal/mtl_dx9_format.h"

#define PRIORITY_HIGH   12
#define PRIORITY_NORMAL 8
#define PRIORITY_LOW    4

namespace xray::render::RENDER_NAMESPACE
{
void resptrcode_texture::create(LPCSTR _name)
{
    _set(RImplementation.Resources->_CreateTexture(_name));
}

//////////////////////////////////////////////////////////////////////
// Construction/Destruction
//////////////////////////////////////////////////////////////////////
CTexture::CTexture()
{
    pSurface = nullptr;
    pBuffer = nullptr;
    pAVI = nullptr;
    pTheora = nullptr;
    desc = mtd2D;
    desc_cache = nullptr;
    seqMSPF = 0;
    flags.MemoryUsage = 0;
    flags.bLoaded = false;
    flags.bUser = false;
    flags.seqCycles = FALSE;
    m_material = 1.0f;
    bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_load);
}

CTexture::~CTexture()
{
    Unload();
    // release external reference
    RImplementation.Resources->_DeleteTexture(this);
}

void CTexture::surface_set(void* surf)
{
    pSurface = surf;
}

void* CTexture::surface_get() const
{
    return pSurface;
}

void CTexture::PostLoad()
{
    if (pTheora) bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_theora);
    else if (pAVI) bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_avi);
    else if (!seqDATA.empty()) bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_seq);
    else bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_normal);
}

void CTexture::apply_load(CBackend& cmd_list, u32 dwStage)
{
    if (!flags.bLoaded) Load();
    else PostLoad();
    bind(cmd_list, dwStage);
};

void CTexture::apply_theora(CBackend& cmd_list, u32 dwStage)
{
    if (pTheora->Update(m_play_time != 0xFFFFFFFF ? m_play_time : Device.dwTimeContinual))
    {
        const u32 _w = pTheora->Width(true);
        const u32 _h = pTheora->Height(true);
        // Decompress into a CPU staging buffer, then replaceRegion (BGRA8
        // texture — the decoder emits BGRA, so no channel fixup needed).
        xr_vector<u32> frame(_w * _h);
        int framePos = 0;
        pTheora->DecompressFrame(frame.data(), 0, framePos);
        std::string err;
        if (!HW.MtlDev.WriteTextureRegion(pSurface, 0, 0, frame.data(), _w, _h, 4, err))
            Msg("! Metal: theora upload failed: %s", err.c_str());
    }
    MtlRecordTextureStage(dwStage, pSurface);
};

void CTexture::apply_avi(CBackend& cmd_list, u32 dwStage) const
{
    // AVI playback is Windows-only in the shared code; nothing to update.
    MtlRecordTextureStage(dwStage, pSurface);
};

void CTexture::apply_seq(CBackend& cmd_list, u32 dwStage)
{
    // SEQ
    u32 frame = Device.dwTimeContinual / seqMSPF; //Device.dwTimeGlobal
    u32 frame_data = seqDATA.size();
    if (flags.seqCycles)
    {
        u32 frame_id = frame % (frame_data * 2);
        if (frame_id >= frame_data) frame_id = frame_data - 1 - frame_id % frame_data;
        pSurface = seqDATA[frame_id];
    }
    else
    {
        u32 frame_id = frame % frame_data;
        pSurface = seqDATA[frame_id];
    }

    MtlRecordTextureStage(dwStage, pSurface);
};

void CTexture::apply_normal(CBackend& cmd_list, u32 dwStage) const
{
    MtlRecordTextureStage(dwStage, pSurface);
};

void CTexture::Preload()
{
    m_bumpmap = RImplementation.Resources->m_textures_description.GetBumpName(cName);
    m_material = RImplementation.Resources->m_textures_description.GetMaterial(cName);
}

void CTexture::Load()
{
    flags.bLoaded = true;
    desc_cache = nullptr;
    if (pSurface) return;

    flags.bUser = false;
    flags.MemoryUsage = 0;
    if (nullptr == cName.c_str())
        return;
    if (0 == xr_stricmp(cName.c_str(), "$null")) return;
    // we need to check only the beginning of the string,
    // so let's use strncmp instead of strstr.
    if (0 == strncmp(cName.c_str(), "$user$", sizeof("$user$") - 1))
    {
        flags.bUser = true;
        return;
    }

    ZoneScoped;

    Preload();

    // Check for OGM
    string_path fn;
    if (FS.exist(fn, "$game_textures$", cName.c_str(), ".ogm"))
    {
        // AVI
        pTheora = xr_new<CTheoraSurface>();
        m_play_time = 0xFFFFFFFF;

        if (!pTheora->Load(fn))
        {
            xr_delete(pTheora);
            FATAL("Can't open video stream");
        }
        else
        {
            flags.MemoryUsage = pTheora->Width(true) * pTheora->Height(true) * 4;
            pTheora->Play(TRUE, Device.dwTimeContinual);

            // Video texture: BGRA8, mip0 only, shader-readable (uploaded
            // per-frame through WriteTextureRegion in apply_theora).
            const u32 _w = pTheora->Width(false);
            const u32 _h = pTheora->Height(false);
            void* tex = HW.MtlDev.NewTexture2D(_w, _h, 1, mtlPF_BGRA8Unorm, /*fbOnly*/ false, /*readable*/ true);
            if (tex)
            {
                pSurface = tex;
                desc = mtd2D;
                size_set(_w, _h);
            }
            else
            {
                Msg("Invalid video stream: texture create failed");
                xr_delete(pTheora);
                pSurface = nullptr;
            }
        }
    }
    else if (FS.exist(fn, "$game_textures$", cName.c_str(), ".avi"))
    {
        // AVI playback is Windows-only in the shared code (tntQAVI).
        Msg("! Metal: .avi texture '%s' is not supported on this platform", cName.c_str());
    }
    else if (FS.exist(fn, "$game_textures$", cName.c_str(), ".seq"))
    {
        // Sequence
        string256 buffer;
        IReader* _fs = FS.r_open(fn);

        flags.seqCycles = FALSE;
        _fs->r_string(buffer, sizeof buffer);
        if (0 == xr_stricmp(buffer, "cycled"))
        {
            flags.seqCycles = TRUE;
            _fs->r_string(buffer, sizeof buffer);
        }
        u32 fps = atoi(buffer);
        seqMSPF = 1000 / fps;

        while (!_fs->eof())
        {
            _fs->r_string(buffer, sizeof buffer);
            _Trim(buffer);
            if (buffer[0])
            {
                // Load another texture
                u32 mem = 0;
                u32 dim = mtd2D;
                pSurface = RImplementation.texture_load(buffer, mem, dim, m_loaded_width, m_loaded_height);
                if (pSurface)
                {
                    seqDATA.push_back(pSurface);
                    flags.MemoryUsage += mem;
                }
            }
        }
        pSurface = nullptr;
        desc = mtd2D;
        FS.r_close(_fs);
    }
    else
    {
        // Normal texture
        u32 mem = 0;
        u32 dim = mtd2D;
        pSurface = RImplementation.texture_load(cName.c_str(), mem, dim, m_loaded_width, m_loaded_height);
        desc = dim;

        // Calc memory usage and preload into vid-mem
        if (pSurface)
        {
            flags.MemoryUsage = mem;
        }
    }

    PostLoad();
}

void CTexture::Unload()
{
    ZoneScoped;
#ifdef DEBUG
    string_path msg_buff;
    sprintf_s(msg_buff, sizeof(msg_buff), "* Unloading texture [%s] pSurface=%p", cName.c_str(), pSurface);
#endif // DEBUG

    //.	if (flags.bLoaded)		Msg		("* Unloaded: %s",cName.c_str());

    flags.bLoaded = FALSE;
    auto& dev = HW.MtlDev;
    if (!seqDATA.empty())
    {
        for (void* seqTex : seqDATA)
            dev.ReleaseResource(seqTex);
        seqDATA.clear();
        pSurface = nullptr;
    }

    if (pSurface)
        dev.ReleaseResource(pSurface);
    pSurface = nullptr;
    if (pBuffer)
        dev.ReleaseResource(pBuffer);
    pBuffer = nullptr;

    // AVI is Windows-only in the shared code; pAVI is never created on this
    // port, and CAviPlayerCustom is only forward-declared here (no complete
    // type to delete through).
    pAVI = nullptr;
    xr_delete(pTheora);

    bind = fastdelegate::FastDelegate2<CBackend&, u32>(this, &CTexture::apply_load);
}

void CTexture::desc_update()
{
    desc_cache = pSurface;
    // Sizes recorded at creation (substrate handles carry no cheap CPU-side
    // query through the facade; RT-bound surfaces get size_set()).
    m_width = m_loaded_width;
    m_height = m_loaded_height;
}

void CTexture::video_Play(BOOL looped, u32 _time)
{
    if (pTheora) pTheora->Play(looped, _time != 0xFFFFFFFF ? (m_play_time = _time) : Device.dwTimeContinual);
}

void CTexture::video_Pause(BOOL state) const
{
    if (pTheora) pTheora->Pause(state);
}

void CTexture::video_Stop() const
{
    if (pTheora) pTheora->Stop();
}

BOOL CTexture::video_IsPlaying() const
{
    return pTheora ? pTheora->IsPlaying() : FALSE;
}
} // namespace xray::render::RENDER_NAMESPACE
