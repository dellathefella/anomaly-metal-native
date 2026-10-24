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
screen-fixed through 66° orbit; fixed-NDC fill reaches x=2645 through the same
PSO path (wvp21, 1.27M red px in position RT + screenshot); staged m_WVP
projects to maxNdcX=2.4 (NOT x-compressed) under the engine's own convention.

**Active theory:** the tilt kills every framebuffer-space mechanism
(viewport/scissor/attachments cannot tilt) — only clip-space or matrix x/y
coupling can. `XR_METAL_WVPCMP=1` (wvp28) compares the ring-slot bytes the VS
actually reads at `m_WVP` against `Device.mFullTransform` per position-pass
draw: match ⇒ matrix path closed; mismatch ⇒ the wrong matrix is dumped and
identified.

**Secondary bug found:** `mtl_R_sun.cpp` passes `Device.fASPECT` (=height/width
in Monolith convention, 0.5582) straight into `glm::perspective`, which expects
width/height — sun/shadow projections are wrong by (h/w)². Not the band
(position pass is clean of it) but queued after.

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
