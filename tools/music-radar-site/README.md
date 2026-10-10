# AI Music Radar website (music.grepawk.com)

One docroot, `/var/www/music-radar` on grepawk.com, served at:

- **https://music.grepawk.com/**: canonical. Every page's `<link rel="canonical">` points here.
- **https://grepawk.com/music-radar/**: same files, kept because the App Store marketing, support and
  privacy URLs point there (`docs/asc/metadata/en-US/*_url.txt`). Its nginx block lives in the finalcut repo.

| Source | Served as |
| --- | --- |
| `docs/explainer/index.html` | `/` (screenshots paths rewritten at deploy) |
| `docs/legal/music-radar/{support,privacy,terms}.html` | `/support`, `/privacy`, `/terms` |
| `tools/music-radar-site/static/` | `robots.txt`, `sitemap.xml`, `404.html`, `site.js`, `og-1200x630.jpg`, icons, `screenshots/*.webp` |
| `tools/music-radar-site/nginx/music.grepawk.com.conf` | `/etc/nginx/sites-available/music.grepawk.com` |

## Deploy

Push to `main` (or run **Deploy music.grepawk.com** from the Actions tab). The workflow:

1. runs `nginx/test-installer.sh` in ubuntu:22.04 (nginx 1.18, as on the droplet);
2. validates the page (one `<h1>`, canonical, JSON-LD parses, no App Store link yet) and `nginx -t`s the vhost;
3. snapshots status + headers of every API/admin route (`api-snapshot.sh`, `api-snapshot-paths.txt`);
4. rsyncs the content (`deploy-grepawk.sh`);
5. installs the vhost with `nginx/install-vhost.sh`: backup, `nginx -t`, reload, smoke (pages 200, real 404, HSTS,
   API/admin probes and every other vhost unchanged), automatic rollback on any failure;
6. re-snapshots the API (must be identical) and checks robots, sitemap, 404, HSTS and gzip.

It needs the repo secret `DEPLOY_SSH_KEY` (key for `root@grepawk.com`, the same one photo-recipes and finalcut use),
optionally `DEPLOY_SSH_KNOWN_HOSTS`. Without it the job only validates and logs a notice.

## Telemetry

`site.js` sends anonymous `web_page_view` and `web_*_click` events to this host's own `/api/telemetry/batch`
(the music-radar-api ingest): no cookies, no third parties, a random per-tab-session id, no IP stored, and nothing
sent when Do Not Track or Global Privacy Control is on. Disclosed in `privacy.html` ("This website").

## Search Console

The `grepawk.com` **Domain property** (DNS-verified) covers `music.grepawk.com`. Submit
`https://music.grepawk.com/sitemap.xml` in that property. `robots.txt` disallows `/api/`, `/admin` and their
`/music-radar/` aliases.
