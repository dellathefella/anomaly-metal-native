# Metal renderer for S.T.A.L.K.E.R. Anomaly (macOS / Apple Silicon)

A native Metal renderer for **Anomaly 1.5.3**. It runs the X-Ray R2 deferred
pipeline directly on Metal: Anomaly's DX9 `r2\` HLSL is compiled at runtime
(DXC → SPIR-V → SPIRV-Cross → MSL) and cached on disk.

- Engine binary: `build-gl/bin/xr_3da`
- Metal layer: `src/LayersMetal/` (`xrRenderMetal` runtime, `xrRenderPC_Metal` backend)
- Shared deferred renderer: `src/LayersOGL/xrRender_R2`, `src/LayersOGL/xrRender`

## Build and run

```sh
cmake -S . -B build-gl -DCMAKE_BUILD_TYPE=Release \
      -DXRAY_RENDERER_METAL=ON -DXRAY_RENDERER_GL=ON
cmake --build build-gl -j 12

data/deploy_gamedata.sh ../Anomaly      # shader + options-menu overlays
scripts/run_metal.sh                    # launches with -renderer metal
```

`-renderer metal` matters: without it the engine loads the GL renderer, and if
the Metal library fails to load it falls back to GL with only a log line
(`! renderer: xrRender_METAL.dylib failed to load ... falling back to GL`).
Check the log when something looks off.

The first launch compiles every shader and is slow; later launches load from
`appdata/shaders_cache_metal/`.

## What works

Verified in-game on `k00_marsh` (day, night and storm weather):

- World geometry, terrain texturing, grass, water, sky, fog, sun and sun shafts
- Auto-exposure and bloom, stable while the camera moves
- Dynamic objects: NPCs, mutants, items, physics props, attached weapons
- First-person hands and weapons, aiming, tracers and hit sparks
- Local lights with shadows: flashlight, lamps, omni lights
- Rain, and other world-space fixed-function effects
- 2D UI, the scripted inventory (item icons), 2D PDA and the 3D in-hand PDA
- MetalFX spatial upscaling (`r_metalfx_scale`, video options → MetalFX upscaling)

## Known gaps

- **Anomaly-specific post-processing is not ported**: SMAA, SSDO, depth of
  field, LUT colour grading, night vision and gas-mask overlays. The renderer
  runs the base r2 shader tree; Anomaly-only shaders that the engine can drive
  as-is (3D PDA screen, scope lens, red-dot sights) are extracted from
  `db/shaders.db0` at startup. Scope lens and red-dot shaders are present but
  have not been checked in-game.
- **MetalFX is spatial only.** The HUD is upscaled with the scene. Temporal
  upscaling needs motion vectors and jitter, which the pipeline does not produce.
- **Occlusion queries are stubbed** (everything reports visible), so lights and
  shadow casters are not occlusion-culled.
- The sun flare still draws with a placeholder pixel shader.
- Lightning, particles, wallmarks and thermal/scope second-viewport effects have
  not been individually verified.

## Settings

| Console variable | Meaning |
| --- | --- |
| `r_metalfx_scale` (0.5–1.0) | Internal render scale; below 1 the scene is upscaled with MetalFX. Applied at launch. |
| `g_3d_pda` | 3D in-hand PDA (Anomaly default: on). |
| `xr_show_stats` (0–2) | FPS / frame-time / memory overlay. |

`XR_METAL_SCALE=<f>` overrides `r_metalfx_scale` for a single run.

## How the port differs from D3D9

These are the conventions that caused most bugs; keep them in mind when
touching the backend.

- **Screen space is D3D-style** (v down). `u_compute_texgen_screen` uses the D3D
  offsets under `USE_METAL`.
- **Hardware shadow compare is explicit.** D3D9 compared implicitly when a depth
  texture was sampled; the MSL is patched to `depth2d` + `sample_compare`
  (`MtlPatchShadowDref` in `mtlShaderCompile.mm`).
