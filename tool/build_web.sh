#!/usr/bin/env bash
# Builds the web version into build/web. Pass --local for one with no server
# behind it, to look at with tool/serve_web.py: no sign-in, data in the browser.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

defines=()
[[ ${1:-} == --local ]] && defines+=(--dart-define=ECLIPSE_LOCAL=true)

flutter build web --wasm --release --no-web-resources-cdn --pwa-strategy=none "${defines[@]}"

cd build/web
version="$(sed -n 's/^version: *//p' ../../pubspec.yaml)"
# What opens the app offline. CanvasKit is only for browsers without WasmGC.
find . -type f \
  ! -path './canvaskit/canvaskit*' ! -path './canvaskit/skwasm_heavy*' ! -path './canvaskit/chromium/*' \
  ! -path './canvaskit/wimp*' ! -path './canvaskit/webparagraph/*' ! -path './assets/NOTICES' \
  ! -name flutter.js ! -name flutter_service_worker.js ! -name sw.js ! -name precache.json \
  ! -name .precache.list ! -name _headers ! -name '*.symbols' ! -name main.dart.js ! -name .last_build_id \
  | sed 's#^\./##' | sort > .precache.list
python3 -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin]))' < .precache.list > precache.json
hash="$(xargs -d '\n' sha256sum < .precache.list | sha256sum | cut -c1-8)"
rm -f .precache.list
# Stamp a unique cache version and update comment so browsers fetch the new list.
sed -i "s/__ECLIPSE_VERSION__/${version}-${hash}/g" sw.js
printf '\n// %s-%s\n' "$version" "$hash" >> sw.js
