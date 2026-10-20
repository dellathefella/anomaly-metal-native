#!/bin/sh
# p4 t4: deploy the GL shader overlay (OpenXRay gl/ set + Anomaly l_shader
# alias scripts) into the Anomaly install's loose gamedata tree.
#
# Anomaly ships zero GLSL shaders; the ported OpenXRay GL renderer loads its
# shader set from $game_shaders$\gl\, so the overlay must sit next to the
# game's own shader tree (loose files win over archives in the X-Ray FS).
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GAME="${1:-$HERE/../../Anomaly}"
DEST="$GAME/gamedata/shaders/gl"

if [ ! -d "$GAME/gamedata" ]; then
    echo "error: no gamedata under $GAME (pass the Anomaly dir as \$1)" >&2
    exit 1
fi

mkdir -p "$DEST"
# --delete keeps the overlay authoritative: stale strays from older overlay
# versions would otherwise shadow engine lookups.
rsync -a --delete "$HERE/shader-overlay/gl/" "$DEST/"
echo "deployed $(find "$DEST" -type f | wc -l | tr -d ' ') files -> $DEST"

# p4 t6: mac options overlay — patched ui_options.script (perf row, DX-only
# rows trimmed) + its string-table keys. Loose scripts/text dirs shadow the
# game's archives in the X-Ray FS. Never touch configs/ root: axr_options.ltx
# (the user's live settings) lives there.
rsync -a --delete "$HERE/ui-overlay/scripts/" "$GAME/gamedata/scripts/"
rsync -a --delete "$HERE/ui-overlay/configs/text/" "$GAME/gamedata/configs/text/"
echo "deployed ui overlay -> $GAME/gamedata/scripts + configs/text"
