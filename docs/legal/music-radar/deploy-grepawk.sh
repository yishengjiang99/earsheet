#!/usr/bin/env bash
# The legal pages are deployed together with the landing page into /var/www/music-radar
# (a separate rsync --delete would wipe the landing page). See tools/music-radar-site/deploy-grepawk.sh.
exec "$(cd "$(dirname "$0")/../../.." && pwd)/tools/music-radar-site/deploy-grepawk.sh" "$@"
