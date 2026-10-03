#!/usr/bin/env bash
# Download the pinned fine-tuned TF.js model (ft-model.lock.json) from its GitHub
# release into web/model-ft/. build.mjs then verifies the sha256 pins. Needs `gh` auth
# (the repo is private). No-op when no model is pinned.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
web="$here/../../web"
read -r tag asset < <(python3 -c "import json;j=json.load(open('$here/ft-model.lock.json'));print(j['tag'] or '', j['asset'] or '')")
[ -n "$tag" ] || { echo "no fine-tuned model pinned"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" -R yishengjiang99/earsheet -p "$asset" -D "$tmp"
rm -rf "$web/model-ft" && mkdir -p "$web/model-ft"
unzip -q "$tmp/$asset" -d "$web/model-ft"
echo "fetched $tag/$asset -> web/model-ft"
