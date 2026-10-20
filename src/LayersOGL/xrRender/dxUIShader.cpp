#include "stdafx.h"
#include "dxUIShader.h"

namespace xray::render::RENDER_NAMESPACE
{
void dxUIShader::Copy(IUIShader& _in) { *this = *((dxUIShader*)&_in); }
void dxUIShader::create(LPCSTR sh, LPCSTR tex)
{
    // p4: UI shaders came up un-inited (black menu) — trace creation.
    static int s_p4_uicreate = 0;
    hShader.create(sh, tex);
    if (s_p4_uicreate < 40 || !hShader._get())
        Msg("* p4: dxUIShader::create #%d '%s' tex='%s' -> %s", s_p4_uicreate++, sh ? sh : "?",
            tex ? tex : "?", hShader._get() ? "ok" : "NULL");
}
void dxUIShader::destroy() { hShader.destroy(); }

bool dxUIShader::operator==(const IUIShader& other) const
{
    return hShader == static_cast<const dxUIShader&>(other).hShader;
}

CTexture* dxUIShader::GetBaseTexture() const
{
    if (!hShader)
        return nullptr;

    const SPass& pass = *hShader->E[0]->passes[0];
    if (!pass.T)
        return nullptr;

    const STextureList& textures = *pass.T;
    if (textures.empty())
        return nullptr;

    const R_constant* sbase = pass.constants->get(baseTexture)._get();

    return textures[sbase ? sbase->samp.index : 0].second._get();
}

xrImTextureData dxUIShader::GetImGuiTextureId()
{
    const auto texture = GetBaseTexture();
    if (!texture)
        return {};

    return
    {
        texture->GetImTextureID(),
        {
            (float)texture->get_Width(),
            (float)texture->get_Height()
        }
    };
}

bool dxUIShader::GetBaseTextureResolution(Fvector2& res)
{
    const auto texture = GetBaseTexture();
    if (!texture)
    {
        res = {};
        return false;
    }

    res = { float(texture->get_Width()), float(texture->get_Height()) };
    return true;
}
} // namespace xray::render::RENDER_NAMESPACE
