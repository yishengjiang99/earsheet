#!/usr/bin/env bash
# Renders src/*.html to 1320x2868 PNGs (440x956 pt @3x) with headless Chrome.
# Needs the fonts DM Serif Display, Inter, Libre Caslon Text and Noto Music installed.
set -euo pipefail
cd "$(dirname "$0")"
CHROME=${CHROME:-google-chrome}
for f in src/*.html; do
  n=$(basename "$f" .html)
  "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=3 --window-size=440,956 \
    --virtual-time-budget=2000 --screenshot="$PWD/$n.png" "file://$PWD/$f" 2>/dev/null
done
ls -1 *.png
