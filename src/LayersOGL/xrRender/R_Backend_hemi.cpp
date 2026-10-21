#include "stdafx.h"
#pragma hdrstop

#include "R_Backend_hemi.h"

namespace xray::render::RENDER_NAMESPACE
{
R_hemi::R_hemi(CBackend& cmd_list_in) : cmd_list(cmd_list_in)
{
    unmap();
    m_pos_faces.set(0, 0, 0);
    m_neg_faces.set(0, 0, 0);
    m_material.set(0, 0, 0, 0);
    m_has_material = false;
}
void R_hemi::unmap()
{
    c_pos_faces = nullptr;
    c_neg_faces = nullptr;
    c_material = nullptr;
    c_camo_data = nullptr; //--#SM+#--
    c_custom_data = nullptr; //--#SM+#--
    c_entity_data = nullptr; //--#SM+#--
}

void R_hemi::set_pos_faces(float posx, float posy, float posz)
{
    m_pos_faces.set(posx, posy, posz);
    if (c_pos_faces)
        cmd_list.set_c(c_pos_faces, posx, posy, posz, 0.f);
}
void R_hemi::set_neg_faces(float negx, float negy, float negz)
{
    m_neg_faces.set(negx, negy, negz);
    if (c_neg_faces)
        cmd_list.set_c(c_neg_faces, negx, negy, negz, 0.f);
}

void R_hemi::set_material(float x, float y, float z, float w)
{
    m_material.set(x, y, z, w);
    m_has_material = true;
    if (c_material)
        cmd_list.set_c(c_material, x, y, z, w);
}

void R_hemi::reemit()
{
    if (c_pos_faces)
        cmd_list.set_c(c_pos_faces, m_pos_faces.x, m_pos_faces.y, m_pos_faces.z, 0.f);
    if (c_neg_faces)
        cmd_list.set_c(c_neg_faces, m_neg_faces.x, m_neg_faces.y, m_neg_faces.z, 0.f);
    if (c_material && m_has_material)
        cmd_list.set_c(c_material, m_material.x, m_material.y, m_material.z, m_material.w);
}

// Обновляем значения в шейдерных константах //--#SM+#-- //SM_TODO Переместить
void R_hemi::c_update(IRenderVisual* pVisual)
{
    // p4: dev reads per-object shader data through vis_data::obj_data
    // (vis_object_data), an engine extension the monolith 1.5.3 vis_data does
    // not carry. The graph renderer's c_update call sites are already
    // commented out, so the body is inert here.
    (void)pVisual;
}
} // namespace xray::render::RENDER_NAMESPACE
