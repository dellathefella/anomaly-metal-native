# Metal Renderer Port — Status

Native Metal renderer for **S.T.A.L.K.E.R. Anomaly 1.5.3** on macOS/ARM64 (Apple Silicon).
Target: render Anomaly's DX9-convention deferred pipeline natively on Metal, no translation layer.

`xr_3da` builds to `engine/build-gl/bin/xr_3da`; the Metal layer lives in
`engine/src/LayersMetal/` (`xrRenderMetal` runtime + `xrRenderPC_Metal` renderer backend),
driving the shared R2 deferred renderer (`src/LayersOGL/xrRender_R2`, compiled into the Metal target).

---

## What works (verified in-game via MCP harness)

- **The world renders.** Verified in-game runs (fps 40–70, level `k00_marsh`, live camera) produce
  correctly painted, lit, full-frame screenshots — geometry, textures, rain, HUD/UI, postprocess chain.
- **Full deferred pass chain** runs: smap → position gbuffer (MRT) → sun/accum → combine → bloom →
  postprocess → UI, matching the GL reference pass list.
- **Metal device layer**: HiDPI CAMetalLayer swapchain, state cache (PSO/DSS), DX9→Metal shader
  pipeline (HLSL→SPIR-V→MSL via DXC + SPIRV-Cross path), sampler/texture map, BCn handling,
  readback with depth/BC-correct blit options, framebuffer feedback guard (same-target RT remap —
  this was the original black-frame root cause and it is fixed).
- **MCP test server** (`-nointro -mcp`, port 27846): `state`, `exec`, `key`, `mouse_move`,
  `screenshot` — headless-ish automated testing with autosave load.
- **Input**: keyboard/mouse reach the game (camera control proven via yaw/pitch deltas).

## Open bug: the right-edge black band (user priority #2)

A vertical black band on the right edge of the screen (~24% of width at the widest), edge tilted
~1°. Extensive forensics have localized it precisely:

### Established facts (verified-in-game or raw-RT evidence only)

| Fact | Evidence |
|---|---|
| The band is a **coverage hole in the geometry passes**, not a compositing bug | `XR_METAL_FILLRT=position` fills the gbuffer last-op; the fill **paints the band region full-width** and survives to the final screenshot (red reaches x=3023) — composite is innocent |
| Position/normal/albedo gbuffer RTs are **raw-data empty** right of the line | raw RT dumps: `position` midrow lastlit=2299, blacktail=724; edge per row: x=2313@y0 → 2287@y1560 (**straight, tilted ≈ −0.96°**) |
| The hole edge is **screen-fixed** — it survives a ≥66° camera orbit pixel-identical | render-matrix sweep probes |
| **Not** viewport/scissor: full rects on all geometry passes, including the direct `SetViewport/SetScissor` bypass paths | `rectdbg` + `rectbp` probes |
| **Not** attachment dimensions: all position-pass attachments 3024×1680 | `rtatt` probe |
| **Not** HOM occlusion culling: band pixel-identical with HOM disabled (`XR_METAL_NOHOM=1`) | wvp11 |
| **Not** texture views (none exist in the port) | static audit |
| Engine geometry **does** project into the band per CPU simulation | replay probe: largest in-game draw (70 272 tris, 9 994 front-facing) CPU bbox spans px 4..2992 — yet the gbuffer stays empty right of the line |
| A fixed-NDC fill (no vertex transform at all) rasterizes fine in the band, in the same encoder | wvp10 fill |
| **Independently re-confirmed on a verified-healthy Metal run** (in-game k00_marsh, 53 fps, no key presses): final-frame content stops at x=2318@y0 → 2287@y1600, i.e. a straight ≈0.93° tilt and a 711–737 px black right band | screenshot column scan, 2026-10-23 |
| Every screen pass uses `vp=(0,0,3024x1688)` on `rtWH=3024x1688` — no narrower viewport exists anywhere in the frame, so the ~2290 edge is **not** a viewport width | log scan of all `rtWH=`/`vp=` pairs |
| Screenshots come out **3024×1688** (RT size), while earlier notes assumed 3024×1680 — the 1680/1688/1690 mismatch across notes is real and unresolved | screenshot vs `rtWH` vs `rtatt` |
| A second seam sits near **y≈1456**: below it the frame shows different content (HUD strip + smeared ground), so the defect is not purely one vertical edge | screenshot row scan + visual |
| Verified-healthy in-game frame also shows **radial streaking** out of a central vanishing point with a stationary camera, and a very dark scene (mean lum 7.7/255, 7% non-black) — separate defects from the band | screenshot, 2026-10-23 |

