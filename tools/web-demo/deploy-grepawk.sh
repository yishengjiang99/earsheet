#!/usr/bin/env bash
# Deploy the EarSheet web demo to https://grepawk.com/music-hear/
#
# Builds web/ (vendor bundle + pinned Basic Pitch model) and rsyncs it to
# /var/www/music-hear on grepawk.com. nginx serves it from the grepawk.com
# server block (/etc/nginx/sites-available/finalcut) via a one-time
# `location ^~ /music-hear/ { root /var/www; ... }` block, kept outside the
# finalcut dist/ directory so finalcut deploys (rsync --delete + vite build) don't wipe it.
#
# Usage: tools/web-demo/deploy-grepawk.sh [--skip-build]
set -euo pipefail

HOST="${MUSIC_HEAR_DEPLOY_HOST:-root@grepawk.com}"
DEST="${MUSIC_HEAR_DEPLOY_DIR:-/var/www/music-hear}"
URL="${MUSIC_HEAR_URL:-https://grepawk.com/music-hear/}"
here="$(cd "$(dirname "$0")" && pwd)"
web="$here/../../web"

if [[ "${1:-}" != "--skip-build" ]]; then
  (cd "$here" && npm ci --silent && node build.mjs)
fi
test -f "$web/vendor/lib.js" && test -f "$web/model/model.json" || { echo "web/ not built" >&2; exit 1; }

ssh -o BatchMode=yes "$HOST" "mkdir -p '$DEST'"
rsync -rlptz --delete --chmod=D755,F644 --exclude '.gitignore' --exclude '.nojekyll' \
  "$web/" "$HOST:$DEST/"

echo "==> smoke"
for p in "" app.js quantize.js vendor/lib.js vendor/abcjs-basic-min.js vendor/tfjs-backend-wasm-simd.wasm model/model.json model/group1-shard1of1.bin; do
  printf '%s  %s\n' "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$URL$p")" "$URL$p"
done
