// Texture.cpp: implementation of the CTexture class.
//
//////////////////////////////////////////////////////////////////////

#include "stdafx.h"

#include <gli/gli.hpp>

// p4: CPU BCn decode for GL contexts without RGTC/BPTC (Apple Silicon's GL
// exposes only S3TC). Single-TU implementation; statics, no external symbols.
#define BCDEC_STATIC
#define BCDEC_IMPLEMENTATION
#include <bcdec.h>

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

GLuint CRender::texture_load(pcstr fRName, u32& ret_msize, GLenum& ret_desc, u32& ret_width, u32& ret_height)
{
    ret_msize = 0;
    R_ASSERT1_CURE(fRName && fRName[0], { return 0; });

    GLuint pTexture = 0;
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
                R_ASSERT1_CURE(FS.exist(fn, "$game_textures$", "ed\\ed_dummy_bump#", ".dds"), return 0);
            else
                R_ASSERT1_CURE(FS.exist(fn, "$game_textures$", "ed\\ed_dummy_bump", ".dds"), return 0);
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
                    return 0;
            }
        }
    }

    // Load and get header
    IReader* S = FS.r_open(fn);
    R_ASSERT2_CURE(S, fn, { return 0; });
    size_t img_size = S->length();
#ifdef DEBUG
    Msg("* Loaded: %s[%d]b", fn, img_size);
#endif // DEBUG
    gli::texture texture = gli::load((char*)S->pointer(), img_size);
    R_ASSERT2(!texture.empty(), fn);

    u32 mip_cnt = u32(-1); // XXX: write to it when reading with GLI!

#ifdef XR_PLATFORM_WEB
    gli::gl GL(gli::gl::PROFILE_ES30);
#else
    gli::gl GL(gli::gl::PROFILE_GL33);
