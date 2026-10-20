#include "stdafx.h"
#pragma hdrstop

#include "SH_Atomic.h"
#include "ResourceManager.h"

namespace xray::render::RENDER_NAMESPACE
{
// Atomic
//SVS::~SVS()
//{
//    _RELEASE(vs);
//    dxRenderDeviceRender::Instance().Resources->_DeleteVS(this);
//}
//SPS::~SPS()
//{
//     _RELEASE(ps);
//     dxRenderDeviceRender::Instance().Resources->_DeletePS(this);
//}
//SState::~SState()
//{
//    _RELEASE(state);
//    dxRenderDeviceRender::Instance().Resources->_DeleteState(this);
//}
//SDeclaration::~SDeclaration()
//{
//    _RELEASE(dcl);
//    dxRenderDeviceRender::Instance().Resources->_DeleteDecl(this);
//}

///////////////////////////////////////////////////////////////////////
//  SVS
SVS::SVS() : sh(0)
#if defined(USE_DX11)
//  ,signature(0)
#endif
{}

SVS::~SVS()
{
    RImplementation.Resources->_DeleteVS(this);

#if defined(USE_DX11)
    // XXX: check just in case
    //_RELEASE(signature);
    //	Now it is release automatically
#endif

#if defined(USE_DX11)
    _RELEASE(sh);
#elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#elif defined(USE_METAL)
    // p5 Metal: id<MTLFunction> is owned by the shader compiler arena; the
    // stage record (MtlStageRefl) is borrowed. Nothing to release here.
#else
#   error No graphics API selected or enabled!
#endif
}

///////////////////////////////////////////////////////////////////////
// SPS
SPS::~SPS()
{
#if defined(USE_DX11)
    _RELEASE(sh);
#elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#elif defined(USE_METAL)
    // p5 Metal: see SVS note (arena-owned function).
#else
#   error No graphics API selected or enabled!
#endif

    RImplementation.Resources->_DeletePS(this);
}

///////////////////////////////////////////////////////////////////////
// SGS
SGS::~SGS()
{
#   if defined(USE_DX11)
    _RELEASE(sh);
#   elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#   elif defined(USE_METAL)
    // p5 Metal: arena-owned MSL function (unused on Metal anyway — no GS/HS).
#   else
#       error No graphics API selected or enabled!
#   endif

    RImplementation.Resources->_DeleteGS(this);
}

SHS::~SHS()
{
#   if defined(USE_DX11)
    _RELEASE(sh);
#   elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#   elif defined(USE_METAL)
    // p5 Metal: arena-owned MSL function (unused on Metal anyway — no GS/HS).
#   else
#       error No graphics API selected or enabled!
#   endif

    RImplementation.Resources->_DeleteHS(this);
}

SDS::~SDS()
{
#   if defined(USE_DX11)
    _RELEASE(sh);
#   elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#   endif

    RImplementation.Resources->_DeleteDS(this);
}

SCS::~SCS()
{
#    if defined(USE_DX11)
    _RELEASE(sh);
#    elif defined(USE_OGL)
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgram(sh));
    else
        CHK_GL(glDeleteShader(sh));
#    elif defined(USE_METAL)
    // p5 Metal: arena-owned MSL function (compute not used on this path yet).
#   else
#       error No graphics API selected or enabled!
#   endif

    RImplementation.Resources->_DeleteCS(this);
}

#if defined(USE_OGL)
SPP::~SPP()
{
    if (GLAD_GL_ARB_separate_shader_objects)
        CHK_GL(glDeleteProgramPipelines(1, &pp));
    else
        CHK_GL(glDeleteProgram(pp));

    RImplementation.Resources->_DeletePP(this);
}
#elif defined(USE_METAL)
SPP::~SPP()
{
    // pp = MtlShaderPair (heap, created by MtlMakeShaderPair). The MSL
    // functions it references are compiler-arena-owned.
    delete static_cast<MtlShaderPair*>(pp);
    pp = nullptr;

    RImplementation.Resources->_DeletePP(this);
}
#endif // USE_OGL


#if defined(USE_DX11)
///////////////////////////////////////////////////////////////////////
//	SInputSignature
SInputSignature::SInputSignature(ID3DBlob* pBlob)
{
    VERIFY(pBlob);
    signature = pBlob;
    signature->AddRef();
};

SInputSignature::~SInputSignature()
{
    _RELEASE(signature);
    RImplementation.Resources->_DeleteInputSignature(this);
}
#endif // USE_DX11

///////////////////////////////////////////////////////////////////////
//	SState
SState::~SState()
{
    _RELEASE(state);
    RImplementation.Resources->_DeleteState(this);
}

///////////////////////////////////////////////////////////////////////
//	SDeclaration
SDeclaration::~SDeclaration()
{
    RImplementation.Resources->_DeleteDecl(this);
    //	Release vertex layout
#if defined(USE_DX11)
    xr_map<ID3DBlob*, ID3DInputLayout*>::iterator iLayout;
    iLayout = vs_to_layout.begin();
    for (; iLayout != vs_to_layout.end(); ++iLayout)
    {
        //	Release vertex layout
        _RELEASE(iLayout->second);
    }
#elif defined(USE_OGL)
#   ifdef XR_PLATFORM_WEB
    ForgetVertexArrays(this);
#   endif
    glDeleteVertexArrays(1, &dcl);
#elif defined(USE_METAL)
    // p5 Metal: MTLVertexDescriptors are cached centrally by the pass manager
    // (mtlRuntime.mm) keyed by decl+VS — nothing per-SDeclaration to release.
#else
#   error No graphics API selected or enabled!
#endif
}
} // namespace xray::render::RENDER_NAMESPACE
