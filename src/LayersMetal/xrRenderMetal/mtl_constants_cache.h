#pragma once
// p5 Metal device layer — R_constants (mirror of glr_constants_cache.h).
//
// GL uploads each constant immediately (glUniform*). Metal constants live in
// a cbuffer image, so the contract becomes:
//   set_Constants(ctable)  → select the staging block for the pass
//   set()/seta()           → memcpy value bytes into the staging block
//   draw                   → snapshot the staging block into the per-frame
//                            buffer ring and bind it for VS and PS.
// Per-draw snapshots avoid the CPU-write-after-encode race (the GPU may read
// the ring chunk long after the CPU moved on; see metal_devicetest notes).
//
// Offsets/sizes in R_constant_load were filled by R_constant_table::parse
// from SPIRV-Cross reflection (rmtl_shaders.cpp). Engine-side value sizes are
// clamped to the shader-side size.

#include "mtlRuntime.h"

namespace xray::render::RENDER_NAMESPACE
{
// stage ids for MtlConstWrite
enum mtl_const_stage : uint32_t
{
    mtl_cs_vs = 0,
    mtl_cs_ps = 1,
    mtl_cs_gs = 2,
    mtl_cs_pp = 3 // writes both images (no Metal script uses RC_dest_all today)
};

class ECORE_API R_constants
{
private:
    ICF static void write(R_constant* C, const R_constant_load& L, uint32_t stage, const void* data, u32 engineBytes)
    {
        if (L.offset == u32(-1))
            return; // name absent in this stage — silently ignored (matches GL no-location behavior)
        MtlConstWrite(stage, L.offset, L.size, data, engineBytes < L.size ? engineBytes : L.size);
    }

    // fp, non-array versions
    ICF void set(R_constant* C, const R_constant_load& L, uint32_t stage, const Fmatrix& A)
    {
        VERIFY(RC_float == C->type);
        u32 bytes;
        switch (L.cls)
        {
        case RC_2x4: bytes = 2 * sizeof(Fvector4); break; // first two rows
        case RC_3x4: bytes = 3 * sizeof(Fvector4); break;
        case RC_4x4: bytes = 4 * sizeof(Fvector4); break;
        default:
#ifdef DEBUG
			Debug.fatal(DEBUG_INFO, "Invalid constant run-time-type for '%s'", C->name.c_str());
#else
            NODEFAULT;
#endif
            bytes = 0;
        }
        write(C, L, stage, &A, bytes);
    }

    ICF void set(R_constant* C, const R_constant_load& L, uint32_t stage, const Fvector4& A)
    {
        VERIFY(RC_float == C->type);
        u32 bytes;
        switch (L.cls)
        {
        case RC_1x2: bytes = 2 * sizeof(float); break;
        case RC_1x3: bytes = 3 * sizeof(float); break;
        case RC_1x4: bytes = 4 * sizeof(float); break;
        default:
#ifdef DEBUG
			Debug.fatal(DEBUG_INFO, "Invalid constant run-time-type for '%s'", C->name.c_str());
#else
            NODEFAULT;
#endif
            bytes = 0;
        }
        write(C, L, stage, &A, bytes);
    }

    ICF void set(R_constant* C, const R_constant_load& L, uint32_t stage, float x, float y, float z, float w)
    {
        VERIFY(RC_float == C->type);
        const Fvector4 v{ x, y, z, w };
        u32 bytes;
        switch (L.cls)
        {
        case RC_1x2: bytes = 2 * sizeof(float); break;
        case RC_1x3: bytes = 3 * sizeof(float); break;
        case RC_1x4: bytes = 4 * sizeof(float); break;
        default:
#ifdef DEBUG
			Debug.fatal(DEBUG_INFO, "Invalid constant run-time-type for '%s'", C->name.c_str());
#else
            NODEFAULT;
#endif
            bytes = 0;
        }
        write(C, L, stage, &v, bytes);
    }

    ICF void set(R_constant* C, const R_constant_load& L, uint32_t stage, float A)
    {
        VERIFY(RC_float == C->type);
        VERIFY(RC_1x1 == L.cls);
        write(C, L, stage, &A, sizeof(A));
    }

