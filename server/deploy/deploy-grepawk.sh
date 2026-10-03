#!/usr/bin/env bash
# Deploy the AI Music Radar API to grepawk.com (https://grepawk.com/music-radar/api/, admin at /music-radar/admin).
#   - code:    /var/www/music-radar-api (dist/, migrations/, certs/, production node_modules)
#   - service: music-radar-api.service (www-data, 127.0.0.1:8790, BASE_PATH=/music-radar); migrations run on start
#   - secrets: /etc/music-radar.env (root:www-data 640) — created once by --bootstrap, never overwritten
#   - nginx:   location blocks in /etc/nginx/sites-available/finalcut (inserted once, backed up, nginx -t before reload)
# Usage: server/deploy/deploy-grepawk.sh [--bootstrap]
set -euo pipefail
HOST="${MUSIC_RADAR_API_HOST:-root@grepawk.com}"
DEST=/var/www/music-radar-api
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
npm ci --silent && npm run -s build
ssh -o BatchMode=yes "$HOST" "mkdir -p $DEST"
rsync -rlptz --delete --chmod=D755,F644 dist migrations certs package.json package-lock.json "$HOST:$DEST/"
scp -q deploy/music-radar-api.service "$HOST:/etc/systemd/system/music-radar-api.service"
scp -q deploy/nginx-music-radar-api.conf "$HOST:/tmp/nginx-music-radar-api.conf"
[ "${1:-}" = "--bootstrap" ] && scp -q deploy/bootstrap-remote.sh "$HOST:/tmp/music-radar-bootstrap.sh" && ssh "$HOST" "bash /tmp/music-radar-bootstrap.sh && rm -f /tmp/music-radar-bootstrap.sh"
ssh -o BatchMode=yes "$HOST" 'set -e
cd /var/www/music-radar-api && npm ci --omit=dev --silent
test -f /etc/music-radar.env || { echo "missing /etc/music-radar.env (run with --bootstrap)"; exit 1; }
C=/etc/nginx/sites-available/finalcut
if ! grep -q "location ^~ /music-radar/api/" $C; then
  cp -p $C /root/finalcut.nginx.bak-$(date +%Y%m%d-%H%M%S)-music-radar-api
  python3 - "$C" <<"PY"
import sys
p = sys.argv[1]; s = open(p).read()
anchor = "    # AI Music Radar support/privacy/terms"
assert s.count(anchor) == 1, "anchor not found"
open(p, "w").write(s.replace(anchor, open("/tmp/nginx-music-radar-api.conf").read() + anchor))
PY
  nginx -t && systemctl reload nginx
fi
rm -f /tmp/nginx-music-radar-api.conf
systemctl daemon-reload && systemctl enable -q music-radar-api && systemctl restart music-radar-api
sleep 2; systemctl is-active music-radar-api'
curl -fsS https://grepawk.com/music-radar/api/health; echo
