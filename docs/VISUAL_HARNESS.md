# Visual Regression Harness (p4 t5)

Deterministic screenshot-based validation for the ported GL renderer and the
upcoming native Metal renderer. Catches the classic port regressions:
gamma/tone-mapping shifts, flipped textures (V-axis), wrong blend states,
missing shader features, letterbox/DPI scaling bugs.

## How it works

1. **Deterministic boot profile** — `harness/run.sh <renderer> <case>` launches
   `xr_3da` with a fixed `-fso`-style user config generated per case:
   fixed resolution (1280x720, non-Retina for byte-stable goldens), fixed
   weather/time via a scripted console command list, `seed`-pinned scene,
   `-nointro` and disabled randomness cvars where available.
2. **Scripted captures** — cases are Lua snippets driven through the engine's
   script console plus the ported screenshot path
   (`screenshot_manager` → the renderer's GL screenshot family → PNG/JPEG into
   `harness/captures/<renderer>/<case>.png`).
3. **Goldens** — first accepted run per renderer stores
   `harness/goldens/<renderer>/<case>.png`. GL goldens are the reference set
   for the Metal parity audit (p5): same case scripts, per-renderer golden dirs.
4. **Diff/contact sheet** — `harness/diff.py` compares captures vs goldens
   (per-pixel max delta + PSNR + a heatmap overlay) and emits
   `harness/reports/<run>/contact.png` with pass/fail per case and the heatmap
   for failures, so a regression localizes to a screen region immediately.

## Case list (minimum)

| case | what it pins down |
|---|---|
| `menu_main` | UI shaders, fonts, gamma, letterbox math |
| `game_newgame_day_clear` | base r2 deferred pipeline, sun shadows |
| `game_night_rain` | emissives, rain blender, wetness |
| `game_sunset_fog` | fog/color grading, tone-mapping |
| `inventory_open` | PDA/secondVP RT path (t2 stub — must show known-gap marker) |
| `scope_3dss` | Anomaly 3DSS scope path (PIP/RT correctness) |
| `hud_effects` | HUD immediate-mode visual path, wallmarks |
| `grass_details` | detail-manager instancing |

## Known-gap markers

Engine-side stubs (real sky, dev console, F3 stats overlay, PDA RT) are listed
in `harness/known_gaps.txt`; diff.py downgrades those regions to "warn" instead
of "fail" so real regressions stay visible while the gaps are closed.

## Metal parity (p5)

`harness/run.sh metal` produces captures against `goldens/gl/` with a looser
PSNR threshold (documented per case) — structural agreement, not bit-exactness,
is the parity criterion; bit-exactness within a renderer is the regression
criterion.

Status: design agreed with the p4 t5 task; implementation lands with the first
successful launch (the screenshot path it drives only exists at runtime).
