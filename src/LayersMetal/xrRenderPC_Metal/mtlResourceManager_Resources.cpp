// mtlResourceManager_Resources.cpp — pass/decl/PP/VS/PS creation for Metal
// (mirror of glResourceManager_Resources.cpp). Passes pair their compiled VS
// and PS into an MtlShaderPair (SPP::pp); the MTLPipelineState is derived
// lazily by the pass manager at draw time.
#include "stdafx.h"
#pragma hdrstop

#include "Layers/xrRender/ResourceManager.h"
#include "Layers/xrRender/tss.h"
#include "Layers/xrRender/Blender.h"
#include "Layers/xrRender/Blender_Recorder.h"
#include "Layers/xrRender/BufferUtils.h"
#include "Layers/xrRender/ShaderResourceTraits.h"
#include "Layers/xrRenderMetal/mtlShader.h"

namespace xray::render::RENDER_NAMESPACE
{
namespace
{
// The ported stub_notransform_t VS emits exactly TEXCOORD0 (float2) then
// COLOR (float4). PS input signatures beyond that need a synthesized FFP VS
// (DXC assigns interpolant locations by declaration order, so a fixed stub
// can never match e.g. bloom's four TEXCOORDs).
bool StubVSMatches(const std::vector<MtlStageRefl::InputAttr>& in)
{
    auto starts = [](const std::string& s, cpcstr p)
    {
        return s.size() >= xr_strlen(p) && 0 == s.compare(0, xr_strlen(p), p);
    };
    if (in.size() > 2)
        return false;
    if (!in.empty() && (!starts(in[0].semantic, "TEXCOORD") || in[0].components > 2))
        return false;
    if (in.size() == 2 && (!starts(in[1].semantic, "COLOR") || in[1].components != 4))
        return false;
    return true;
}
} // namespace
//--------------------------------------------------------------------------------------------------------------

SPass* CResourceManager::_CreatePass(const SPass& proto)
{
    for (SPass* pass : v_passes)
        if (pass->equal(proto))
            return pass;

    SPass* P = v_passes.emplace_back(xr_new<SPass>());
    P->dwFlags |= xr_resource_flagged::RF_REGISTERED;
    P->state = proto.state;
    P->ps = proto.ps;
    P->vs = proto.vs;
    P->gs = proto.gs;
    P->pp = proto.pp;
    P->constants = proto.constants;
    P->T = proto.T;
#ifdef _EDITOR
    P->M = proto.M;
#endif
    P->C = proto.C;

    return P;
}

//--------------------------------------------------------------------------------------------------------------

SDeclaration* CResourceManager::_CreateDecl(const D3DVERTEXELEMENT9* dcl)
{
    // Search equal code
    for (SDeclaration* D : v_declarations)
    {
        if (!D->dcl_code.empty() && dcl_equal(dcl, &D->dcl_code.front()))
            return D;
    }

    SDeclaration* D = v_declarations.emplace_back(xr_new<SDeclaration>());
    // Metal: no eager MTLVertexDescriptor — the pass manager derives it per
    // draw from dcl_code + the bound VS's [[attribute]] reflection.
    D->dcl = nullptr;

    u32 dcl_size = GetDeclLength(dcl) + 1;
    D->dcl_code.assign(dcl, dcl + dcl_size);
    ConvertVertexDeclaration(dcl, D);
    D->dwFlags |= xr_resource_flagged::RF_REGISTERED;

    return D;
}

//--------------------------------------------------------------------------------------------------------------

SPP* CResourceManager::_CreatePP(pcstr vs, pcstr ps, pcstr gs, pcstr hs, pcstr ds)
{
    pcstr skinning{}, samples{};
    switch (RImplementation.m_skinning)
    {
    case -1: skinning = "";   break;
    case  0: skinning = "_0"; break;
    case  1: skinning = "_1"; break;
    case  2: skinning = "_2"; break;
    case  3: skinning = "_3"; break;
    case  4: skinning = "_4"; break;
    default: NODEFAULT;
    }
    switch (RImplementation.m_MSAASample)
    {
    case -1: samples = "";   break;
    case  0: samples = "_0"; break;
    case  1: samples = "_1"; break;
    case  2: samples = "_2"; break;
    case  3: samples = "_3"; break;
    case  4: samples = "_4"; break;
    case  5: samples = "_5"; break;
    case  6: samples = "_6"; break;
    case  7: samples = "_7"; break;
    default: NODEFAULT;
    }

    string256 name{};
    strconcat(name, vs, skinning, "|", ps, samples, "|", gs/*, "|", hs, "|", ds*/); // XXX: Tesselation

    const auto iterator = m_pp.find(name);

    if (iterator != m_pp.end())
        return iterator->second;

    SPP* pp = xr_new<SPP>();

    pp->dwFlags |= xr_resource_flagged::RF_REGISTERED;
    m_pp.emplace(pp->set_name(name), pp);

    return pp;
}

bool CResourceManager::_LinkPP(SPass& pass)
{
    auto& pp = *pass.pp;
    if (pp.pp)
        return true;

    if (!pass.ps || !pass.ps->sh)
    {
        // DX9 null-PS pass (shadow_direct_model_*|null|null): depth-only
        // rasterization. Metal allows a nil fragment function; the PSO gets
        // no color attachments (the engine binds only a z-buffer here).
        if (!strstr(pp.cName.c_str(), "|null"))
        {
            Msg("! Metal _LinkPP: pass '%s' has no pixel shader (ps=%p) and is not a null-PS pass",
                pp.cName.c_str(), (void*)pass.ps._get());
            return false;
        }
        Msg("- Metal _LinkPP: depth-only pass '%s'", pp.cName.c_str());
    }
    if (!pass.vs || !pass.vs->sh)
    {
        // FFP pass (shader:begin("null", ...)). DX9 fed these through the
        // fixed-function pipeline with the engine's 2D ortho: vertices are
        // SCREEN-PIXEL space. Emulate with the ported stub_notransform_t VS
        // (pixel -> clip + Tex0 + Color); plain stub_notransform (pass-
        // through) would put every UI quad off-screen.
        SVS* ffp = RImplementation.Resources->_CreateVS("stub_notransform_t");
        if (!ffp || !ffp->sh)
        {
            Msg("! Metal _LinkPP: FFP pass '%s' — stub_notransform_t VS unavailable",
                pp.cName.c_str());
            return false;
        }
        Msg("- Metal _LinkPP: FFP pass '%s' -> stub_notransform_t VS", pp.cName.c_str());
        pass.vs = ffp;
    }

    // p5: DX9 fixed-function pass ("null" VS — _CreateVS already substituted
    // the single-interpolant stub). When the PS interpolant signature goes
    // beyond the stub's outputs, synthesize a per-pass FFP VS mirroring the
    // PS inputs exactly (true DX9 FFP pass-through emulation; fixes bloom /
    // AA-combine / rain / deferred passes that the stub can never match).
    if (pass.vs && pass.vs->sh && !strncasecmp(pp.cName.c_str(), "null", 4) && pass.ps && pass.ps->sh)
    {
        auto* psr = static_cast<const MtlStageRefl*>(pass.ps->sh);
        if (psr && !StubVSMatches(psr->inputs))
        {
            std::string ffpErr;
            MtlStageRefl* ffpRefl = MtlBuildFfpVertexStage(psr->inputs, ffpErr);
            if (ffpRefl)
            {
                string256 ffpName;
                xr_sprintf(ffpName, "ffpvs:%s", pp.cName.c_str());
                SVS* ffp = xr_new<SVS>();
                ffp->dwFlags |= xr_resource_flagged::RF_REGISTERED;
                m_vs.insert(mk_pair(ffp->set_name(ffpName), ffp));
                ffp->sh = ffpRefl;
                ffp->constants.parse(ffpRefl, ShaderTypeTraits<SVS>::GetShaderDest());
                pass.vs = ffp;
                Msg("- Metal _LinkPP: FFP pass '%s' -> synthesized VS (%u interpolants)",
                    pp.cName.c_str(), (unsigned)psr->inputs.size());
            }
            else
                Msg("! Metal _LinkPP: FFP VS synthesis failed for '%s': %s (stub fallback)", pp.cName.c_str(),
                    ffpErr.c_str());
        }
    }

    // p5: DX9 matched interpolants by semantic name; DXC's declaration-order
    // locns diverge between the two stages of real pairs (deffer_detail_w_flat
    // vs + deffer_base_aref_flat.ps etc.) — align the pair's MSL and recompile
    // on the device before assembling the pipeline pair.
    const auto* vsR = static_cast<const MtlStageRefl*>(pass.vs->sh);
    const auto* psR = pass.ps && pass.ps->sh ? static_cast<const MtlStageRefl*>(pass.ps->sh) : nullptr;
    MtlStageRefl alVs, alPs;
    bool v2pAligned = false;
    // p5 diag: A/B kill switch for the V2P aligner (regression hunts).
    static const bool s_v2p_off = getenv("MTL_NO_V2P") != nullptr;
    if (vsR && psR && !s_v2p_off)
    {
        std::string v2pErr;
        v2pAligned = MtlAlignV2PStages(*vsR, *psR, alVs, alPs, v2pErr);
        if (!v2pAligned && !v2pErr.empty())
            Msg("! Metal _LinkPP: V2P align failed for '%s': %s", pp.cName.c_str(), v2pErr.c_str());
    }

    auto* pair = MtlMakeShaderPair(pp.cName.c_str());
    // Stage reflections were produced by shader_compile (rmtl_shaders.cpp);
    // the pair borrows the arena-owned MTLFunctions and copies reflection.
    if (v2pAligned)
    {
        pair->vs = std::move(alVs);
        pair->ps = std::move(alPs);
    }
    else
        pair->vs = *static_cast<const MtlStageRefl*>(pass.vs->sh);
    if (pass.ps && pass.ps->sh)
    {
        if (!v2pAligned)
            pair->ps = *static_cast<const MtlStageRefl*>(pass.ps->sh);
    }
    else
        pair->depthOnly = true;
    pp.pp = pair;

    // RC_dest_all constants: no Metal script uses them (per-stage tables are
    // merged by the blender recorder), so pp.constants stays empty on purpose.

    pass.ps = nullptr;
    pass.vs = nullptr;
    pass.gs = nullptr;

    return pp.pp != nullptr;
}

void CResourceManager::_DeletePP(const SPP* pp)
{
    if (0 == (pp->dwFlags & xr_resource_flagged::RF_REGISTERED))
        return;

    const pstr N = const_cast<pstr>(pp->cName.c_str());
    auto iterator = m_pp.find(N);

    if (iterator != m_pp.end())
    {
        m_pp.erase(iterator);
        return;
    }

#ifndef MASTER_GOLD
    Msg("! ERROR: Failed to find program pipeline '%s'", pp->cName.c_str());
#endif
}

//--------------------------------------------------------------------------------------------------------------

SVS* CResourceManager::_CreateVS(cpcstr shader, u32 flags /*= 0*/)
{
    const char* eff = shader;
    if (shader && 0 == xr_stricmp(shader, "null"))
    {
        // FFP VS (shader:begin("null",...), PassEnd fallback): Metal has no
        // fixed-function pipeline. DX9 FFP ran these vertices through the
        // engine's 2D ortho (screen-pixel -> clip): emulate with the ported
        // stub_notransform_t VS. Done HERE (not in _LinkPP) so the replaced
        // VS's constants (screen_res!) merge into the pass ctable like any
        // other stage — and so the traits "null" special-case (which misses
        // the suffixed "null_0") never falls through to stub_default's
        // unbound m_WVP (zero matrix => degenerate draws).
        eff = "stub_notransform_t";
    }

    string_path name;
    xr_strcpy(name, eff);
    switch (RImplementation.m_skinning)
    {
    case 0:
        xr_strcat(name, "_0");
        break;
    case 1:
        xr_strcat(name, "_1");
        break;
    case 2:
        xr_strcat(name, "_2");
        break;
    case 3:
        xr_strcat(name, "_3");
        break;
    case 4:
        xr_strcat(name, "_4");
        break;
    }

    return CreateShader<SVS>(name, eff, flags);
}

void CResourceManager::_DeleteVS(const SVS* vs) { DestroyShader(vs); }

//--------------------------------------------------------------------------------------------------------------
SPS* CResourceManager::_CreatePS(LPCSTR _name)
{
    string_path name;
    xr_strcpy(name, _name);
    switch (RImplementation.m_MSAASample)
    {
    case 0:
        xr_strcat(name, "_0");
        break;
    case 1:
        xr_strcat(name, "_1");
        break;
    case 2:
        xr_strcat(name, "_2");
        break;
    case 3:
        xr_strcat(name, "_3");
        break;
    case 4:
        xr_strcat(name, "_4");
        break;
    case 5:
        xr_strcat(name, "_5");
        break;
    case 6:
        xr_strcat(name, "_6");
        break;
    case 7:
        xr_strcat(name, "_7");
        break;
    }

    return CreateShader<SPS>(name, _name);
}

void CResourceManager::_DeletePS(const SPS* ps) { DestroyShader(ps); }

//--------------------------------------------------------------------------------------------------------------
SGS* CResourceManager::_CreateGS(LPCSTR Name) { return CreateShader<SGS>(Name); }
void CResourceManager::_DeleteGS(const SGS* gs) { DestroyShader(gs); }

SHS* CResourceManager::_CreateHS(LPCSTR Name) { return CreateShader<SHS>(Name); }
void CResourceManager::_DeleteHS(const SHS* HS) { DestroyShader(HS); }

SDS* CResourceManager::_CreateDS(LPCSTR Name) { return CreateShader<SDS>(Name); }
void CResourceManager::_DeleteDS(const SDS* DS) { DestroyShader(DS); }

SCS* CResourceManager::_CreateCS(LPCSTR Name) { return CreateShader<SCS>(Name); }
void CResourceManager::_DeleteCS(const SCS* CS) { DestroyShader(CS); }

//--------------------------------------------------------------------------------------------------------------
} // namespace xray::render::RENDER_NAMESPACE
