#!/usr/bin/env bash
# Rebuilds design/icon/eclipse-linux-circle and copies its icons into the
# project: the circle for Linux and Windows, the squircle for macOS.
# Run after changing the icon, and commit the files it writes.
set -euo pipefail
cd "$(dirname "$0")/.."

icon_python=${ECLIPSE_ICON_PYTHON:-python3}
if ! "$icon_python" -c 'import PIL' >/dev/null 2>&1; then
  icon_python="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
fi
"$icon_python" tool/generate_linux_circle_icon.py --update-project
