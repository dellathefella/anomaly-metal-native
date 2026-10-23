#!/bin/bash
# p6 band-hunt helper: launch xr_3da with a given env, load the autosave over
# MCP, wait for a verified in-game state, screenshot, quit.
#
# usage: probe_run.sh <tag> [ENV=VAL ...]
# The screenshot lands in Anomaly/appdata/screenshots/probe_<tag>.jpg
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(dirname "$HERE")"
GAME_DIR="${GAME_DIR:-$(cd "$ENGINE_DIR/.." && pwd)/Anomaly}"
BIN="$ENGINE_DIR/build-gl/bin/xr_3da"

TAG="${1:?usage: probe_run.sh <tag> [ENV=VAL ...]}"; shift || true
declare -a ENVS=("$@")

pkill -9 -x xr_3da 2>/dev/null; sleep 2
rm -f "$GAME_DIR/appdata/screenshots/probe_$TAG.jpg"

LOG="$GAME_DIR/appdata/logs/probe_$TAG.log"
cd "$GAME_DIR"
# NOTE `-renderer metal` is mandatory: EngineAPI.cpp picks the renderer from
# "-renderer metal|gl", then $XR_RENDERER, and DEFAULTS TO GL (the Apple OpenGL
# translayer). Launch without it and you are screenshotting/profiling GL while
# believing it is Metal.
# NOTE: do NOT add -nosound; it stalls startup before the log/MCP come up.
# Audio is silenced with cvars below instead - snd_volume_eff and
# snd_volume_music cover both branches of the only volume formula
# (SoundRender_Emitter_FSM: st_Effect ? eff*factor : music).
if [ ${#ENVS[@]} -gt 0 ]; then
    env "${ENVS[@]}" "$BIN" -nointro -renderer metal -mcp > "$LOG" 2>&1 &
else
    "$BIN" -nointro -renderer metal -mcp > "$LOG" 2>&1 &
fi
PID=$!
echo "launched pid=$PID tag=$TAG env=${ENVS[*]:-none}"

mcp() { python3 -c "
import socket,sys,time
s=socket.create_connection(('127.0.0.1',27846),timeout=15)
s.sendall((sys.argv[1]+'\n').encode())
s.settimeout(20)
d=b''
try:
    while True:
        b=s.recv(65536)
        if not b: break
        d+=b
except Exception: pass
sys.stdout.write(d.decode('utf-8','replace'))
" "$1" 2>/dev/null; }

# Silence audio as soon as the control server answers (pure cvars, no engine
# hack). Tried before and after the wait loop because the earliest attempts may
# land before the console exists.
mcp 'exec snd_volume_eff 0'   >/dev/null
mcp 'exec snd_volume_music 0' >/dev/null

# wait for the control server
for i in $(seq 1 90); do
    R=$(mcp ping); case "$R" in pong*) echo "mcp up: $R"; break;; esac
    sleep 2
done
mcp 'exec snd_volume_eff 0'   >/dev/null
mcp 'exec snd_volume_music 0' >/dev/null

mcp 'exec start server(player - autosave/single/alife/load) client(localhost)' >/dev/null
echo "load issued; waiting for verified in-game state..."

# NOTE: no unconditional key taps here. They were added for a 'pause gate' that
# turned out to be the GL translayer, not a gate. Tapping ESC/RETURN during a
# level load opens the pause menu / aborts, so keys are only tapped once we are
# actually in-game with a stalled frame clock (see the poll loop).
mcp 'exec snd_volume_eff 0'   >/dev/null
mcp 'exec snd_volume_music 0' >/dev/null

# Verified-in-game gate per the project's evidence standard:
# in_game=1, level=k00_marsh, frame>9000, fps>5, and a STABLE yaw across polls.
PREV_YAW=""; STABLE=0
for i in $(seq 1 150); do
    S=$(mcp state)
    case "$S" in *"in_game=1"*"fps="*) ;; *) sleep 4; continue;; esac
    FG=$(echo "$S" | sed -n 's/.*frame=\([0-9]*\).*/\1/p')
    FPS=$(echo "$S" | sed -n 's/.*fps=\([0-9.]*\).*/\1/p')
    LVL=$(echo "$S" | sed -n 's/.*level=\([^ ]*\).*/\1/p')
    YAW=$(echo "$S" | sed -n 's/.*yaw=\([^ ]*\).*/\1/p')
    if [ "$LVL" = "k00_marsh" ] && [ "${FG:-0}" -gt 9000 ] \
       && python3 -c "import sys;sys.exit(0 if float('${FPS:-0}')>5 else 1)" 2>/dev/null; then
        if [ "$YAW" = "$PREV_YAW" ]; then STABLE=$((STABLE+1)); else STABLE=0; fi
        PREV_YAW="$YAW"
        if [ $STABLE -ge 2 ]; then echo "VERIFIED IN-GAME: $S"; break; fi
    else
        PREV_YAW="$YAW"
    fi
    # Only tap keys when genuinely in-game AND the frame clock is stalled; never
    # during loading, where ESC/RETURN would open the pause menu.
    if [ "$LVL" = "k00_marsh" ] && python3 -c "import sys;sys.exit(0 if float('${FPS:-0}')<=0.5 else 1)" 2>/dev/null; then
        mcp 'key RETURN' >/dev/null
    fi
    [ $((i % 10)) -eq 0 ] && echo "  poll $i: frame=$FG fps=$FPS level=$LVL yaw=$YAW"
    sleep 4
done

mcp "screenshot probe_$TAG" >/dev/null
echo "screenshot requested; settling..."; sleep 6
mcp quit >/dev/null; sleep 4
pkill -9 -x xr_3da 2>/dev/null
echo "shot: $GAME_DIR/appdata/screenshots/probe_$TAG.jpg"
ls -la "$GAME_DIR/appdata/screenshots/probe_$TAG.jpg" 2>/dev/null || echo "NO SCREENSHOT PRODUCED"
