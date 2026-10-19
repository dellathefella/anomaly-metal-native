#pragma once

#include "Include/xrRender/RenderFactory.h"

#define RENDER_FACTORY_DECLARE(Class)\
    virtual I##Class* Create##Class();\
    virtual void Destroy##Class(I##Class* pObject);

namespace xray::render::RENDER_NAMESPACE
{
class dxRenderFactory // p4: monolith boundary has no IRenderFactory (all-commented)
{
public: // p4: the monolith dxRenderFactory bridge delegates to these directly
#ifndef _EDITOR
    RENDER_FACTORY_DECLARE(UISequenceVideoItem)
    RENDER_FACTORY_DECLARE(UIShader)
    RENDER_FACTORY_DECLARE(StatGraphRender)
#ifdef DEBUG
    RENDER_FACTORY_DECLARE(ObjectSpaceRender)
#endif // DEBUG
    RENDER_FACTORY_DECLARE(WallMarkArray)
#endif // _EDITOR

#ifndef _EDITOR
    RENDER_FACTORY_DECLARE(FlareRender)
    RENDER_FACTORY_DECLARE(ThunderboltRender)
    RENDER_FACTORY_DECLARE(ThunderboltDescRender)
    RENDER_FACTORY_DECLARE(RainRender)
    RENDER_FACTORY_DECLARE(LensFlareRender)
    // p4: ImGuiRender factory entries dropped (imgui overlay not ported)
    RENDER_FACTORY_DECLARE(EnvironmentRender)
    RENDER_FACTORY_DECLARE(EnvDescriptorRender)
#endif
    RENDER_FACTORY_DECLARE(FontRender)
};

extern dxRenderFactory RenderFactoryImpl;
} // namespace xray::render::RENDER_NAMESPACE