#endif

    gli::gl::format const format = GL.translate(texture.format(), texture.swizzles());
    GLenum target = GL.translate(texture.target());

    // p4: the Apple Silicon GL driver supports S3TC (BC1-3) but not RGTC
    // (BC4/5) or BPTC (BC6H/BC7) — Anomaly's normal maps (BC5) and modern
    // albedo/HDR (BC7/BC6H) live there. Block-decode those to RGBA8/RGBA16F
    // on the CPU and upload as plain textures; S3TC stays on the hardware
    // path. Raw hex values because the glad configuration may not define the
    // extension tokens.
    enum
    {
        p4_GL_COMPRESSED_RED_RGTC1 = 0x8DBB, p4_GL_COMPRESSED_SIGNED_RED_RGTC1 = 0x8DBC,
        p4_GL_COMPRESSED_RG_RGTC2 = 0x8DBD, p4_GL_COMPRESSED_SIGNED_RG_RGTC2 = 0x8DBE,
        p4_GL_COMPRESSED_RGBA_BPTC_UNORM = 0x8E8C, p4_GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM = 0x8E8D,
        p4_GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT = 0x8E8E, p4_GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT = 0x8E8F
    };
    bool p4_decode = false;
    size_t p4_bps = 4; // destination bytes per pixel
    gli::gl::format p4_format = format;
    int p4_signed = 0;
    switch (format.Internal)
    {
    case p4_GL_COMPRESSED_RED_RGTC1: case p4_GL_COMPRESSED_RG_RGTC2:
    case p4_GL_COMPRESSED_RGBA_BPTC_UNORM:
        p4_decode = true;
        p4_format.Internal = GL_RGBA8;
        p4_format.External = GL_RGBA; p4_format.Type = GL_UNSIGNED_BYTE;
        break;
    case p4_GL_COMPRESSED_SIGNED_RED_RGTC1: case p4_GL_COMPRESSED_SIGNED_RG_RGTC2:
        p4_decode = true; p4_signed = 1;
        p4_format.Internal = GL_RGBA8;
        p4_format.External = GL_RGBA; p4_format.Type = GL_UNSIGNED_BYTE;
        break;
    case p4_GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
        p4_decode = true;
        p4_format.Internal = GL_SRGB8_ALPHA8;
        p4_format.External = GL_RGBA; p4_format.Type = GL_UNSIGNED_BYTE;
        break;
    case p4_GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT: case p4_GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
        p4_decode = true; p4_bps = 8; p4_signed = p4_GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT == format.Internal;
        p4_format.Internal = GL_RGBA16F;
        p4_format.External = GL_RGBA; p4_format.Type = GL_HALF_FLOAT;
        break;
    default: break;
    }
    if (p4_decode && gli::TARGET_2D != texture.target() && gli::TARGET_CUBE != texture.target())
        p4_decode = false; // rare 3D/array BCn: leave to GL (will warn below)

    xr_vector<u8> p4_decoded;
    xr_vector<size_t> p4_offsets;
    if (p4_decode)
    {
        const size_t faces = texture.faces(), layers = texture.layers(), levels = texture.levels();
        const auto p4_idx = [&](size_t l, size_t f, size_t lv) { return (l * faces + f) * levels + lv; };
        p4_offsets.resize(layers * faces * levels);
        size_t total = 0;
        for (size_t l = 0; l < layers; ++l)
            for (size_t f = 0; f < faces; ++f)
                for (size_t lv = 0; lv < levels; ++lv)
                { p4_offsets[p4_idx(l, f, lv)] = total; total += size_t(texture.extent(lv).x) * texture.extent(lv).y * p4_bps; }
        p4_decoded.resize(total);

        const GLenum fmt = format.Internal;
        const size_t bbytes = (p4_GL_COMPRESSED_RED_RGTC1 == fmt || p4_GL_COMPRESSED_SIGNED_RED_RGTC1 == fmt) ? 8 : 16;
        for (size_t l = 0; l < layers; ++l)
            for (size_t f = 0; f < faces; ++f)
                for (size_t lv = 0; lv < levels; ++lv)
                {
                    const u8* src = static_cast<const u8*>(texture.data(l, f, lv));
                    u8* dst = p4_decoded.data() + p4_offsets[p4_idx(l, f, lv)];
                    const GLsizei w = GLsizei(texture.extent(lv).x), h = GLsizei(texture.extent(lv).y);
                    const GLsizei bw = (w + 3) / 4, bh = (h + 3) / 4;
                    // scratch holds one 4x4 block; per-format pixel strides:
                    // BC4: 1B (pitch 4), BC5: 2B (pitch 4), BC6H: 3x16F (pitch 8), BC7: 4B (pitch 16)
                    u8 scratch[16 * 8];
                    for (GLsizei by = 0; by < bh; ++by)
                        for (GLsizei bx = 0; bx < bw; ++bx)
                        {
                            const u8* blk = src + (size_t(by) * bw + bx) * bbytes;
                            switch (fmt)
                            {
                            case p4_GL_COMPRESSED_RED_RGTC1: case p4_GL_COMPRESSED_SIGNED_RED_RGTC1:
                                bcdec_bc4(blk, scratch, 4, p4_signed); break;
                            case p4_GL_COMPRESSED_RG_RGTC2: case p4_GL_COMPRESSED_SIGNED_RG_RGTC2:
                                bcdec_bc5(blk, scratch, 4, p4_signed); break;
                            case p4_GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT: case p4_GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
                                bcdec_bc6h_half(blk, scratch, 8, p4_signed); break;
                            default:
                                bcdec_bc7(blk, scratch, 16); break;
                            }
                            for (GLsizei y = 0; y < 4 && by * 4 + y < h; ++y)
                                for (GLsizei x = 0; x < 4 && bx * 4 + x < w; ++x)
                                {
                                    u8* px = dst + (size_t(by * 4 + y) * w + bx * 4 + x) * p4_bps;
                                    const size_t row = size_t(y), col = size_t(x);
                                    switch (fmt)
                                    {
                                    case p4_GL_COMPRESSED_RED_RGTC1: case p4_GL_COMPRESSED_SIGNED_RED_RGTC1:
                                        px[0] = px[1] = px[2] = scratch[row * 4 + col]; px[3] = 255;
                                        break;
                                    case p4_GL_COMPRESSED_RG_RGTC2: case p4_GL_COMPRESSED_SIGNED_RG_RGTC2:
                                        px[0] = scratch[row * 4 + col * 2]; px[1] = scratch[row * 4 + col * 2 + 1];
                                        px[2] = 0; px[3] = 255;
                                        break;
                                    case p4_GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT: case p4_GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
                                    {
                                        const unsigned short* hp = reinterpret_cast<const unsigned short*>(scratch);
                                        unsigned short* dp = reinterpret_cast<unsigned short*>(px);
                                        dp[0] = hp[row * 4 + col * 3]; dp[1] = hp[row * 4 + col * 3 + 1];
                                        dp[2] = hp[row * 4 + col * 3 + 2]; dp[3] = 0x3C00; // half 1.0
                                        break;
                                    }
                                    default:
                                        std::memcpy(px, scratch + (row * 4 + col) * 4, 4);
                                        break;
                                    }
                                }
                        }
                }
    }


    const texture_upload_unit uploadUnit(target);
    glGenTextures(1, &pTexture);
    glBindTexture(target, pTexture);

    glTexParameteri(target, GL_TEXTURE_BASE_LEVEL, 0);
    glTexParameteri(target, GL_TEXTURE_MAX_LEVEL, static_cast<GLint>(texture.levels() - 1));

