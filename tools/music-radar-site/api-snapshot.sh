#!/usr/bin/env bash
# api-snapshot.sh <base-url> <paths-file> -> normalized status + headers per path (GET, no request body).
# Used by the "Deploy music.grepawk.com" workflow before and after a deploy; the two must be identical.
# Only volatile headers are dropped; HSTS and Vary are kept so static-only header changes can't leak into the API.
set -uo pipefail
base="$1"
while read -r p; do
  [[ -z "$p" || "$p" == \#* ]] && continue
  echo "== $p"
  curl -s -o /dev/null -D - -m 20 "$base$p" | tr -d '\r' \
    | sed -E 's#^HTTP/[0-9.]+ ([0-9]{3}).*#STATUS \1#; s#^([A-Za-z0-9-]+):#\L\1:#' \
    | grep -viE '^(date|etag|last-modified|content-length|server|expires|connection|x-request-id|ratelimit[a-z-]*|retry-after|set-cookie|age|alt-svc):' | grep -v '^$' | sort
done < "$2"
