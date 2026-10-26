#!/usr/bin/env bash
# Rebuilds design/icon/first-contact-icon-suite and copies the approved
# circular First Contact icon into the Linux, macOS and Windows project assets.
# Run after changing the icon, and commit the project icons it updates
# (linux/icons, macos/Runner/Assets.xcassets, windows/runner/resources).
# Needs Pillow (python-pillow) and rsvg-convert (librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

icon_python=${ECLIPSE_ICON_PYTHON:-python3}
if ! "$icon_python" -c 'import PIL' >/dev/null 2>&1; then
  echo "make_icons.sh: $icon_python has no Pillow. Install it (sudo pacman -S python-pillow)" >&2
  echo 'or point ECLIPSE_ICON_PYTHON at a Python that has it.' >&2
  exit 1
fi
"$icon_python" design/icon/first-contact-icon-suite/build.py --update-project
