#!/bin/sh
# Deploy the GL shader overlay (OpenXRay gl/ set + p4 alias .s files) into an
# Anomaly gamedata tree. Loose files override archive contents (FS precedence).
#   usage: deploy_gamedata.sh <Anomaly-root>
set -e
[ -d "$1/gamedata/shaders" ] || { echo "usage: $0 <Anomaly-root> (dir containing gamedata/)"; exit 1; }
SRC="$(cd "$(dirname "$0")/gl" && pwd)"
DST="$(cd "$1" && pwd)/gamedata/shaders/gl"
mkdir -p "$DST"
(cd "$SRC" && find . -type f -print | while read -r f; do
  mkdir -p "$DST/$(dirname "$f")"
  cp -f "$SRC/${f#./}" "$DST/$f"
done)
echo "deployed $(find "$SRC" -type f | wc -l | tr -d ' ') overlay files -> $DST"
