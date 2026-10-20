#pragma once
// p5 Metal device layer — compiled shader records + reflection (mirror role of
// the GLuint program handles in the GL device layer).
//
// Shader flow (rmtl_shaders.cpp CRender::shader_compile):
//   .vs/.ps DX9 HLSL body (+ script defines) → mtl_dx9_translate (DX9→SM6)
//   → DXC → SPIR-V → SPIRV-Cross → MSL → newLibraryWithSource (id<MTLFunction>)
// The SPIRV-Cross pass also emits the reflection table below, which drives
// R_constant_table::parse (constant offsets) and the pass manager (textures,
// samplers, cbuffer size).

#include <cstdint>
#include <string>
#include <vector>

namespace xray::render::RENDER_NAMESPACE
{
// One reflected uniform (DXC $Globals member) of a compiled stage.
struct MtlUniformRefl
{
    std::string name;   // HLSL name, array suffix stripped ("m44")
    uint32_t offset;         // bytes within the stage cbuffer image
    uint32_t size;           // element size in bytes
    uint32_t stride;         // array element stride (0 = not an array)
    uint32_t elements;       // 1 = scalar member
    int baseType;       // 0 float, 1 int, 2 bool (RC_float/RC_int/RC_bool)
    int rows;           // 1..4 (matrices: rows of float4 in DX9 layout)
    int cols;           // 1..4
};

// One reflected texture/sampler binding of a compiled stage.
struct MtlResourceRefl
{
    std::string name;
    uint32_t textureSlot;    // [[texture(N)]]
    uint32_t samplerSlot;    // [[sampler(N)]] (UINT32_MAX = shared default sampler)
    bool isSamplerOnly; // declared sampler w/o an own texture
};

// Reflection bundle for one compiled MSL function (one shader stage).
struct MtlStageRefl
{
    void* function{ nullptr }; // id<MTLFunction>, borrowed (compiler-owned)
    uint32_t cbufferSize{ 0 };      // $Globals image size (0 = no constants)
    std::vector<MtlUniformRefl> uniforms;
    std::vector<MtlResourceRefl> resources;
    // VS only: input attribute table (SPIRV-Cross [[attribute(N)]] order).
    struct InputAttr
    {
        std::string semantic; // original HLSL semantic ("TEXCOORD3", "POSITION")
        uint32_t attribute;        // [[attribute(N)]]
        uint32_t components;       // 1..4
        bool isMatrixRow;     // matrix inputs occupy consecutive attributes
    };
    std::vector<InputAttr> inputs;
};

// SPP::pp payload: a compiled VS+PS pair (the Metal "program pipeline").
// The MTLPipelineState is built lazily by the pass manager (it needs vertex
// format + render-target formats at draw time).
struct MtlShaderPair
{
    MtlStageRefl vs;
    MtlStageRefl ps;
    std::string name;
};

// Compile a translated HLSL stage source through the MetalShaderCompiler.
// Implemented in mtlShaderCompile.mm. target: 'v'/'p'. entry: HLSL entry
// ("main"/"main_ps_1_1"...). defines: newline-joined #define block (may be "").
// Returns false + error on failure. The MtlStageRefl payload (function +
// reflection) is allocated and owned by the shader-compile registry.
bool MetalCompileStage(MtlStageRefl& out, char target, const char* name, const char* source,
    const char* entry, const std::string& defines, std::string& error);

// Heap-allocate a shader pair record (SPP::pp payload).
MtlShaderPair* MtlMakeShaderPair(const char* name);

// SVS/SPS `sh` payload: pointer to a heap MtlStageRefl (filled by
// MetalCompileStage). (SPP::pp payload: MtlShaderPair*.)
} // namespace xray::render::RENDER_NAMESPACE
