#pragma once
// p5 Metal shader pipeline — SPIR-V reflection (plain C++, no ObjC).
//
// Extracted from the DXC-produced SPIR-V via SPIRV-Cross, this drives:
//   * R_constant_table::parse (uniform name -> byte offset in the stage
//     $Globals image; matrices report row-major DX9 packing),
//   * the pass manager's texture/sampler binding (slots mirror the DX9
//     registers the translator emitted: t/s index == DX9 stage),
//   * the vertex-layout resolver (VS input attribute <-> HLSL semantic).
//
// Semantics are recovered from the *translated HLSL* (DXC records only
// Locations in SPIR-V): CollectInputSemantics() scans the entry's input
// declaration order, which is exactly the Location order DXC assigns, which
// is exactly the [[attribute(N)]] order SPIRV-Cross emits.

#include <cstdint>
#include <string>
#include <vector>

namespace xray::metal
{

	struct ReflectionUniform
	{
		std::string name; // HLSL name, array suffix stripped
		uint32_t offset; // bytes within the stage cbuffer image
		uint32_t size; // total size (arrays included)
		uint32_t stride; // array element stride (0 = not an array)
		uint32_t elements; // element count (1 = scalar member)
		int baseType; // 0 float, 1 int, 2 bool
		int rows; // 1..4
		int cols; // 1..4
	};

	struct ReflectionResource
	{
		std::string name;
		uint32_t textureSlot; // [[texture(N)]]
		uint32_t samplerSlot; // [[sampler(N)]]
		bool isSamplerOnly; // sampler declared without an own texture
	};

	struct ReflectionInput
	{
		std::string semantic; // "POSITION", "TEXCOORD3"...
		uint32_t attribute; // [[attribute(N)]] == SPIR-V Location
		uint32_t components; // 1..4
		bool isMatrixRow;
	};

	struct ShaderReflection
	{
		uint32_t cbufferSize = 0; // $Globals image size (0 = no constants)
		std::vector<ReflectionUniform> uniforms;
		std::vector<ReflectionResource> resources;
		std::vector<ReflectionInput> inputs; // VS only
	};

	// spirv: DXC output for one stage. inputSemantics: entry input declaration
	// order (CollectInputSemantics); may be empty for PS (inputs unused).
	bool ReflectSpirv(const std::vector<uint32_t>& spirv, const std::vector<std::string>& inputSemantics,
	                  ShaderReflection& out, std::string& error);

	// Scan translated HLSL for the entry function's input semantics in
	// declaration order. Handles struct-parameter entries (looks up the struct
	// definition) and flat parameter lists. SV_* semantics are skipped
	// (SPIRV-Cross maps them to builtins, not attributes).
	std::vector<std::string> CollectInputSemantics(const std::string& hlsl, const std::string& entry);

} // namespace xray::metal