    ICF void set(R_constant* C, const R_constant_load& L, uint32_t stage, int A)
    {
        VERIFY(RC_int == C->type);
        VERIFY(RC_1x1 == L.cls);
        write(C, L, stage, &A, sizeof(A));
    }

public:
    // fp, non-array versions
    ICF void set(R_constant* C, const Fmatrix& A)
    {
        if (C->destination & RC_dest_vertex) set(C, C->vs, mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, C->ps, mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, C->gs, mtl_cs_gs, A);
        if (C->destination & RC_dest_all) { set(C, C->pp, mtl_cs_vs, A); set(C, C->pp, mtl_cs_ps, A); }
    }

    ICF void set(R_constant* C, const Fvector4& A)
    {
        if (C->destination & RC_dest_vertex) set(C, C->vs, mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, C->ps, mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, C->gs, mtl_cs_gs, A);
        if (C->destination & RC_dest_all) { set(C, C->pp, mtl_cs_vs, A); set(C, C->pp, mtl_cs_ps, A); }
    }

    ICF void set(R_constant* C, float x, float y, float z, float w)
    {
        if (C->destination & RC_dest_vertex) set(C, C->vs, mtl_cs_vs, x, y, z, w);
        if (C->destination & RC_dest_pixel) set(C, C->ps, mtl_cs_ps, x, y, z, w);
        if (C->destination & RC_dest_geometry) set(C, C->gs, mtl_cs_gs, x, y, z, w);
        if (C->destination & RC_dest_all) { set(C, C->pp, mtl_cs_vs, x, y, z, w); set(C, C->pp, mtl_cs_ps, x, y, z, w); }
    }

    // scalars, non-array versions
    ICF void set(R_constant* C, float A)
    {
        if (C->destination & RC_dest_vertex) set(C, C->vs, mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, C->ps, mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, C->gs, mtl_cs_gs, A);
        if (C->destination & RC_dest_all) { set(C, C->pp, mtl_cs_vs, A); set(C, C->pp, mtl_cs_ps, A); }
    }

    ICF void set(R_constant* C, int A)
    {
        if (C->destination & RC_dest_vertex) set(C, C->vs, mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, C->ps, mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, C->gs, mtl_cs_gs, A);
        if (C->destination & RC_dest_all) { set(C, C->pp, mtl_cs_vs, A); set(C, C->pp, mtl_cs_ps, A); }
    }

    // fp, array versions — element offset via reflection stride
    ICF void seta(R_constant* C, u32 e, const Fmatrix& A)
    {
        if (C->destination & RC_dest_vertex) set(C, element_load(C->vs, e), mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, element_load(C->ps, e), mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, element_load(C->gs, e), mtl_cs_gs, A);
    }

    ICF void seta(R_constant* C, u32 e, const Fvector4& A)
    {
        if (C->destination & RC_dest_vertex) set(C, element_load(C->vs, e), mtl_cs_vs, A);
        if (C->destination & RC_dest_pixel) set(C, element_load(C->ps, e), mtl_cs_ps, A);
        if (C->destination & RC_dest_geometry) set(C, element_load(C->gs, e), mtl_cs_gs, A);
    }

    ICF void seta(R_constant* C, u32 e, float x, float y, float z, float w)
    {
        if (C->destination & RC_dest_vertex) set(C, element_load(C->vs, e), mtl_cs_vs, x, y, z, w);
        if (C->destination & RC_dest_pixel) set(C, element_load(C->ps, e), mtl_cs_ps, x, y, z, w);
        if (C->destination & RC_dest_geometry) set(C, element_load(C->gs, e), mtl_cs_gs, x, y, z, w);
    }

    // Snapshot+upload happens at draw time (mtlRuntime.mm); nothing to do here.
    ICF void flush() { }

private:
    ICF static R_constant_load element_load(const R_constant_load& base, u32 e)
    {
        R_constant_load L = base;
        if (L.offset != u32(-1))
            L.offset += e * (L.stride ? L.stride : L.size);
        return L;
    }
};
} // namespace xray::render::RENDER_NAMESPACE
