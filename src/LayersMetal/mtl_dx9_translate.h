#pragma once
// DX9-era XRay shader source -> SM6 HLSL source translator (p5).
//
// Anomaly's shader set descends from Searge's DX9 HLSL corpus (searge-coc
// r2-style .ps/.vs + shared headers). DXC only targets SM6, so the legacy
// surface gets rewritten textually before DXC sees it:
//
//   * #include "x.h" / <x.h> resolved against the shader tree (inline
//     expansion; #ifndef guards dedup; #line markers keep diagnostics honest)
//   * sampler2D/3D/1D/CUBE and DX7 sampler declarations -> Texture* on unique
//     t registers. The corpus declares combined samplers without sampler_state
//     blocks, so one shared default sampler covers sampling; textures keep
//     their names so call sites read naturally after the rewrite.
//   * tex2D / tex2Dlod / tex2Dproj / tex3D / tex3Dlod / tex1D / texCUBE ->
//     _tex... helper functions wrapping Sample/SampleLevel/SampleBias/
//     SampleGrad (identifier-aware; whitespace before '(' tolerated)
//   * 'point' renamed (DXC reserves it for the point-sampling operator)
//   * (vec CMP x) ? a : b -> select(...) (fxc evaluated vector ternaries
//     component-wise; DXC forbids them)
//   * PS semantics COLOR -> SV_TARGET; DX9 FOG -> user semantic. When COLOR*
//     is used on PS INPUTS the caller retries with colorInputsAsTexcoord.
//   * stray DX9 c-register bindings on globals stripped (binding layout is
//     the backend's job; noted per file)
//
// Anything it cannot rewrite is reported in the translation notes so the
// batch validator can list it honestly instead of silently mangling.

#include "mtl_shader_compiler.h"

#include <string>
#include <vector>

namespace xray::metal
{

	struct Dx9Translation
	{
		bool ok = false;
		std::string hlsl; // inlined + SM6-ready source (prelude included)
		std::string error; // first fatal problem, short form
		std::vector<std::string> notes; // per-file diagnostics
	};

	struct Dx9TranslateOptions
	{
		// DX9 COLOR* semantics on PS INPUTS cannot become SV_TARGET; map them
		// to high TEXCOORD slots (COLOR/COLOR0->10, COLOR1->11, COLOR2->12).
		// Callers use this as a retry after the SV_TARGET mapping is rejected.
		bool colorInputsAsTexcoord = false;
	};

	// sourcePath: file the source came from (for diagnostics + include dirs).
	// includeDirs: extra search dirs after the including file's own directory
	// (e.g. the shader tree root so "shared\\common.h" resolves).
	Dx9Translation TranslateDx9Shader(const std::string& source, const std::string& sourcePath, ShaderStage stage,
	                                   const std::vector<std::string>& includeDirs, const Dx9TranslateOptions& opts = {});

} // namespace xray::metal
