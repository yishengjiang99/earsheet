#!/usr/bin/env bash
# One-time, on grepawk.com as root: MySQL database/user + /etc/music-radar.env. Idempotent; never overwrites an existing env file.
# Secrets are generated here and never leave the server. APNs key/team are the account-level values photo-recipes already uses.
set -euo pipefail
ENV=/etc/music-radar.env
if [ -f "$ENV" ]; then echo "$ENV exists; leaving it alone"; exit 0; fi
DBPW=$(openssl rand -hex 24)
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS music_radar CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'music_radar'@'localhost' IDENTIFIED BY '$DBPW';
ALTER USER 'music_radar'@'localhost' IDENTIFIED BY '$DBPW';
GRANT ALL PRIVILEGES ON music_radar.* TO 'music_radar'@'localhost';
FLUSH PRIVILEGES;
SQL
mkdir -p /etc/music-radar && chmod 750 /etc/music-radar && chgrp www-data /etc/music-radar
PR=/etc/photo-recipes.env
get() { grep -E "^$1=" "$PR" 2>/dev/null | head -1 | cut -d= -f2- || true; }
P8SRC=$(get APNS_P8_PATH)
APNS_LINES="# APNs not configured: set APNS_KEY_ID, APNS_TEAM_ID, APNS_P8_PATH"
if [ -n "$P8SRC" ] && [ -f "$P8SRC" ]; then
  install -m 640 -o root -g www-data "$P8SRC" /etc/music-radar/"$(basename "$P8SRC")"
  APNS_LINES="# APNs token auth (account-level key shared with photo-recipes)
APNS_KEY_ID=$(get APNS_KEY_ID)
APNS_TEAM_ID=$(get APNS_TEAM_ID)
APNS_P8_PATH=/etc/music-radar/$(basename "$P8SRC")
APNS_TOPIC=com.ragnus.pnge"
fi
umask 027
cat > "$ENV" <<ENVF
# AI Music Radar API (music-radar-api.service). root:www-data 640. Created $(date -u +%FT%TZ).
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_DATABASE=music_radar
MYSQL_USER=music_radar
MYSQL_PASSWORD=$DBPW
APPLE_BUNDLE_ID=com.ragnus.pnge
APPLE_APP_APPLE_ID=6818838017
IAP_PRODUCT_MONTHLY=com.ragnus.pnge.pro.monthly
IAP_PRODUCT_YEARLY=com.ragnus.pnge.pro.yearly
IAP_PRODUCT_LIFETIME=com.ragnus.pnge.lifetime
$APNS_LINES
# Admin panel login (https://grepawk.com/music-radar/admin)
ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
SESSION_SECRET=$(openssl rand -hex 32)
ENVF
chown root:www-data "$ENV" && chmod 640 "$ENV"
echo "created $ENV and database music_radar"
