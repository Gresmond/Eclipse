#!/usr/bin/env bash
# Builds Eclipse and installs it for the current user, with a launcher entry
# and icon, so it opens from the app menu like any other app.
# Run it again to update to the latest code. With --bundle it installs the
# release bundle already built by `flutter run --release` instead.
set -euo pipefail
cd "$(dirname "$0")/.."

# Must match APPLICATION_ID in linux/CMakeLists.txt, so the desktop matches
# the running window to this launcher and its icon.
app_id=dev.nicholas.productivity_app
prefix="${XDG_DATA_HOME:-$HOME/.local/share}"
dest="$HOME/.local/opt/eclipse"

flutter="$(command -v flutter || echo "$HOME/development/flutter/bin/flutter")"
# Taken before building, so a commit made mid-build still counts as new.
commit="$(git rev-parse HEAD 2>/dev/null || true)"
[[ ${1:-} == --bundle ]] || "$flutter" build linux --release
# The database format this build writes; an installed copy older than the
# data can't open it, so `flutter run` builds reinstall when it's behind.
schema="$(sed -n 's/.*static const schemaVersion = \([0-9]*\);.*/\1/p' lib/data/store.dart)"

rm -rf "$dest"
mkdir -p "$dest"
cp -R build/linux/x64/release/bundle/. "$dest/"

# Lets the app notice when this folder has newer commits than it was
# built from, and offer to run this script again.
printf 'repo=%s\ncommit=%s\nschema=%s\n' "$PWD" "$commit" "$schema" > "$dest/build-info"

mkdir -p "$prefix/icons/hicolor"
cp -R linux/icons/hicolor/. "$prefix/icons/hicolor/"

install -Dm644 /dev/stdin "$prefix/applications/$app_id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Eclipse
Comment=Habits, to-dos and a journal
Exec=$dest/eclipse
Icon=$app_id
StartupWMClass=$app_id
Categories=Office;
Keywords=habits;todo;planner;journal;
DESKTOP

update-desktop-database -q "$prefix/applications" 2>/dev/null || true
gtk-update-icon-cache -q -t "$prefix/icons/hicolor" 2>/dev/null || true

echo "Installed Eclipse to $dest"
