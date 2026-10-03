#!/usr/bin/env bash
# Deploy AI Music Radar support/privacy/terms to https://grepawk.com/music-radar/
# Files live in /var/www/music-radar (outside finalcut's dist/, so finalcut deploys don't wipe them).
# nginx: `location ^~ /music-radar/ { root /var/www; try_files $uri $uri.html $uri/ =404; }`
# in /etc/nginx/sites-available/finalcut (added 2026-10-03, backup in /root/finalcut.nginx.bak-*-music-radar).
set -euo pipefail
HOST="${MUSIC_RADAR_DEPLOY_HOST:-root@grepawk.com}"
here="$(cd "$(dirname "$0")" && pwd)"
ssh -o BatchMode=yes "$HOST" "mkdir -p /var/www/music-radar"
rsync -rlptz --delete --chmod=D755,F644 --exclude 'deploy-grepawk.sh' "$here/" "$HOST:/var/www/music-radar/"
for p in support privacy terms; do printf '%s  %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "https://grepawk.com/music-radar/$p")" "https://grepawk.com/music-radar/$p"; done
