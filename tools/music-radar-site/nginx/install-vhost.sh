#!/usr/bin/env bash
# Guarded installer for the music.grepawk.com nginx vhost. Runs ON the server as root (the
# "Deploy music.grepawk.com" workflow copies this file and the conf over SSH and runs it).
#
#   install-vhost.sh <new-conf>
#
# 1. Preflight: cert files the conf references must exist; the docroot must have index.html + 404.html.
# 2. Snapshot (before): status + content-type of every API/admin probe on this host, and the status
#    of "/" on every other nginx server_name (so we can prove we didn't break other vhosts).
# 3. Back up the live file, install the new one, `nginx -t`, reload.
# 4. Smoke: static pages 200, unknown path 404 with the 404 page, HSTS on "/", API/admin probes and
#    other vhosts identical to the snapshot.
# 5. Any failure -> restore the backup, nginx -t, reload, exit 1.
set -euo pipefail
NEW="${1:?usage: install-vhost.sh <new-conf>}"
HOST=music.grepawk.com
# Overridable only for tests/nginx/music-vhost-installer.test.sh; production uses the defaults.
NGINX_ETC="${NGINX_ETC:-/etc/nginx}"
NGINX_CONF="${NGINX_CONF:-}"
SITE=$NGINX_ETC/sites-available/$HOST
ENABLED=$NGINX_ETC/sites-enabled/$HOST
DOCROOT="${DOCROOT:-/var/www/music-radar}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BK_DIR="${BACKUP_ROOT:-/var/backups/music-grepawk-nginx}/$TS"
ngx_test() { nginx -t ${NGINX_CONF:+-c "$NGINX_CONF"}; }
ngx_reload() { if [[ -z "$NGINX_CONF" ]] && command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then systemctl reload nginx; else nginx ${NGINX_CONF:+-c "$NGINX_CONF"} -s reload; fi; }
PORT="${HTTPS_PORT:-443}"
R=(--resolve "$HOST:$PORT:127.0.0.1" -sk -m 15)

log() { printf '%s\n' "$*"; }
die() { log "FAIL: $*" >&2; exit 1; }

# ---- preflight
[[ -f "$NEW" ]] || die "missing $NEW"
grep -q "server_name $HOST;" "$NEW" || die "conf has no server_name $HOST"
for f in $(grep -oE '/etc/letsencrypt/[^ ;]+' "$NEW" | sort -u); do [[ -e "$f" ]] || die "conf references missing $f"; done
[[ -f "$DOCROOT/index.html" ]] || die "$DOCROOT/index.html missing (deploy content first)"
[[ -f "$DOCROOT/404.html" ]] || die "$DOCROOT/404.html missing (deploy content first)"
[[ -L "$ENABLED" || -f "$ENABLED" ]] || die "$ENABLED not enabled; refusing to create a new site here"
if cmp -s "$NEW" "$SITE"; then log "vhost unchanged; nothing to install"; exit 0; fi

API_PATHS=(/api/health /api/iap/products /api/iap/entitlement /api/ /api/nope /admin /admin/login /adminx
           /music-radar /music-radar/api/health /music-radar/admin/login /music-radar/api/nope)
api_snapshot() { local p; for p in "${API_PATHS[@]}"; do
  printf '%s %s\n' "$p" "$(curl "${R[@]}" -o /dev/null -w '%{http_code} %{content_type} %{redirect_url}' "https://$HOST:$PORT$p")"; done; }
others_snapshot() { local n; for n in $(grep -rhoE '^\s*server_name\s+[^;]+' "$NGINX_ETC/sites-enabled/" 2>/dev/null \
    | sed -E 's/^\s*server_name\s+//' | tr ' ' '\n' | grep -E '^[a-z0-9.-]+\.[a-z]+$' | grep -vx "$HOST" | sort -u || true); do
  printf '%s %s\n' "$n" "$(curl --resolve "$n:$PORT:127.0.0.1" -sk -m 15 -o /dev/null -w '%{http_code}' "https://$n:$PORT/")"; done; }

API_BEFORE="$(api_snapshot)"; OTHERS_BEFORE="$(others_snapshot)"
log "== API/admin probes (before)"; log "$API_BEFORE"
log "== other vhosts (before)"; log "$OTHERS_BEFORE"


mkdir -p "$BK_DIR"; cp -a "$SITE" "$BK_DIR/$HOST.conf"
restore() {
  log "!! restoring $SITE from $BK_DIR"
  cp -a "$BK_DIR/$HOST.conf" "$SITE"
  ngx_test && ngx_reload && sleep 2 && log "restored previous vhost: / -> $(curl "${R[@]}" -o /dev/null -w "%{http_code}" "https://$HOST:$PORT/" || true), /api/health -> $(curl "${R[@]}" -o /dev/null -w "%{http_code}" "https://$HOST:$PORT/api/health" || true)"
  exit 1
}
trap 'log "error on line $LINENO"; restore' ERR

# Explicit checks (an ERR trap does not fire for failures inside functions without set -E).
install -m 0644 "$NEW" "$SITE" || restore
ngx_test || { log "nginx -t rejected the new vhost"; restore; }
ngx_reload || { log "nginx reload failed"; restore; }
sleep 2

fails=0
chk() { local got; got="$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "https://$HOST:$PORT$1" || true)"
  if [[ "$got" == "$2" ]]; then log "ok   $1 -> $got"; else log "FAIL $1 -> $got (want $2)"; fails=$((fails+1)); fi; }
for p in / /privacy /terms /support /robots.txt /sitemap.xml /site.js /og-1200x630.jpg /music-radar/ /music-radar/privacy; do chk "$p" 200; done
chk /this-page-does-not-exist 404
curl "${R[@]}" "https://$HOST:$PORT/this-page-does-not-exist" | grep -q 'Page not found' && log "ok   404 page body" || { log "FAIL 404 page body"; fails=$((fails+1)); }
curl "${R[@]}" -D - -o /dev/null "https://$HOST:$PORT/" | tr -d '\r' | grep -qi '^strict-transport-security: max-age=31536000' && log "ok   HSTS" || { log "FAIL HSTS"; fails=$((fails+1)); }
API_AFTER="$(api_snapshot)"; OTHERS_AFTER="$(others_snapshot)"
if [[ "$API_AFTER" == "$API_BEFORE" ]]; then log "ok   API/admin probes unchanged"; else log "FAIL API/admin probes changed:"; diff <(echo "$API_BEFORE") <(echo "$API_AFTER") || true; fails=$((fails+1)); fi
if [[ "$OTHERS_AFTER" == "$OTHERS_BEFORE" ]]; then log "ok   other vhosts unchanged"; else log "FAIL other vhosts changed:"; diff <(echo "$OTHERS_BEFORE") <(echo "$OTHERS_AFTER") || true; fails=$((fails+1)); fi

if (( fails > 0 )); then trap - ERR; restore; fi
trap - ERR
log "installed $SITE (backup: $BK_DIR)"
