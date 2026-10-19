# Divergence map: X-Ray Monolith (Anomaly 1.5.3) vs its base

Baseline for comparison: `SeargeDP/coc-1.4-xray-64` (OpenXRay Call of Chernobyl
Edition, last commit 2018-07-01) — the upstream that Anomaly's X-Ray Monolith
engine forked from. Monolith HEAD: `028ccf5` (2024-09-18, "Anomaly 1.5.3").

## Per-module divergence (diff -rq monolith/src vs searge-coc/src)

| Module              | added by Anomaly | removed | modified | notes |
|---------------------|-----------------:|--------:|---------:|-------|
| xrGame              |             31   |   266   |  2633    | game logic effectively rewritten; the reason we host on Monolith, not on OpenXRay dev |
| Layers (renderers)  |             66   |     9   |   557    | DX9 R1–R4 + DX9/DX10 layers; Anomaly render features (SSR, HBBO, DFD, 3DSS/PIP scopes) |
| xrEngine            |              1   |    82   |   170    | engine core services |
| xrServerEntities    |              0   |     5   |   154    | |
| xrPhysics           |              0   |     0   |   150    | ODE-based (bundled `3rd party/ode`), x86 SIMD (xrCPU_Pipe/ttapi) |
| xrCore              |              4   |    16   |   158    | platform layer divergence point |
| xrCDB               |              0   |     0   |    84    | |
| xrSound             |              0   |    12   |    33    | **already OpenAL-based** (`SoundRender_TargetA*`) — audio port nearly free |
| xrCPU_Pipe          |              0   |     0   |    23    | CPU detect + SIMD glue (x86 asm) — replace/skip on arm64 |
| xrServer/XRNetServer|              —   |     —   |    ~19   | |
| xrParticles         |              —   |     —   |    ~18   | |
| xrXMLParser         |              —   |     —   |     ~8   | |

## Windows/MSVC dependency surface (grep, monolith/src)

- `windows.h` includes: 31 files total — only **6 in xrCore**
  (`xrCore_platform.h`, `LocatorAPI.cpp`, `PPMdType.h`, `rt_miniacc.h`,
  `blackbox/BugslayerUtil.h`, `blackbox/stdafx_.h`), 2 in xrCPU_Pipe, plus
  3rd-party. OpenXRay's Linux port rewrote these same files → backport target.
- DirectX header usage: ~92 files, nearly all inside `Layers/` (renderer) —
  expected; renderer layers get replaced (GL first, then Metal).
- x86 intrinsics/asm: ~58 files (xrCPU_Pipe, physics SIMD, a few engine spots).
- Audio: OpenAL already (3rd party bundles OpenAL-Windows binaries only →
  use openal-soft).
- Bundled deps in `3rd party/`: luajit-2, luabind, ode, tbb, icu, cximage,
  NVTT, discord, crypto, DXERR — mostly source, buildable.

## Strategy (decided)

1. **Platform → Monolith**: keep Monolith's xrGame/Lua API intact (2600+ files
   of Anomaly logic), backport OpenXRay dev's CMake + POSIX xrCore + SDL2 layer.
2. **Renderer staging**: port OpenXRay `xrRenderGL`/`xrRenderPC_GL` into the
   Monolith tree to reach a playable game; then build native
   **xrRenderMetal** (DXC HLSL→SPIR-V, SPIRV-Cross→MSL) to full parity.

## Environment notes (macOS 26.6 / Xcode CLT only, Apple Silicon)

- OpenXRay dev baseline: configure needs `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`
  (LuaJIT make chokes on Darwin 25/26 three-part `MACOSX_DEPLOYMENT_TARGET`).
- Upstream `Externals/LuaJIT-proj/CMakeLists.txt` hardcodes
  `/Applications/Xcode.app/.../MacOSX.sdk`; on CLT-only machines the linker
  then fails parsing the Xcode SDK `.tbd` files (`arm64e.x1` unknown arch).
  Patched to use `xcrun --show-sdk-path` (see `patches/`).
