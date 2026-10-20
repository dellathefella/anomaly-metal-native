# Native Metal shader pipeline (p5)

Anomaly ships **no shader sources** — only precompiled DX9 DXBC inside
`shaders.xr`. The source corpus for the Metal port is therefore the
**Anomaly-lineage DX9 HLSL tree** (`repos/searge-coc/res/gamedata/shaders/r2`,
the direct ancestor of the monolith r2 shader set Anomaly 1.5.3 compiles),
plus the shared headers it includes.

## Pipeline

```
.ps/.vs ──► TranslateDx9Shader ──► DXC (in-process, -spirv) ──► SPIRV-Cross ──► MSL ──► MTLLibrary
            (mtl_dx9_translate)    (mtl_shader_compiler +       (CompilerMSL)            (on-device
                                     dlopen libdxcompiler)                                validation)
```

- `MetalShaderCompiler` (`src/LayersMetal/mtl_shader_compiler.*`) — HLSL →
  SPIR-V → MSL with an FNV-1a hash-keyed on-disk MSL cache (stage, entry,
  defines and source all feed the key). DXC runs in-process via the DXC C API
  (dlopen `libdxcompiler.dylib`); the `dxc` CLI is the fallback backend.
- `TranslateDx9Shader` (`src/LayersMetal/mtl_dx9_translate.*`) — textual
  DX9→SM6 source rewriting, driven by what the corpus actually contains:
  - `#include` inlining (own dir first, then the shader-tree root so
    `shared\common.h` resolves; `#line` markers keep diagnostics honest)
  - `sampler2D/3D/1D/CUBE` and DX7 `sampler` → `Texture*` on unique `t`
    registers + one shared default sampler (the corpus uses no
    `sampler_state` blocks)
  - `tex2D / tex2Dlod / tex2Dproj / tex3D / tex3Dlod / tex1D / texCUBE` →
    prelude helpers wrapping `Sample/SampleLevel/SampleBias/SampleGrad`
    (whitespace between call name and `(` tolerated — corpus style)
  - DX9 `c`-register bindings on globals stripped (constant packing is the
    backend's job); `register(ps,sN)` accepted
  - `point` renamed (`point` is reserved in DXC — point-sampling operator)
  - `(vec CMP x) ? a : b` → `select(...)` (fxc evaluated vector ternaries
    component-wise; DXC forbids them)
  - PS semantics: `COLOR*` → `SV_TARGET*`; DX9 `FOG` → plain user semantic.
    When a file reads DX9 `COLOR*` as PS *input*, the batch tool retries with
    `colorInputsAsTexcoord` (input structs/params map to TEXCOORD10..12).
  - Script-injected defines (`USE_SUNMASK`, `USE_SUNFILTER`,
    `USE_R2_STATIC_SUN`, `USE_STATIC_FLASH`, `SKIN_NONE`, `SSAO_QUALITY=3`)
    are applied automatically as a retry when identifiers or the entry point
    sit behind `#ifdef`s the `.compile`/`.pass` scripts normally resolve.
- Entry points are discovered per file: `main`, stem-derived (`avg4`,
  `ssao_blur_ps`) and profile-suffixed (`main_ps_1_1`, `main_ps_3_0`) names
  all appear in the corpus; the shader-script system binds them by name.

## Batch validation

`metal_shader_batch` (opt-in `XRAY_RENDERER_METAL=ON`) runs every corpus
shader through the full chain including **on-device MSL validation**
(`newLibraryWithSource` + function lookup):

```
cmake --build build-gl --target metal_shader_batch
./build-gl/bin/metal_shader_batch [shaderRoot] [report.tsv] [nameFilter]
```

Latest run (Apple M1 Max, in-process DXC):

```
BATCH_SUMMARY total=201 msl_ok=197 dxc_fail=4 trans_fail=0 msl_fail=0
```

Full per-shader table: [`metal_shader_batch_r2.tsv`](metal_shader_batch_r2.tsv).

The 4 remaining failures are shader-script-context cases, not pipeline gaps —
each needs data only the runtime `.compile`/`.pass` scripts supply:

| file | reason |
| --- | --- |
| `combine_2.ps` | fxc implicitly widened `half3`→`half4` at a `combine_bloom` call (source bug fxc tolerated) |
| `ssao.ps` | global `m_v2w` is declared by the shader script, not the source |
| `ssao_blur.ps` | library fragment without entry-point semantics (wrapped by the script system) |
| `ssao_hbao.ps` | sampler `s_position` is declared by the shader script |

These are handled by the shader-script layer when the Metal renderer parses
`.compile`/`.pass` files (p5 t2+), where the engine already knows the pass
defines, sampler bindings and entry names.