- **Vertex inputs are typed.** SM3 treated every input as float. Integer inputs
  fed from normalized formats are rewritten to float in the translator; raw
  `SHORT`/`UBYTE` formats arrive unscaled, exactly as on D3D9.
- **Fixed-function passes** (`"null"` vertex shader) use
  `stub_notransform_t.vs`, which picks pixel-space or `m_WVP` per draw from the
  bound vertex declaration.
- **Array constants** record their full extent (`R_constant_load::extent`);
  only the first element used to be uploaded.
- **Script numbers → unsigned** go through `int64` in luabind so negative
  colours wrap as on x86 instead of saturating to 0 on ARM64.

## Testing

The engine has a small command server for automated runs: launch with
`-nointro -renderer metal -mcp` and connect to `127.0.0.1:27846` (one client at
a time; read up to the first newline).

| Command | Effect |
| --- | --- |
| `state` | frame, fps, in-game flag, level |
| `exec <console command>` | run a console command |
| `lua <chunk>` | run Lua in the game's script VM and return the results |
| `key <name>` / `hold <name> <sec>` | key tap / hold (`337`/`338` = left/right mouse) |
| `mouse_move <dx> <dy>` | relative mouse motion |
| `screenshot <name>` | write `appdata/screenshots/<name>.jpg` |
| `quit` | exit |

Load a save with
`exec start server(<save name>/single/alife/load) client(localhost)`.
Mute with `exec snd_volume_eff 0` and `exec snd_volume_music 0` (do not use
`-nosound`).

When the window is hidden or the screen is locked, frames are rendered but not
presented and the loop sleeps 10 ms per frame, so fps numbers from background
runs are not representative.

### Debug switches

All are environment variables and off by default.

| Variable | Purpose |
| --- | --- |
| `XR_METAL_RTSTATS=<rt substr>` (+ `_PERIOD`) | Log min/mean/max of matching render targets. |
| `XR_METAL_RTDUMP=<dir>` | With `RTSTATS`, also write each target as a PPM. |
| `XR_METAL_RTTRACE=<rt substr>` | Log which shader pairs draw into matching targets. |
| `XR_METAL_VLDUMP=<pair substr>` | Dump the vertex layout built for a shader pair. |
| `XR_METAL_CBDUMP=<pair substr>` | Dump the constant values uploaded for a shader pair. |
| `XR_METAL_DRAWDIAG=1` | Enable the per-draw histogram/state probes. |
| `XR_P5_CONSTPS=<ps substr>` | Replace a pixel shader's output with solid red. |
| `XR_P5_SHADOW1`, `XR_P5_MAT1`, `XR_P5_LMAP1` | Neutralise the shadow / material / light-map term in light shaders. |
| `XR_METAL_RAWX2=1` | Re-enable the old (incorrect) ×2 scaling of raw integer vertex attributes. |

`mtlRuntime.mm` and `mtlShaderCompile.mm` still contain many older one-off
probes from the bring-up (`XR_P5_*`, `p5`/`p6` log lines); they are inert unless
their variable is set, and are due for removal.

## Key files

- `src/LayersMetal/xrRenderMetal/mtlRuntime.mm` — pass manager, encoders, draw path
- `src/LayersMetal/xrRenderMetal/mtlShaderCompile.mm` — MSL patches, stage alignment
- `src/LayersMetal/mtl_dx9_translate.cpp` — DX9 HLSL → SM6 HLSL rewrites
- `src/LayersMetal/mtl_device.mm`, `mtl_state.mm` — device, textures, state cache
- `src/LayersMetal/xrRenderPC_Metal/` — renderer backend (targets, sun, shader loading)
- `src/LayersOGL/xrRender_R2/`, `src/LayersOGL/xrRender/` — shared deferred renderer
- `data/shader-overlay/r2-extra/` — port-side shaders layered over the r2 tree
- `src/xrEngine/xr_mcp.cpp` — test command server
