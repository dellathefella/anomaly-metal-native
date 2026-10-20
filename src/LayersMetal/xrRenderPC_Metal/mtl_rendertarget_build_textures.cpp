// mtl_rendertarget_build_textures.cpp — material table + jitter/noise
// textures on Metal (p5 t2). Mirror of gl_rendertarget_build_textures.cpp:
// same generated content, uploaded through the substrate (3D material table
// per z-slice; mipped noise via GenerateMipmaps).
#include "stdafx.h"
#include "mtl_rendertarget.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "Layers/xrRenderMetal/mtlRuntime.h"
#include "Layers/xrRenderMetal/mtl_dx9_format.h"

namespace xray::render::RENDER_NAMESPACE
{
static void generate_jitter(u32* dest, u32 elem_count)
{
    const int cmax = 8;
    svector<Ivector2, cmax> samples;
    while (samples.size() < elem_count * 2)
    {
        Ivector2 test;
        test.set(Random.randI(0, 256), Random.randI(0, 256));
        BOOL valid = TRUE;
        for (auto& sample : samples)
        {
            int dist = _abs(test.x - sample.x) + _abs(test.y - sample.y);
            if (dist < 32)
            {
                valid = FALSE;
                break;
            }
        }
        if (valid)
            samples.push_back(test);
    }
    for (u32 it = 0; it < elem_count; it++, dest++)
        *dest = color_rgba(samples[2 * it].x, samples[2 * it].y, samples[2 * it + 1].y, samples[2 * it + 1].x);
}

void CRenderTarget::build_textures()
{
    auto& dev = HW.MtlDev;
    std::string err;

    // Build material(s)
    {
        // Surface: RG8 volume (addr: x=dot(L,N), y=dot(L,H), z=material)
        t_material_surf = dev.NewTexture3D(TEX_material_LdotN, TEX_material_LdotH, TEX_material_Count, 1,
                                           mtlPF_RG8Unorm, /*readable*/ true);
        t_material = RImplementation.Resources->_CreateTexture(r2_material);
        t_material->surface_set(t_material_surf);
        t_material->size_set(TEX_material_LdotN, TEX_material_LdotH);

        // Fill it
        static constexpr u32 RowPitch = TEX_material_LdotN * 2;
        static constexpr u32 SlicePitch = TEX_material_LdotH * RowPitch;
        u16 pBits[TEX_material_LdotN * TEX_material_LdotH * TEX_material_Count];
        for (u32 slice = 0; slice < TEX_material_Count; slice++)
        {
            for (u32 y = 0; y < TEX_material_LdotH; y++)
            {
                for (u32 x = 0; x < TEX_material_LdotN; x++)
                {
                    u16* p = (u16*)((u8*)(pBits)+slice * SlicePitch +
                        y * RowPitch + x * 2);
                    float ld = float(x) / float(TEX_material_LdotN - 1);
                    float ls = float(y) / float(TEX_material_LdotH - 1) + EPS_S;
                    ls *= powf(ld, 1 / 32.f);
                    float fd, fs;

                    switch (slice)
                    {
                    case 0:
                    { // looks like OrenNayar
                        fd = powf(ld, 0.75f); // 0.75
                        fs = powf(ls, 16.f) * .5f;
                    }
                    break;
                    case 1:
                    { // looks like Blinn
                        fd = powf(ld, 0.90f); // 0.90
                        fs = powf(ls, 24.f);
                    }
                    break;
                    case 2:
                    { // looks like Phong
                        fd = ld; // 1.0
                        fs = powf(ls * 1.01f, 128.f);
                    }
                    break;
                    case 3:
                    { // looks like Metal
                        float s0 = _abs(1 - _abs(0.05f * _sin(33.f * ld) + ld - ls));
                        float s1 = _abs(1 - _abs(0.05f * _cos(33.f * ld * ls) + ld - ls));
                        float s2 = _abs(1 - _abs(ld - ls));
                        fd = ld; // 1.0
                        fs = powf(_max(_max(s0, s1), s2), 24.f);
                        fs *= powf(ld, 1 / 7.f);
                    }
                    break;
                    default: fd = fs = 0;
                    }
                    s32 _d = clampr(iFloor(fd * 255.5f), 0, 255);
                    s32 _s = clampr(iFloor(fs * 255.5f), 0, 255);
                    if (y == (TEX_material_LdotH - 1) && x == (TEX_material_LdotN - 1))
                    {
                        _d = 255;
                        _s = 255;
                    }
                    *p = u16(_s * 256 + _d);
                }
            }
        }
        // per-z-slice upload (substrate regions are depth-1)
        for (u32 z = 0; z < TEX_material_Count; ++z)
            if (!dev.WriteTextureRegion(t_material_surf, z, 0, (u8*)pBits + z * SlicePitch,
                    TEX_material_LdotN, TEX_material_LdotH, 2, err))
                Msg("! Metal: material table upload failed (slice %u): %s", z, err.c_str());
    }

    // Build noise table
    if (true)
    {
        static const int sampleSize = 4;
        u32 tempData[TEX_jitter_count][TEX_jitter * TEX_jitter];

        // Surfaces
        for (u32 it1 = 0; it1 < TEX_jitter_count - 1; it1++)
        {
            string_path name;
            xr_sprintf(name, "%s%d", r2_jitter, it1);
            t_noise_surf[it1] = dev.NewTexture2D(TEX_jitter, TEX_jitter, 1, mtlPF_RGBA8Unorm,
                                                 /*fbOnly*/ false, /*readable*/ true);
            t_noise[it1] = RImplementation.Resources->_CreateTexture(name);
            t_noise[it1]->surface_set(t_noise_surf[it1]);
            t_noise[it1]->size_set(TEX_jitter, TEX_jitter);
        }

        // Fill it,
        static const u32 Pitch = TEX_jitter * sampleSize;
        for (u32 y = 0; y < TEX_jitter; y++)
        {
            for (u32 x = 0; x < TEX_jitter; x++)
            {
                u32 data[TEX_jitter_count - 1];
                generate_jitter(data, TEX_jitter_count - 1);
                for (u32 it2 = 0; it2 < TEX_jitter_count - 1; it2++)
                {
                    u32* p = (u32*)((u8*)(tempData[it2]) + y * Pitch + x * 4);
                    *p = data[it2];
                }
            }
        }
        u32 it3 = 0;
        while (it3 < TEX_jitter_count - 1)
        {
            dev.WriteTextureRegion(t_noise_surf[it3], 0, 0, tempData[it3], TEX_jitter, TEX_jitter, 4, err);
            it3++;
        }

        float tempDataHBAO[TEX_jitter * TEX_jitter * 4];

        // generate HBAO jitter texture (last)
        int it = TEX_jitter_count - 1;
        string_path name;
        xr_sprintf(name, "%s%d", r2_jitter, it);
        t_noise_surf[it] = dev.NewTexture2D(TEX_jitter, TEX_jitter, 1, mtlPF_RGBA32Float,
                                            /*fbOnly*/ false, /*readable*/ true);
        t_noise[it] = RImplementation.Resources->_CreateTexture(name);
        t_noise[it]->surface_set(t_noise_surf[it]);
        t_noise[it]->size_set(TEX_jitter, TEX_jitter);

        // Fill it,
        static const int HBAOPitch = TEX_jitter * sampleSize * sizeof(float);
        for (u32 y = 0; y < TEX_jitter; y++)
        {
            for (u32 x = 0; x < TEX_jitter; x++)
            {
                float numDir = 1.0f;
                switch (ps_r_ssao)
                {
                case 1: numDir = 4.0f; break;
                case 2: numDir = 6.0f; break;
                case 3: numDir = 8.0f; break;
                }
                float angle = 2 * PI * Random.randF(0.0f, 1.0f) / numDir;
                float dist = Random.randF(0.0f, 1.0f);

                float* p =
                    (float*)((u8*)(tempDataHBAO)+y * HBAOPitch + x * 4 * sizeof(float));
                *p = (float)_cos(angle);
                *(p + 1) = (float)_sin(angle);
                *(p + 2) = (float)dist;
                *(p + 3) = 0;
            }
        }
        dev.WriteTextureRegion(t_noise_surf[it], 0, 0, tempDataHBAO, TEX_jitter, TEX_jitter, 16, err);

        //	Create noise mipped
        {
            // full mip chain (mips=0), generated below
            t_noise_surf_mipped = dev.NewTexture2D(TEX_jitter, TEX_jitter, 0, mtlPF_RGBA8Unorm,
                                                   /*fbOnly*/ false, /*readable*/ true);
            t_noise_mipped = RImplementation.Resources->_CreateTexture(r2_jitter_mipped);
            t_noise_mipped->surface_set(t_noise_surf_mipped);
            t_noise_mipped->size_set(TEX_jitter, TEX_jitter);

            dev.WriteTextureRegion(t_noise_surf_mipped, 0, 0, tempData[0], TEX_jitter, TEX_jitter, 4, err);
            dev.GenerateMipmaps(MtlCurrentCommandBuffer(), t_noise_surf_mipped);
        }
    }
}
} // namespace xray::render::RENDER_NAMESPACE
