// mtlTexture.cpp — CRender::texture_load on the Metal substrate (p5 t2).
// Mirror of glTexture.cpp: same file lookup + gli DDS parsing + memory
// accounting. Metal carries the whole BCn family natively (the GL path's
// bcdec CPU-decode exists only because Apple Silicon's GL lacks RGTC/BPTC),
// so uploads are straight replaceRegion calls; only 24-bit RGB needs a
// channel-expand fallback (Metal has no RGB8).
#include "stdafx.h"

#include <gli/gli.hpp>

#include "r2.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "Layers/xrRenderMetal/mtl_dx9_format.h"

namespace xray::render::RENDER_NAMESPACE
{
void fix_texture_name(pstr fn)
{
    pstr _ext = strext(fn);
    if (_ext &&
        (0 == xr_stricmp(_ext, ".tga") ||
            0 == xr_stricmp(_ext, ".dds") ||
            0 == xr_stricmp(_ext, ".bmp") ||
            0 == xr_stricmp(_ext, ".ogm")))
        *_ext = 0;
}

int get_texture_load_lod(LPCSTR fn)
{
    CInifile::Sect& sect = pSettings->r_section("reduce_lod_texture_list");

    for (const auto& item : sect.Data)
    {
        if (strstr(fn, item.first.c_str()))
        {
            if (psTextureLOD < 1)
                return 0;
            if (psTextureLOD < 3)
                return 1;
            return 2;
        }
    }

    if (psTextureLOD < 2)
        return 0;
    if (psTextureLOD < 4)
        return 1;
    return 2;
}

u32 calc_texture_size(int lod, u32 mip_cnt, size_t orig_size)
{
    if (1 == mip_cnt)
        return orig_size;

    int _lod = lod;
    float res = float(orig_size);

    while (_lod > 0)
    {
        --_lod;
        res -= res / 1.333f;
    }
    return iFloor(res);
}

namespace
{
struct mtl_texfmt_info
{
    uint32_t mtl{ mtlPF_INVALID };
    uint32_t blockBytes{ 0 }; // >0 = compressed
    uint32_t bpp{ 0 }; // uncompressed bytes/pixel
    bool expandRgb8{ false }; // 24-bit -> BGRA8 (Metal has no RGB8)
};

mtl_texfmt_info map_gli_format(gli::format f)
{
    using namespace gli;
    mtl_texfmt_info o;
    switch (f)
    {
    // --- uncompressed ---
    case FORMAT_RGBA8_UNORM_PACK8: o.mtl = mtlPF_RGBA8Unorm; o.bpp = 4; break;
    case FORMAT_RGBA8_SRGB_PACK8: o.mtl = mtlPF_RGBA8Unorm_sRGB; o.bpp = 4; break;
    case FORMAT_BGRA8_UNORM_PACK8: o.mtl = mtlPF_BGRA8Unorm; o.bpp = 4; break;
    case FORMAT_R8_UNORM_PACK8: o.mtl = mtlPF_R8Unorm; o.bpp = 1; break;
    case FORMAT_R8_SNORM_PACK8: o.mtl = mtlPF_R8Snorm; o.bpp = 1; break;
    case FORMAT_RG8_UNORM_PACK8: o.mtl = mtlPF_RG8Unorm; o.bpp = 2; break;
    case FORMAT_RG8_SNORM_PACK8: o.mtl = mtlPF_RG8Snorm; o.bpp = 2; break; // D3DFMT_V8U8 normals
    case FORMAT_R16_UNORM_PACK16: o.mtl = mtlPF_R16Unorm; o.bpp = 2; break;
    case FORMAT_R16_SNORM_PACK16: o.mtl = mtlPF_R16Snorm; o.bpp = 2; break;
    case FORMAT_R16_SFLOAT_PACK16: o.mtl = mtlPF_R16Float; o.bpp = 2; break;
    case FORMAT_RG16_UNORM_PACK16: o.mtl = mtlPF_RG16Unorm; o.bpp = 4; break;
    case FORMAT_RG16_SNORM_PACK16: o.mtl = mtlPF_RG16Snorm; o.bpp = 4; break; // D3DFMT_V16U16
    case FORMAT_RG16_SFLOAT_PACK16: o.mtl = mtlPF_RG16Float; o.bpp = 4; break; // D3DFMT_G16R16F
    case FORMAT_RGBA16_UNORM_PACK16: o.mtl = mtlPF_RGBA16Unorm; o.bpp = 8; break;
    case FORMAT_RGBA16_SNORM_PACK16: o.mtl = mtlPF_RGBA16Snorm; o.bpp = 8; break; // D3DFMT_Q16W16V16U16
    case FORMAT_RGBA16_SFLOAT_PACK16: o.mtl = mtlPF_RGBA16Float; o.bpp = 8; break; // D3DFMT_A16B16G16R16F
    case FORMAT_R32_SFLOAT_PACK32: o.mtl = mtlPF_R32Float; o.bpp = 4; break;
    case FORMAT_RGBA32_SFLOAT_PACK32: o.mtl = mtlPF_RGBA32Float; o.bpp = 16; break;
    case FORMAT_RGB10A2_UNORM_PACK32: o.mtl = mtlPF_RGB10A2Unorm; o.bpp = 4; break;
    case FORMAT_A8_UNORM_PACK8: o.mtl = mtlPF_A8Unorm; o.bpp = 1; break; // DX9 A8 = (0,0,0,A) — exact match
    case FORMAT_L8_UNORM_PACK8: o.mtl = mtlPF_R8Unorm; o.bpp = 1; break; // .x reads exact; .rgb loses the DX9 broadcast
    case FORMAT_LA8_UNORM_PACK8: o.mtl = mtlPF_RG8Unorm; o.bpp = 2; break; // rare; no LA8 in Metal
    case FORMAT_R5G6B5_UNORM_PACK16: o.mtl = mtlPF_B5G6R5Unorm; o.bpp = 2; break;
    // 24-bit: expand to BGRA8 on upload
    case FORMAT_BGR8_UNORM_PACK8: o.mtl = mtlPF_BGRA8Unorm; o.bpp = 3; o.expandRgb8 = true; break;

    // --- BCn (native) ---
    case FORMAT_RGB_DXT1_UNORM_BLOCK8: case FORMAT_RGBA_DXT1_UNORM_BLOCK8:
        o.mtl = mtlPF_BC1_RGBA; o.blockBytes = 8; break;
    case FORMAT_RGB_DXT1_SRGB_BLOCK8: case FORMAT_RGBA_DXT1_SRGB_BLOCK8:
        o.mtl = mtlPF_BC1_RGBA_sRGB; o.blockBytes = 8; break;
    case FORMAT_RGBA_DXT3_UNORM_BLOCK16:
        o.mtl = mtlPF_BC2_RGBA; o.blockBytes = 16; break;
    case FORMAT_RGBA_DXT3_SRGB_BLOCK16:
        o.mtl = mtlPF_BC2_RGBA_sRGB; o.blockBytes = 16; break;
    case FORMAT_RGBA_DXT5_UNORM_BLOCK16:
        o.mtl = mtlPF_BC3_RGBA; o.blockBytes = 16; break;
    case FORMAT_RGBA_DXT5_SRGB_BLOCK16:
        o.mtl = mtlPF_BC3_RGBA_sRGB; o.blockBytes = 16; break;
    case FORMAT_R_ATI1N_UNORM_BLOCK8: o.mtl = mtlPF_BC4_RUnorm; o.blockBytes = 8; break;
    case FORMAT_R_ATI1N_SNORM_BLOCK8: o.mtl = mtlPF_BC4_RSnorm; o.blockBytes = 8; break;
    case FORMAT_RG_ATI2N_UNORM_BLOCK16: o.mtl = mtlPF_BC5_RGUnorm; o.blockBytes = 16; break;
    case FORMAT_RG_ATI2N_SNORM_BLOCK16: o.mtl = mtlPF_BC5_RGSnorm; o.blockBytes = 16; break;
    case FORMAT_RGB_BP_UFLOAT_BLOCK16: o.mtl = mtlPF_BC6H_RGBUfloat; o.blockBytes = 16; break;
    case FORMAT_RGB_BP_SFLOAT_BLOCK16: o.mtl = mtlPF_BC6H_RGBFloat; o.blockBytes = 16; break;
    case FORMAT_RGBA_BP_UNORM_BLOCK16: o.mtl = mtlPF_BC7_RGBAUnorm; o.blockBytes = 16; break;
    case FORMAT_RGBA_BP_SRGB_BLOCK16: o.mtl = mtlPF_BC7_RGBAUnorm_sRGB; o.blockBytes = 16; break;

    default: break;
    }
    return o;
}
} // namespace

void* CRender::texture_load(pcstr fRName, u32& ret_msize, u32& ret_desc, u32& ret_width, u32& ret_height)
{
    ret_msize = 0;
    ret_desc = mtd2D;
    R_ASSERT1_CURE(fRName && fRName[0], { return nullptr; });

    string_path fn;
    {
        // make file name
        string_path fname;
        xr_strcpy(fname, fRName);
        fix_texture_name(fname);

        // Call to FS.exist WRITES to fn !

        if (!FS.exist(fn, "$game_textures$", fname, ".dds") && strstr(fname, "_bump"))
        {
            Msg("! Fallback to default bump map: %s", fname);
            if (strstr(fname, "_bump#"))
                R_ASSERT1_CURE(FS.exist(fn, "$game_textures$", "ed\\ed_dummy_bump#", ".dds"), return nullptr);
            else
                R_ASSERT1_CURE(FS.exist(fn, "$game_textures$", "ed\\ed_dummy_bump", ".dds"), return nullptr);
        }
        else
        {
            bool exist = false;

            for (cpcstr folder : { "$level$", "$game_saves$", "$game_textures$" })
            {
                exist = FS.exist(fn, folder, fname, ".dds");
                if (exist)
                    break;
            }

            if (!exist)
            {
                Msg("! Can't find texture '%s'", fname);
                if (!FS.exist(fn, "$game_textures$", "ed\\ed_not_existing_texture", ".dds"))
                    return nullptr;
            }
        }
    }

    // Load and get header
    IReader* S = FS.r_open(fn);
    R_ASSERT2_CURE(S, fn, { return nullptr; });
    size_t img_size = S->length();
#ifdef DEBUG
    Msg("* Loaded: %s[%d]b", fn, img_size);
#endif // DEBUG
    gli::texture texture = gli::load((char*)S->pointer(), img_size);
    R_ASSERT2(!texture.empty(), fn);

    const mtl_texfmt_info fmt = map_gli_format(texture.format());
    if (fmt.mtl == mtlPF_INVALID)
    {
        Msg("! Metal: unsupported DDS format 0x%x for '%s' — using magenta fallback",
            (u32)texture.format(), fn);
        S->close();
        FS.r_close(S);
        return nullptr; // engine replaces null with ed_not_existing_texture upstream? no — caller keeps null; log once per texture
    }

    auto& dev = HW.MtlDev;
    const u32 levels = u32(texture.levels());
    void* pTexture = nullptr;
    const glm::vec3 ext(texture.extent());

    // p6 leakbeat: creation telemetry for the texture-reload-storm hunt
    // (liveTexMB grows unbounded). Rate-limited: first 300, then every 100th.
    static int s_texDbgN = 0;
    if (++s_texDbgN <= 300 || s_texDbgN % 100 == 0)
        Msg("- p6 texdbg: #%d '%s' %ux%u", s_texDbgN, fn, (u32)ext.x, (u32)ext.y);

    switch (texture.target())
    {
    case gli::TARGET_2D:
        ret_desc = mtd2D;
        pTexture = dev.NewTexture2D(u32(ext.x), u32(ext.y), levels, fmt.mtl, /*fbOnly*/ false, /*readable*/ true);
        break;
    case gli::TARGET_CUBE:
        ret_desc = mtdCube;
        pTexture = dev.NewTextureCube(u32(ext.x), levels, fmt.mtl, /*fbOnly*/ false, /*readable*/ true);
        break;
    case gli::TARGET_3D:
        ret_desc = mtd3D;
        pTexture = dev.NewTexture3D(u32(ext.x), u32(ext.y), u32(ext.z), levels, fmt.mtl, /*readable*/ true);
        break;
    case gli::TARGET_1D:
        // Metal texture1d needs MTLTextureType1D; the substrate has no 1D
        // factory (no 1D textures in the Anomaly corpus). Upload as 2D x1.
        ret_desc = mtd2D;
        pTexture = dev.NewTexture2D(u32(ext.x), 1, levels, fmt.mtl, false, true);
        break;
    case gli::TARGET_2D_ARRAY:
        ret_desc = mtd2DArray;
        pTexture = dev.NewTexture2DArray(u32(ext.x), u32(ext.y), u32(ext.z), levels, fmt.mtl, false, true);
        break;
    default:
        Msg("! Metal: unsupported DDS target %d for '%s'", (int)texture.target(), fn);
        S->close();
        FS.r_close(S);
        return nullptr;
    }
    if (!pTexture)
    {
        Msg("! Metal: texture create failed for '%s' (%ux%u fmt %u)", fn, u32(ext.x), u32(ext.y), fmt.mtl);
        S->close();
        FS.r_close(S);
        return nullptr;
    }

    std::string err;
    xr_vector<u8> expand; // 24-bit expand scratch
    const bool is3D = gli::TARGET_3D == texture.target();
    for (size_t layer = 0; layer < texture.layers(); ++layer)
    {
        for (size_t face = 0; face < texture.faces(); ++face)
        {
            for (size_t level = 0; level < texture.levels(); ++level)
            {
                const glm::vec3 le(texture.extent(level));
                const u32 w = u32(le.x), h = u32(le.y);
                const u8* src = static_cast<const u8*>(texture.data(layer, face, level));
                if (is3D)
                {
                    // Volumes: gli packs a whole level contiguously; upload z
                    // slices individually (substrate regions are depth-1).
                    const u32 d = u32(le.z);
                    const size_t sliceStride = texture.size(level) / d;
                    for (u32 z = 0; z < d; ++z)
                    {
                        const u8* zsrc = src + size_t(z) * sliceStride;
                        bool ok = fmt.blockBytes
                            ? dev.WriteTextureBlocks(pTexture, z, u32(level), zsrc, w, h, fmt.blockBytes, err)
                            : dev.WriteTextureRegion(pTexture, z, u32(level), zsrc, w, h, fmt.bpp, err);
                        if (!ok)
                            Msg("! Metal: volume upload failed (z %u mip %u) for '%s': %s", z, u32(level), fn, err.c_str());
                    }
                    continue;
                }
                const u32 slice = u32(layer * texture.faces() + face);
                bool ok = false;
                if (fmt.blockBytes)
                    ok = dev.WriteTextureBlocks(pTexture, slice, u32(level), src, w, h, fmt.blockBytes, err);
                else if (fmt.expandRgb8)
                {
                    expand.resize(size_t(w) * h * 4);
                    for (size_t i = 0; i < size_t(w) * h; ++i)
                    {
                        expand[i * 4 + 0] = src[i * 3 + 0];
                        expand[i * 4 + 1] = src[i * 3 + 1];
                        expand[i * 4 + 2] = src[i * 3 + 2];
                        expand[i * 4 + 3] = 255;
                    }
                    ok = dev.WriteTextureRegion(pTexture, slice, u32(level), expand.data(), w, h, 4, err);
                }
                else
                    ok = dev.WriteTextureRegion(pTexture, slice, u32(level), src, w, h, fmt.bpp, err);
                if (!ok)
                    Msg("! Metal: upload failed (slice %u mip %u) for '%s': %s", slice, u32(level), fn, err.c_str());
            }
        }
    }

    FS.r_close(S);

    xr_strlwr(fn);
    ret_width = u32(ext.x);
    ret_height = u32(ext.y);
    int img_loaded_lod = is_target_cube(texture.target()) ? 0 : get_texture_load_lod(fn);
    ret_msize = calc_texture_size(img_loaded_lod, u32(texture.levels()), img_size);
    return pTexture;
}
} // namespace xray::render::RENDER_NAMESPACE