#ifdef XR_PLATFORM_WEB
    const bool swapRedBlue = !gli::is_compressed(texture.format()) && gli::block_size(texture.format()) == 4
        && format.Swizzles[gli::SWIZZLE_RED] == GL_BLUE;
    xr_vector<u8> reordered;
    const auto texels = [&](size_t layer, size_t face, size_t level) -> const void*
    {
        const void* data = texture.data(layer, face, level);
        if (!swapRedBlue)
            return data;
        const size_t size = texture.size(level);
        reordered.assign(static_cast<const u8*>(data), static_cast<const u8*>(data) + size);
        for (size_t i = 0; i + 3 < size; i += 4)
            std::swap(reordered[i], reordered[i + 2]);
        return reordered.data();
    };
#else
    if (!p4_decode && gli::gl::EXTERNAL_RED != format.External) // skip for proper greyscale-alpha font textures
        glTexParameteriv(target, GL_TEXTURE_SWIZZLE_RGBA, &format.Swizzles[gli::SWIZZLE_RED]);
    // p4: decoded textures are plain RGBA — identity swizzle is correct for
    // every BCn family (BC5 keeps x/y in R/G as the *2-1 shaders expect).
    const auto texels = [&](size_t layer, size_t face, size_t level) -> const void*
    {
        if (p4_decode)
            return p4_decoded.data() + p4_offsets[(layer * texture.faces() + face) * texture.levels() + level];
        return texture.data(layer, face, level);
    };
