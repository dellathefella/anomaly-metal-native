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

## Live MCP run recipe (what actually drives runs today)

`xr_3da -nointro -mcp` serves a line console on `127.0.0.1:27846`
(`src/xrEngine/xr_mcp.cpp`). Sequence for a gameplay capture:

1. `exec g_always_active 1` shortly after launch (keeps `b_is_Active` true —
   macOS apps started detached never receive an activate event, and
   `OnAppDeactivate` pauses the game at startup).
2. `exec start server(player - autosave/single/alife/load) client(localhost)`
   twice (~8 s apart; the first call can arrive before the menu accepts it).
3. `key space` taps every ~15 s: the post-load story-text overlay ("Press any
   key to continue") survives without dismissal and is harmless — the game
   renders behind it. Key names come from the table in `xr_mcp.cpp` (`ESC`,
   `SPACE`, `TAB`, `ENTER`, letters, raw DIK numbers); `escape` is NOT a name
   and fails silently.
4. **Unpause = `exec main_menu on` then `exec main_menu off`.** The load screen
   leaves the game paused (`paused=1`); `pause_state` is not a registered
   command (MCP answers "OK exec" even for unknown commands — trust the
   `p5 render: frame=N paused=` probe line, not the MCP reply). `main_menu on`
   hits the `li_pause_key` unpause branch; `main_menu off` deactivates the menu
   and `mm_deactivate2` clears the pause manager for real.
5. `exec screenshot <name>` → JPEG into `Anomaly/appdata/screenshots/`.

## Storm-weather finding (launches 232–240)

The autosave's weather is `w_storm2`; Anomaly's storm descriptors
legitimately carry `sun_color=(0,0,0)` (hemi 0.32 / fog 0.35 stay alive).
`CLight_DB::Update` derives the sun from that black env, the sun-phase init
gate (`u_diffuse2s > EPS`) fails forever, and no sun accum quad is ever
drawn — the dark world is data-correct storm weather plus the paused-game
artifact above, not a Metal regression: the GL renderer renders the same
dark storm (`appdata/screenshots/gl_world1/2.jpg` vs `m239_world.jpg`).
The Lua weather manager re-forces `w_storm2` (forced=1) during gameplay and
`sv_setweather` is not registered in this build, so sun-pipeline verification
uses the temporary `XR_P5_FORCE_SUN` env override in `Light_DB.cpp`.

