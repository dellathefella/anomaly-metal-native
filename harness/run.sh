#!/bin/bash
# p4: visual regression harness driver (docs/VISUAL_HARNESS.md).
#
# usage: harness/run.sh <case> [extra xr_3da args...]
#
# Launches xr_3da with -harness <cases/<case>.txt> — a timed console-command
# sequence executed by the engine's CHarnessDriver (xrEngine/harness_driver.cpp)
# at frame boundaries. The case script ends with `screenshot harness_<case>`,
# which the GL renderer writes to <game>/appdata/screenshots/. This script
# collects it into harness/captures/<renderer>/<case>.jpg.
#
# Env overrides:
#   GAME_DIR  Anomaly root (default: <repo>/../Anomaly)
#   XR3DA     engine binary (default: build-gl/bin/xr_3da)
#   RENDERER  capture bucket: gl|metal (default: gl)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(dirname "$HERE")"
GAME_DIR="${GAME_DIR:-$(cd "$ENGINE_DIR/.." && pwd)/Anomaly}"
BIN="${XR3DA:-$ENGINE_DIR/build-gl/bin/xr_3da}"
RENDERER="${RENDERER:-gl}"

CASE="${1:?usage: run.sh <case> [args...]}"; shift || true
CASE_FILE="$HERE/cases/$CASE.txt"
[ -f "$CASE_FILE" ] || { echo "no such case: $CASE ($CASE_FILE)" >&2; exit 1; }
[ -x "$BIN" ] || { echo "no engine binary: $BIN" >&2; exit 1; }

SHOT="harness_$CASE.jpg"
OUT_DIR="$HERE/captures/$RENDERER"
mkdir -p "$OUT_DIR"
rm -f "$GAME_DIR/appdata/screenshots/$SHOT"

cd "$GAME_DIR"
# RENDERER names the capture bucket AND must select the renderer module:
# EngineAPI.cpp defaults to GL (Apple's translayer) unless told otherwise, so a
# bare `RENDERER=metal ./run.sh ...` used to capture GL pixels into the metal
# bucket. Pass the matching -renderer flag.
RFLAG=""
case "$RENDERER" in
    metal) RFLAG="-renderer metal" ;;
    gl)    RFLAG="-renderer gl" ;;
esac
"$BIN" -nointro $RFLAG -harness "$CASE_FILE" "$@" || {
    echo "xr_3da exited with $? — see appdata/logs" >&2; }

SRC="$GAME_DIR/appdata/screenshots/$SHOT"
if [ -f "$SRC" ]; then
    cp "$SRC" "$OUT_DIR/$CASE.jpg"
    echo "captured: $OUT_DIR/$CASE.jpg"
else
    echo "MISSING capture: $SRC (case did not produce a screenshot)" >&2
    exit 2
fi