#endif

    glm::tvec3<GLsizei> const tex_extent(texture.extent());

    GLenum err;
    switch (texture.target())
    {
    case gli::TARGET_2D:
    case gli::TARGET_CUBE:
        glTexStorage2D(target, static_cast<GLint>(texture.levels()), p4_format.Internal,
                       tex_extent.x, tex_extent.y);
        err = glGetError();
        if (err != GL_NO_ERROR)
        {
            VERIFY(err == GL_NO_ERROR);
            Msg("! OpenGL: 0x%x: Invalid 2D texture: '%s'", err, fn);
        }
        break;
    case gli::TARGET_3D:
    case gli::TARGET_CUBE_ARRAY:
        glTexStorage3D(target, static_cast<GLint>(texture.levels()), format.Internal,
                       tex_extent.x, tex_extent.y, tex_extent.z);
        err = glGetError();
        if (err != GL_NO_ERROR)
        {
            VERIFY(err == GL_NO_ERROR);
            Msg("! OpenGL: 0x%x: Invalid 3D texture: '%s'", err, fn);
        }
        break;
    default:
        NODEFAULT;
        break;
    }

    for (size_t layer = 0; layer < texture.layers(); ++layer)
    {
        for (size_t face = 0; face < texture.faces(); ++face)
        {
            for (size_t level = 0; level < texture.levels(); ++level)
            {
                glm::tvec3<GLsizei> const tex_level_extent(texture.extent(level));
                GLenum sub_target = gli::is_target_cube(texture.target())
                         ? static_cast<GLenum>(GL_TEXTURE_CUBE_MAP_POSITIVE_X + face)
                         : target;

                switch (texture.target())
                {
                case gli::TARGET_2D:
                case gli::TARGET_CUBE:
                {
                    if (gli::is_compressed(texture.format()) && !p4_decode)
                    {
                        glCompressedTexSubImage2D(sub_target, static_cast<GLint>(level),
                                    0, 0, tex_level_extent.x, tex_level_extent.y,
                                    format.Internal, static_cast<GLsizei>(texture.size(level)),
                                    texture.data(layer, face, level));
                        err = glGetError();
                        if (err != GL_NO_ERROR)
                        {
                            VERIFY(err == GL_NO_ERROR);
                            Msg("! OpenGL: 0x%x: Invalid 2D compressed subtexture: '%s'", err, fn);
                        }
                    }
                    else
                    {
                        glTexSubImage2D(sub_target, static_cast<GLint>(level),
                                    0, 0, tex_level_extent.x, tex_level_extent.y,
                                    p4_format.External, p4_format.Type,
                                    texels(layer, face, level));
                        err = glGetError();
                        if (err != GL_NO_ERROR)
                        {
                            VERIFY(err == GL_NO_ERROR);
                            Msg("! OpenGL: 0x%x: Invalid 2D subtexture: '%s'", err, fn);
                        }

                    }
                    break;
                }
                case gli::TARGET_3D:
                case gli::TARGET_CUBE_ARRAY:
                {
                    if (gli::is_compressed(texture.format()))
                    {
                        glCompressedTexSubImage3D(target, static_cast<GLint>(level),
                                    0, 0, 0, tex_level_extent.x, tex_level_extent.y, tex_level_extent.z,
                                    format.Internal, static_cast<GLsizei>(texture.size(level)),
                                    texture.data(layer, face, level));
                        err = glGetError();
                        if (err != GL_NO_ERROR)
                        {
                            VERIFY(err == GL_NO_ERROR);
                            Msg("! OpenGL: 0x%x: Invalid compressed 3D subtexture: '%s'", err, fn);
                        }
                    }
                    else
                    {
                        glTexSubImage3D(target, static_cast<GLint>(level),
                                    0, 0, 0, tex_level_extent.x, tex_level_extent.y, tex_level_extent.z,
                                    format.External, format.Type,
                                    texels(layer, face, level));
                        err = glGetError();
                        if (err != GL_NO_ERROR)
                        {
                            VERIFY(err == GL_NO_ERROR);
                            Msg("! OpenGL: 0x%x: Invalid 3D subtexture: '%s'", err, fn);
                        }
                    }
                    break;
                }
                default:
                    NODEFAULT;
                    break;
                }
            }
        }
    }

    FS.r_close(S);

    xr_strlwr(fn);
    ret_desc = target;
    ret_width = tex_extent.x;
    ret_height = tex_extent.y;
    int img_loaded_lod = is_target_cube(texture.target()) ? 0 : get_texture_load_lod(fn);
    ret_msize = calc_texture_size(img_loaded_lod, mip_cnt, img_size);
    return pTexture;
}
} // namespace xray::render::RENDER_NAMESPACE