### Suspect ledger (status after wvp27)

**Ruled out** (each by raw RT bytes, in-game probes, or state-bisect runs):
composite; viewport/scissor incl. bypass paths; attachment dims; texture views;
HOM occlusion culling (wvp11); **culling frustum** — `OnCameraUpdated` is LIVE
(frusprobe stamp advances), planes verified by hand as the correct 108° wedge
of a healthy `mFullTransform` (wvp19); **stencil** — `XR_P5_NOSTENCIL=1` band
pixel-identical (wvp26); **depth test** — `XR_METAL_NODEPTH=1` band unchanged
(wvp27).

**Replay probe RETIRED as oracle** (wvp18–wvp24): engine terrain MSL confirmed
as `POSITION * m_WVP` (row-vector, `XR_METAL_MSFDUMP` dumps in /tmp/msl/);
mode-0 replay performs the identical op on identical bytes yet rasterizes
nothing — its raw vertex fetch does not reproduce the engine's attributed read.
Earlier "red stops/never crosses" readings were additionally corrupted by
single-row scans and tail-truncated logs.

**Facts still load-bearing:** band edge = NDC x ≈ 0.52, straight, tilted ≈0.9°,
**conclusively screen-fixed** — wvp29 orbited the live camera 132° (yaw
94→50→6→−38) and the edge stayed at top=2311/mid=2297/bot=2287, tilt 0.91°,
BAND@0.760 in every shot. This rules out world-fixed geometry: missing terrain
sectors, world-space geometry gaps, and camera-locked culling (all rotate with
the camera). Fixed-NDC fill reaches x=2645 through the same PSO path (wvp21,
1.27M red px in position RT + screenshot); staged m_WVP projects to
maxNdcX=2.4 (NOT x-compressed) under the engine's own convention.

**wvp31–wvp37 additions (all verified in-game, current build):**

- **Full-RT coverage map** (`XR_METAL_RTDUMP='$user$'`, wvp32): `_user_albedo`
  and `_user_normal` are full-left but end at the *same tilted edge* as the
  screen band (2313@y33 → 2286@y1650); `base_0/1/2` (HUD) reach x=3023;
  `generic1` 100%; `generic0`/`accum` empty at dump time; `_user_position` is
  a separate anomaly (content only in strip x∈[1500..2312], tilted both edges).
  ⇒ the band is a **geometry-pass coverage hole**, and the visible color source
  is albedo/normal, not position.
- **Viewport/scissor on EVERY screen-sized pass** (`XR_METAL_POSVP=1` widened
  to all passes, wvp33): all vp=(0,0,3024x1684); scissor only small HUD rects
  on `base_*`. Viewport theory dead on the current build.
- **CPU submission culling double-exonerated** (`XR_METAL_CULLWIDE=1.0`):
  widening applied BOTH at r2 `OnCameraUpdated` ViewBase (wvp34) AND at the
  `r__dsgraph_render_subspace` temp frustum that world geometry actually uses
  (wvp35) — band unchanged. Frustum extraction (`CreateFromMatrix`) audited
  element-by-element against the dumped planes: textbook-correct.
