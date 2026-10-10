#!/usr/bin/env bash
# Exercises install-vhost.sh against a throwaway nginx (run as root; needs nginx, curl, openssl, python3).
# Starts from the vhost exactly as it was on the server (live-music.grepawk.com.conf), plus a second
# vhost, a mock music-radar-api (on $BACKEND_PORT, default 18790) and a docroot; then checks:
#   1. a good install succeeds, adds HSTS/gzip/404 and leaves API + other vhost unchanged
#   2. re-running with the same file is a no-op
#   3. a candidate that changes API behaviour is rolled back automatically
#   4. a candidate that fails nginx -t is rolled back automatically
# CI runs it inside ubuntu:22.04 (nginx 1.18, same as the droplet).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; site="$(cd "$here/.." && pwd)"; repo="$(cd "$site/../.." && pwd)"
T="$(mktemp -d)"; chmod 755 "$T"; PORT="${HTTPS_PORT:-18443}"; BEPORT="${BACKEND_PORT:-18790}"
E="$T/etc/nginx"; mkdir -p "$E/sites-available" "$E/sites-enabled" "$T/le" "$T/www/music-radar" "$T/www/other" "$T/bk"
cleanup() { [[ -f "$T/nginx.pid" ]] && kill "$(cat "$T/nginx.pid")" 2>/dev/null || true; sleep 0.5; [[ -n "${BE:-}" ]] && kill "$BE" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout "$T/le/k.pem" -out "$T/le/c.pem" 2>/dev/null
echo "ssl_protocols TLSv1.2 TLSv1.3;" > "$T/le/options-ssl-nginx.conf"
adapt() { sed -e "s#/etc/letsencrypt/live/music.grepawk.com/fullchain.pem#$T/le/c.pem#" -e "s#/etc/letsencrypt/live/music.grepawk.com/privkey.pem#$T/le/k.pem#" \
  -e "s#/etc/letsencrypt/options-ssl-nginx.conf#$T/le/options-ssl-nginx.conf#" -e '/ssl-dhparams.pem/d' \
  -e "s#listen \[::\]:443 ssl#listen 127.0.0.1:$PORT ssl#" -e '/listen 443 ssl/d' -e "s#listen 80;#listen 127.0.0.1:18080;#" -e '/listen \[::\]:80;/d' \
  -e "s#/var/www#$T/www#g" -e "s#127.0.0.1:8790#127.0.0.1:$BEPORT#g" "$1"; }
cat > "$E/nginx.conf" <<NGX
pid $T/nginx.pid; error_log $T/error.log; events {}
http { include /etc/nginx/mime.types; default_type application/octet-stream; access_log off; gzip on;
  include $E/sites-enabled/*; }
NGX
adapt "$here/live-music.grepawk.com.conf" > "$E/sites-available/music.grepawk.com"
ln -s "$E/sites-available/music.grepawk.com" "$E/sites-enabled/music.grepawk.com"
cat > "$E/sites-enabled/other" <<NGX
server {
    listen 127.0.0.1:$PORT ssl;
    server_name other.test;
    ssl_certificate $T/le/c.pem; ssl_certificate_key $T/le/k.pem;
    root $T/www/other;
}
NGX
echo other > "$T/www/other/index.html"
# Docroot as tools/music-radar-site/deploy-grepawk.sh stages it.
S="$T/www/music-radar"
cp "$repo"/docs/legal/music-radar/{support,privacy,terms}.html "$S/"; cp -R "$site/static/." "$S/"
sed 's#\.\./asc/screenshots/en-US/#screenshots/#g' "$repo/docs/explainer/index.html" > "$S/index.html"
mkdir -p "$T/www/music-radar"; cp "$repo/docs/explainer/ai-music-radar-landing-poster.jpg" "$S/"
cat > "$T/be.py" <<'PY'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p=self.path
        if p=='/music-radar/api/health': c,b=200,{'ok':True}
        elif p.startswith('/music-radar/admin') and p.rstrip('/')=='/music-radar/admin': c,b=303,None
        elif p=='/music-radar/admin/login': c,b=200,{'login':True}
        else: c,b=404,{'error':'not found'}
        self.send_response(c)
        if c==303: self.send_header('Location','/music-radar/admin/login')
        self.send_header('Content-Type','application/json; charset=utf-8'); self.end_headers()
        if b is not None: self.wfile.write(json.dumps(b).encode())
    def log_message(self,*a): pass
import sys
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
PY
python3 "$T/be.py" "$BEPORT" & BE=$!
nginx -t -c "$E/nginx.conf" 2>/dev/null; nginx -c "$E/nginx.conf"; sleep 1
export NGINX_ETC="$E" NGINX_CONF="$E/nginx.conf" DOCROOT="$S" BACKUP_ROOT="$T/bk" HTTPS_PORT="$PORT"
run() { bash "$here/install-vhost.sh" "$1" > "$T/out.txt" 2>&1; }
pass=0; fail() { echo "TEST FAIL: $*"; cat "$T/out.txt"; exit 1; }
LIVE_BEFORE="$(cat "$E/sites-available/music.grepawk.com")"

# 1. good install
adapt "$here/music.grepawk.com.conf" > "$T/good.conf"
run "$T/good.conf" || fail "good install failed"
grep -q '^installed ' "$T/out.txt" || fail "no installed line"
cmp -s "$T/good.conf" "$E/sites-available/music.grepawk.com" || fail "good conf not in place"
grep -q "^other.test 200" "$T/out.txt" || fail "other vhost not probed"
for l in "ok   /privacy -> 200" "ok   HSTS" "ok   /this-page-does-not-exist -> 404" "ok   404 page body" "ok   API/admin probes unchanged" "ok   other vhosts unchanged"; do grep -qF "$l" "$T/out.txt" || fail "missing: $l"; done
echo "ok 1 good install"; pass=$((pass+1))

# 2. idempotent
run "$T/good.conf" || fail "re-run failed"; grep -q 'vhost unchanged' "$T/out.txt" || fail "re-run not a no-op"
echo "ok 2 re-run is a no-op"; pass=$((pass+1))

# 3. API-changing candidate rolls back (start from the good one)
sed -E 's#proxy_pass http://127.0.0.1:[0-9]+/music-radar/api/;#return 418;#' "$T/good.conf" > "$T/bad-api.conf"
echo "# v3" >> "$T/bad-api.conf"
if run "$T/bad-api.conf"; then fail "API-changing conf was accepted"; fi
grep -q 'FAIL API/admin probes changed' "$T/out.txt" || fail "API change not detected"
cmp -s "$T/good.conf" "$E/sites-available/music.grepawk.com" || fail "not rolled back after API change"
[[ "$(curl -sk --resolve music.grepawk.com:$PORT:127.0.0.1 -o /dev/null -w '%{http_code}' https://music.grepawk.com:$PORT/api/health)" == 200 ]] || fail "API not serving after rollback"
echo "ok 3 API change rolled back"; pass=$((pass+1))

# 4. nginx -t failure rolls back
sed 's#error_page 404 /404.html;#error_page 404 /404.html; bogus_directive on;#' "$T/good.conf" > "$T/bad-syntax.conf"
if run "$T/bad-syntax.conf"; then fail "invalid conf was accepted"; fi
cmp -s "$T/good.conf" "$E/sites-available/music.grepawk.com" || fail "not rolled back after nginx -t failure"
echo "ok 4 nginx -t failure rolled back"; pass=$((pass+1))
echo "all $pass installer tests passed"
