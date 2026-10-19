#pragma once

namespace xray::render::RENDER_NAMESPACE
{
struct light_indirect
{
    Fvector P;
    Fvector D;
    float E;
    IRender_Sector* S; // p4: monolith sector handle
};
} // namespace xray::render::RENDER_NAMESPACE
