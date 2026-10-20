// mtlr_constants.cpp — R_constant_table::parse for Metal (mirror of
// glr_constants.cpp). Constant placement comes from SPIRV-Cross reflection:
// each uniform carries its byte offset/size in the stage's $Globals image
// (mtl_constants_cache.h writes value bytes straight into the staging block).
//
// Sampler resources become RC_dest_sampler constants whose samp.index is the
// DX9 stage (the translator emits t/s register bindings == DX9 stages, so the
// reflected sampler binding is the stage the blender's r_Sampler/r_texture
// path expects — see CBlender_Compile::SampledImage).
#include "stdafx.h"
#pragma hdrstop

#include "Layers/xrRender/r_constants.h"
#include "Layers/xrRenderMetal/mtlShader.h"

namespace xray::render::RENDER_NAMESPACE
{
static class cl_sampler : public R_constant_setup
{
    void setup(CBackend& /*cmd_list*/, R_constant* /*C*/) override
    {
        // Metal binds textures/samplers per-draw from the stage table +
        // shader reflection (mtlRuntime.mm); no per-constant upload exists.
    }
} binder_sampler;

BOOL R_constant_table::parse(void* _desc, u32 destination)
{
    const auto* refl = static_cast<const MtlStageRefl*>(_desc);

    for (const auto& u : refl->uniforms)
    {
        pcstr name = u.name.c_str();

        u16 type = RC_float;
        if (u.baseType == 1)
            type = RC_int;
        if (u.baseType == 2)
            type = RC_bool;

        // class from element shape (row-major -Zpr: rows = HLSL rows,
        // cols = HLSL columns; RC_<rows>x<cols>)
        u16 r_type = u16(-1);
        if (u.cols == 1)
        {
            switch (u.rows)
            {
            case 1: r_type = RC_1x1; break;
            case 2: r_type = RC_1x2; break;
            case 3: r_type = RC_1x3; break;
            case 4: r_type = RC_1x4; break;
            default: break;
            }
        }
        else if (u.rows == 4 && (u.cols == 2 || u.cols == 3 || u.cols == 4))
        {
            // float2x4/3x4/4x4 (row-major float4 rows)
            r_type = u.cols == 2 ? RC_2x4 : (u.cols == 3 ? RC_3x4 : RC_4x4);
        }
        else if (u.rows == 2 && u.cols == 4)
        {
            r_type = RC_2x4; // float4x2 declared column-style — rare, treat as 2-row
        }
        if (r_type == u16(-1))
        {
            Msg("! Metal constant parse: unsupported shape for '%s' (rows=%d cols=%d), skipped",
                name, u.rows, u.cols);
            continue;
        }

        // We have determined all valuable info, search if constant already created
        ref_constant C = get(name);
        if (!C)
        {
            C = table.emplace_back(xr_new<R_constant>());
            C->name = name;
            C->destination = destination;
            C->type = type;
            R_constant_load& L = C->get_load(destination);
            L.index = static_cast<u16>(&u - refl->uniforms.data());
            L.cls = r_type;
            L.offset = u.offset;
            L.size = u.elements > 1 ? u.stride : u.size; // element size for seta paths
            L.stride = u.stride;
        }
        else
        {
            C->destination |= destination;
            VERIFY(C->type == type);
            R_constant_load& L = C->get_load(destination);
            L.index = static_cast<u16>(&u - refl->uniforms.data());
            L.cls = r_type;
            L.offset = u.offset;
            L.size = u.elements > 1 ? u.stride : u.size;
            L.stride = u.stride;
        }
    }

    // --- samplers ----------------------------------------------------------
    for (const auto& r : refl->resources)
    {
        if (r.isSamplerOnly || r.samplerSlot == UINT32_MAX)
            continue;
        // ***Register sampler*** (mirrors the GL sampler branch; the DX9
        // stage == the reflected sampler binding).
        pcstr name = r.name.c_str();
        const u16 r_index = static_cast<u16>(r.samplerSlot);

        ref_constant C = get(name);
        if (!C)
        {
            C = table.emplace_back(xr_new<R_constant>());
            C->name = name;
            C->destination = RC_dest_sampler;
            C->type = RC_sampler;
            C->handler = &binder_sampler;
            R_constant_load& L = C->samp;
            L.index = r_index;
            L.cls = RC_sampler;
            L.offset = 0;
            L.size = 0;
            L.stride = 0;
        }
        else
        {
            R_ASSERT(C->destination & RC_dest_sampler);
            R_ASSERT(C->type == RC_sampler);
            R_ASSERT(C->handler == &binder_sampler);
            R_constant_load& L = C->samp;
            R_ASSERT(L.index == r_index);
            R_ASSERT(L.cls == RC_sampler);
        }
    }

    sort(table.begin(), table.end(), [](const ref_constant& C1, const ref_constant& C2)
    {
        return xr_strcmp(C1->name, C2->name) < 0;
    });

    return TRUE;
}
} // namespace xray::render::RENDER_NAMESPACE
