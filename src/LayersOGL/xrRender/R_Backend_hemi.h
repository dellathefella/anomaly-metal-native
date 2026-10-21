#pragma once

#include "Include/xrRender/RenderVisual.h" //--#SM+#--

namespace xray::render::RENDER_NAMESPACE
{
class ECORE_API R_hemi
{
public:
    R_constant* c_pos_faces;
    R_constant* c_neg_faces;
    R_constant* c_material;
    R_constant* c_camo_data; //--#SM+#--
    R_constant* c_custom_data; //--#SM+#--
    R_constant* c_entity_data; //--#SM+#--

    // value storage for reemit() (colors are set once per level)
    Fvector m_pos_faces;
    Fvector m_neg_faces;
    Fvector4 m_material;
    bool m_has_material;

public:
    explicit R_hemi(CBackend& cmd_list_in);
    void unmap();

    void set_c_pos_faces(R_constant* C) { c_pos_faces = C; }
    void set_c_neg_faces(R_constant* C) { c_neg_faces = C; }
    void set_c_material(R_constant* C) { c_material = C; }
    void set_pos_faces(float posx, float posy, float posz);
    void set_neg_faces(float negx, float negy, float negz);
    void set_material(float x, float y, float z, float w);
    // Metal parity hook: hemi colors are set once per level; the Metal backend
    // re-applies them after each shader switch (its staging block is per-pass).
    void reemit();

    void c_update(IRenderVisual* pVisual); //--#SM+#--

    CBackend& cmd_list;
};
} // namespace xray::render::RENDER_NAMESPACE
