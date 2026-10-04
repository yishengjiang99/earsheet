#!/usr/bin/env bash
# Deploy the AI Music Radar site to https://grepawk.com/music-radar/ (the App Store marketing URL):
#   /music-radar/                 landing page   (docs/explainer/index.html)
#   /music-radar/ai-music-radar-landing.mp4 (+ -poster.jpg, the page video), ai-music-radar-tiktok.mp4,
#   ai-music-radar-explainer.mp4, poster.jpg (old explainer, kept for existing links), screenshots/*.png
#   /music-radar/support|privacy|terms           (docs/legal/music-radar/*.html)
# Both are staged together and rsynced with --delete into /var/www/music-radar, so this is the
# single deploy for that directory (docs/legal/music-radar/deploy-grepawk.sh delegates here).
#
# nginx (/etc/nginx/sites-available/finalcut on grepawk.com) already has, and needs no change for:
#   location ^~ /music-radar/api/ and ^~ /music-radar/admin -> 127.0.0.1:8790 (Node service)
#   location ^~ /music-radar/ { root /var/www; try_files $uri $uri.html $uri/ =404; }
# Longest-prefix ^~ matching keeps /api/ and /admin on the Node service; nothing staged here
# may be named api* or admin* (checked below).
#
# Usage: tools/music-radar-site/deploy-grepawk.sh [--dry-run]
set -euo pipefail
HOST="${MUSIC_RADAR_DEPLOY_HOST:-root@grepawk.com}"
DEST="${MUSIC_RADAR_DEPLOY_DIR:-/var/www/music-radar}"
URL="${MUSIC_RADAR_URL:-https://grepawk.com/music-radar/}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT

# Legal pages (support/privacy/terms); their index.html redirect is replaced by the landing page.
for f in support privacy terms; do cp "$root/docs/legal/music-radar/$f.html" "$stage/"; done
# Landing page + media. In the repo the page points at ../asc/screenshots/en-US/ (so it renders on
# GitHub); on the site the screenshots live in screenshots/ next to it.
cp "$root/docs/explainer/ai-music-radar-explainer.mp4" "$root/docs/explainer/poster.jpg" \
   "$root/docs/explainer/ai-music-radar-landing.mp4" "$root/docs/explainer/ai-music-radar-landing-poster.jpg" \
   "$root/docs/explainer/ai-music-radar-tiktok.mp4" "$stage/"
mkdir -p "$stage/screenshots"
cp "$root"/docs/asc/screenshots/en-US/iphone-69-*.png "$stage/screenshots/"
sed 's#\.\./asc/screenshots/en-US/#screenshots/#g' "$root/docs/explainer/index.html" > "$stage/index.html"

# Every local src/href/poster in the page must exist in the stage.
missing=0
for ref in $(grep -oE '(src|href|poster)="[^"#:]+"' "$stage/index.html" | sed -E 's/^[a-z]+="//; s/"$//' | sort -u); do
  [ -e "$stage/$ref" ] || { echo "missing asset: $ref" >&2; missing=1; }
done
[ "$missing" = 0 ] || exit 1
# Path-collision guard with the Node service locations.
if ls "$stage" | grep -qiE '^(api|admin)'; then echo "refusing: staged name collides with /music-radar/api or /admin" >&2; exit 1; fi

ls -la "$stage" "$stage/screenshots"
if [ "${1:-}" = "--dry-run" ]; then exit 0; fi
ssh -o BatchMode=yes "$HOST" "mkdir -p '$DEST'"
rsync -rlptz --delete --chmod=D755,F644 "$stage/" "$HOST:$DEST/"

echo "==> smoke"
for p in "" index.html poster.jpg ai-music-radar-explainer.mp4 ai-music-radar-landing.mp4 ai-music-radar-landing-poster.jpg ai-music-radar-tiktok.mp4 screenshots/iphone-69-01-hear-it.png screenshots/iphone-69-05-export.png \
         support privacy terms api/health admin; do
  printf '%s  %s\n' "$(curl -s -o /dev/null -r 0-1023 -w '%{http_code} %{content_type}' "$URL$p")" "$URL$p"
done
