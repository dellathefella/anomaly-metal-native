#!/bin/sh
# p4 t3: launch Anomaly on the ported GL renderer.
#
# The engine resolves fsgame.ltx from the working directory, so we run from
# the Anomaly install root; all module dylibs sit next to xr_3da (rpath
# @loader_path). Loose gamedata/ files (the GL shader overlay) take priority
# over the db archives in the X-Ray FS.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GAME="${GAME_DIR:-$HERE/../../Anomaly}"
BIN="$HERE/../build-gl/bin/xr_3da"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built (cmake --build build-gl --target xr_3da)" >&2
    exit 1
fi
if [ ! -f "$GAME/fsgame.ltx" ]; then
    echo "error: no fsgame.ltx under $GAME (set GAME_DIR)" >&2
    exit 1
fi

cd "$GAME"
exec "$BIN" "$@"