- **Matrix bytes on GPU == `mFullTransform`** at the VS-read offset 272
  (`XR_METAL_WVPCMP=1`, wvp33); all 80 dumped VS transforms orthodox
  `POSITION * matrix`.
- **Rain shares the clip**: bright rain-streak pixels end at x≈2300–2309,
  nothing past 2325 (screenshot scan) — terrain and rain (both drawn in the
  position pass) are cut by the same camera-fixed line.
- **PPLIST probe fixed** (wvp37): the old flush waited for 400 draws, but the
  position pass submits far fewer per frame (terrain is batched) so it never
  fired. Now flushes at window end and logs head+tail draw order — used to
  identify a late zero-painting draw.
- **wvp37 (fresh dumps, RT 3024×1676 — the drawable height varies per run)**:
  the position-pass draw order is terrain/tree/lmh materials
  (`deffer_tree_bump-hq`, `deffer_base_lmh_bump_d-hq`, `deffer_base_bump_d-hq`,
  `deffer_base_lmh_bump-hq`, …) — **no sky/null "zero-painter" draw** in the
  tail. Geometry coverage is a quadrilateral: left edge = terrain silhouette
  (1053→1355, steep) and right edge = the band (2313→2286, ~0.93° tilt).
  `base_0/1/2` are the **back buffers** (`rt_Base`) and share the exact same
  right edge — the band survives into the final screen target. `accum` ends at
  2292 (same edge). `normal` reads full-left only because its clear value is
  non-zero (not geometry coverage).
- **DRAWBBOX/CLIPSTAT probes exist** (`XR_METAL_DRAWBBOX`, `XR_METAL_CLIPSTAT`):
  they compute the full-vertex NDC-x bbox of gbuffer draws from the exact
  staging bytes. Draws whose bbox reaches the band yet store nothing prove a
  per-fragment kill; no such draws prove the CPU culling boundary itself is
  the tilted line. Terrain VB is `float4 POSITION` at offset 0, so the raw
  fetch is valid for this probe.
- **wvp39 — DECISIVE: the band is a per-fragment kill.** DRAWBBOX logs terrain
  draws whose vertex bbox reaches into and beyond the band
  (`deffer_base_bump-hq prim=2139 ndc=[0.92..1.02] px[2901..3050]`,
  `prim=660 ndc=[-0.34..0.87]`, `deffer_impl_flat_d ndc=[0.96..1.51]`), and
  CLIPSTAT confirms `band=1722 out=1285 maxndc=3.624`. So geometry IS
  submitted and its vertices project into the band, yet the gbuffer stores
  nothing there ⇒ fragments are killed, not CPU-culled.
- **wvp40 — depth and stencil re-exonerated on the CURRENT build**:
  `XR_METAL_NODEPTH=1 XR_P5_NOSTENCIL=1` leaves the band pixel-identical
  (2312/2296/2286, tilt 0.92°). Depth buffer is cleared to 1.0 (far) each
  frame, so fragments beyond the band pass a LessEqual test anyway. Terrain
  VB is `float3 POSITION` at offset 0 (posclip decl[0] type=2 off=0),
  confirming the DRAWBBOX raw fetch is valid.
- **Remaining per-fragment suspects** (after depth/stencil/scissor/viewport/
  blend/write-mask/PS-discard are all exonerated): the engine PSO vs the fill
  probe's own PSO, and the engine's per-draw depth bias (the fill resets bias
  to 0). wvp41 re-runs the fill probe on the current build with RECTBYPASS to
  confirm the RT accepts fragments beyond the band and log direct scissor
  calls.
- **wvp41 — BREAKTHROUGH: the fill paints the FULL RT and the band vanishes.**
  `XR_METAL_FILLRT=position` (own PSO, full viewport/scissor, depth Always,
  cull None, bias 0) covers x=0..3023 (`band%=100 left%=100`), and the
  screenshot reads `BAND@1.000` (top/mid/bot=3023) — **no band**. So the RT,
  composite and present all accept the full width; the band is caused by
  engine per-draw state that the fill resets. Engine never sets a depth bias
  (only the fill does), so bias is innocent.
- **wvp42 — cull mode innocent**: `XR_METAL_NOCULL=1` leaves the band
  pixel-identical (2313/2297/2286, tilt 0.96°).
- **wvp44 — blend/write-mask innocent**: `blenddbg` shows the terrain PSOs
  have `blendEn=0`, `mask=15` (all channels), `depthEn=0`, `depthWrite=0`,
  `blendAlpha=0`. So of the state the fill resets (viewport/scissor/DSS/cull/
  fill-mode/bias/blend/PSO), **only the engine PSO's VS/PS + vertex descriptor
  remains** as the difference vs the fill's hardcoded VS/PS.
- **Next discriminator**: draw the engine geometry with the engine VS + the
  fill PS (red). If it paints the band, the VS is fine and the PS kills; if
  not, the VS kills.

**Active theory (post-wvp37):** the tilt kills every framebuffer-space
mechanism (viewport/scissor/attachments cannot tilt) — only clip-space, a
camera-locked plane, or a late in-pass draw painting zeros can. Matrix path is
closed (wvpcmp). Next discriminator: ordered draw list of the position pass
(`XR_METAL_PPLIST=1`) to find the last-drawn pair(s) covering x>2297.

**Secondary bug found:** `mtl_R_sun.cpp` passes `Device.fASPECT` (=height/width
in Monolith convention, 0.5582) straight into `glm::perspective`, which expects
width/height — sun/shadow projections are wrong by (h/w)². Not the band
(position pass is clean of it) but queued after.

## Fixed: radial streaks from the screen centre

A fan of thin green/brown lines radiated from the screen centre (x≈1512) across
the right half, in both the final frame and the raw `$user$albedo` RT. It was
screen-fixed and survived camera motion. The fan converged at the camera origin,
so the geometry had vertices collapsing to the eye point.

**Root cause (fixed):** the Metal constants cache wrote the engine `Fmatrix`
**row-major**, while the GL backend uploads its **transpose**
(`glr_constants_cache.h`: `it[0].set(_11,_21,_31,_41)…`). The MSL
`float4x4`/`float3x4` constants are column-major, so writing the row-major
Fmatrix made every matrix transposed: the terrain WVP lost its translation and
geometry collapsed to a fan from the camera origin. `XR_METAL_REPLAY` proved it
— replaying the captured terrain draw with the engine VB/WVP bytes rasterized
to a 5-pixel bbox at screen centre (`px=[1498..1528] py=[843..844]`). The fix
transposes the Fmatrix rows in `mtl_constants_cache.h` to match GL; verified
in-game screenshots now render coherent grass/terrain/HUD with no streaks.

**Exonerated by verified in-game bisect runs** (each knob left the streaks
pixel-identical):

| Knob | Pass skipped |
|---|---|
| `XR_P5_NORAIN=1` | visible rain layer |
| `XR_P5_NORAIN=2` | rain layer **and** rain normal pass (`draw_rain` → rt_Position) |
| `XR_P5_NOSKY=1/2` | skybox (+ lens flare) |
| `XR_P5_NOFLARE=1` | combine-pass lens flare (`RenderFlares`) |
| `XR_P5_NOSKY=2 + NOFLARE=1` | **both** flare copies |
| `XR_P5_NODETAIL=1` | grass/detail manager (split + non-split branches) |
| `XR_P5_NOLOD=1` | FLOD imposter billboards (`render_lods`) |
| `XR_P5_NOPART=1` | particle sprites (`CParticleEffect::Render`) |
| `XR_P5_NOIMPLD=1` | implicit-detail terrain (`deffer_impl_flat_d`) |
| `XR_P5_NOWATER=1` | water surface draws |
| `XR_P5_NOTREE=1` | tree geometry (left half goes black; streaks persist) |
| `XR_P5_NOBASE=1` | base terrain/building draws (scene mostly black; streaks persist) |
| `XR_P5_NOWMARK=1` | wallmark decals |
| `XR_P5_NOBLOOM=1` | bloom chain |
| `XR_P5_NOPP=1` | postprocess chain |
| `XR_P5_NOSHAFTS=1` | volumetric sun shafts |
| `r3_water_refl 0` / `r2_soft_water off` | water SSR |

**Note on the old FILLRT evidence:** `XR_METAL_FILLRT=accum` appeared to remove
the streaks, but the fill probe fires at the scene encoder's close (3
attachments), so it overwrote the g-buffer RTs — a probe artifact. Direct
`XR_P5_NOACCUM=1` (combine accum sample → 0) left the streaks intact, and the
postaccum readback showed the accum RT empty. The streaks were always the
transposed-WVP geometry, not the accum RT.

The `XR_METAL_RTDUMP='$user$'` dump pins `_user_position` to a parallelogram
strip (x≈1505→2312 top, 1447→2286 bottom) while `_user_albedo`/`base_*` are
full-left — the position RT strip was the same transposed-WVP collapse and is
gone with the fix.

## Known issues / queue

- **Daytime verification** (user priority #3) pending — daytime lighting check after the band.
- **Sky is an invisible stub** → void areas read black (planned in t5: sky/sun/accum_sun GL-parity).
- **Pause-menu selector misalignment** — wide-screen ratio branch fires at 1.8:1 + RT height 1684
  vs window 1680 discrepancy (`layer.drawableSize` vs `Device.dwHeight`).
- **Texture-retention stall**: RSS grows to ~10 GB and the game freezes after ~4–5 min in-game.
  Real bug, independent of probes.
- **t4**: MetalFX upscaling runtime verification.
- **t6**: strip all diagnostic probes (list below), re-run `metal_devicetest` + shader-batch regressions.
- **p6**: `.app` packaging, stability pass, docs.

## Probe knobs (all env-gated, stripped in t6)

| Knob | Purpose |
|---|---|
| `XR_METAL_FILLRT=<substr>` | last-op red fill in passes matching substr — coverage oracle |
| `XR_METAL_REPLAY=1` | replay biggest position-pass draw (engine VB/WVP bytes) through neutralized pipeline into position + final target; CPU clip-sim logs expected px bbox |
| `XR_METAL_RTDUMP=<substr>` | raw RT byte dumps to `/tmp/rtdump/` (once per RT after verified in-game gate); forces ShaderRead usage |
| `XR_METAL_RECTDBG2=<substr>` | per-pass attachment dims |
| `XR_METAL_RECTBYPASS=1` | logs viewport/scissor applied via the direct (bypass) path |
| `XR_METAL_FRUSPROBE=1` | culling frustum planes + `mFullTransform` dump in-game |
| `XR_METAL_NOHOM=1` | disable HOM occlusion culling |
| `XR_P5_NOSTENCIL=1` | neutralize stencil tests globally |
| `XR_P5_NOSCISSOR=1` | ignore engine scissor rects |
| `XR_METAL_NOCULL=1`, `XR_METAL_FRONT=1`, `XR_METAL_NODEPTH=1` | state overrides for state-theory bisection |
| `XR_P5_NORAIN=1/2` | skip visible rain layer / also the rain normal pass |
| `XR_P5_NOSKY=1/2` | skip skybox / also the RenderSky lens flare |
| `XR_P5_NOFLARE=1` | skip the combine-pass lens flare (`RenderFlares`) |
| `XR_P5_NODETAIL=1` | skip grass/detail manager |
| `XR_P5_NOLOD=1` | skip FLOD imposter billboards |
| `XR_P5_NOPART=1` | skip particle sprites |
| `XR_P5_NOIMPLD=1` | skip implicit-detail terrain draws (`deffer_impl_flat_d`) |
| `XR_P5_NOWATER=1` | skip water surface draws |
| `XR_P5_NOTREE=1` | skip tree geometry draws |
| `XR_P5_NOBASE=1` | skip base terrain/building draws |
| `XR_P5_NOWMARK=1` | skip wallmark decals |
| `XR_P5_NOBLOOM=1` | skip bloom chain |
| `XR_P5_NOPP=1` | skip postprocess chain |
| `XR_METAL_REFLDBG=<substr>` | dump uniform offset/size/stride/elements for matching shaders |

## Testing workflow

### `-renderer metal` is mandatory

Launch flags are `-nointro -renderer metal -mcp`. `EngineAPI.cpp` picks the renderer module
from `-renderer metal|gl`, then `$XR_RENDERER`, and **defaults to `gl`** — Apple's OpenGL
translayer. It then `dlopen`s the chosen dylib and, if the Metal one fails, prints
`! renderer: xrRender_METAL.dylib failed to load ... - falling back to GL` and silently
continues on GL. Launch without the flag and you are screenshotting, profiling and
"debugging" the translayer while believing it is Metal (a black window plus `fps=0.0` in
the menu is the classic symptom). Verify which renderer is live before trusting any
observation, e.g. `sample <pid>` and check for `render_metal` vs `render_gl::CHW::Present`,
or grep the log for `xrRenderMetal` lines.

### Logging goes to stdout, not the .log file

`Msg()` output lands on **stdout**; `appdata/logs/xray_jdella.log` is not written by current
runs. Redirect stdout when launching or you have no log at all.

### MCP notes

MCP listens on `127.0.0.1:27846` and serves **one client at a time**. A second client
blocks until the first closes, which looks exactly like an engine hang — never run the
driver script and a manual client together. Commands execute on the main thread, so replies
lag while the frame loop is busy. The server keeps the socket open, so read **up to the
first newline** and stop; reading until the connection closes just burns your whole timeout.

Load with `exec start server(player - autosave/single/alife/load) client(localhost)`.

### Audio

Silence runs with `exec snd_volume_eff 0` + `exec snd_volume_music 0`. Those two cover both
branches of the only volume formula (`SoundRender_Emitter_FSM`:
`st_Effect ? psSoundVEffects*psSoundVFactor : psSoundVMusic`), so they mute everything.
**Do not use `-nosound`** — it stalls startup before the log and MCP come up.

**Evidence standard**: only *verified in-game* samples count — the load screen fakes a lot
(it orbits its own camera; `frame`/`yaw` can look alive). `fps=0.0` means
`Device.fTimeDelta <= 1e-6`, which is normal *during* loading — it is **not** a pause or a
key-gate, and no key press is needed: the same session reaches ~50 fps on its own once the
load finishes. Acceptance requires `in_game=1 && level=k00_marsh && frame>9000 && fps>5`
**and** a stable `yaw` across two polls with **no mouse nudges** (nudges rotate the player
camera and fake orbit). Screenshots land in `Anomaly/appdata/screenshots/`.

`harness/probe_run.sh <tag> [ENV=VAL ...]` automates launch → mute → load → verified-in-game
poll → screenshot → quit.

## Key files

- `src/LayersMetal/xrRenderMetal/mtlRuntime.mm` — pass manager, encoders, probes, builtin blit/fill/replay MSL
- `src/LayersMetal/mtl_device.mm` — device/layer/texture/readback
- `src/LayersMetal/mtl_state.mm` — pipeline + depth/stencil state cache
- `src/LayersMetal/xrRenderPC_Metal/` — renderer backend (phases, sun, targets)
- `src/LayersOGL/xrRender_R2/` — shared R2 renderer compiled into the Metal target
- `src/xrEngine/xr_mcp.cpp` — MCP console server
- `src/Layers/xrRender/HOM.cpp` — HOM occlusion (with `XR_METAL_NOHOM` switch)
