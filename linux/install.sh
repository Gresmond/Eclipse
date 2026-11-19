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

mkdir -p "$(dirname "$dest")"
stage="$(mktemp -d "$(dirname "$dest")/.eclipse-install.XXXXXX")"
backup=''
cleanup() {
  rm -rf "$stage"
  if [[ -n $backup && -e $backup ]]; then
    if [[ ! -e $dest ]]; then
      mv -T "$backup" "$dest"
    else
      rm -rf "$backup"
    fi
  fi
}
trap cleanup EXIT

cp -R build/linux/x64/release/bundle/. "$stage/"
# The whole icon font, not the build's cut-down one: a repeat build can keep an
# old cut that lacks a newly used icon, and the desktop then borrows another
# font's symbol for it.
cp "$(dirname "$(readlink -f "$flutter")")/cache/artifacts/material_fonts/MaterialIcons-Regular.otf" \
  "$stage/data/flutter_assets/fonts/MaterialIcons-Regular.otf"

# Lets the app notice when this folder has newer commits than it was
# built from, and offer to run this script again.
printf 'repo=%s\ncommit=%s\nschema=%s\n' "$PWD" "$commit" "$schema" > "$stage/build-info"

if [[ -e $dest ]]; then
  backup="$(mktemp -u "$(dirname "$dest")/.eclipse-old.XXXXXX")"
  mv -T "$dest" "$backup"
fi
mv -T "$stage" "$dest"
if [[ -n $backup ]]; then
  rm -rf "$backup"
  backup=''
fi

mkdir -p "$prefix/icons/hicolor"
cp -R linux/icons/hicolor/. "$prefix/icons/hicolor/"

exec_path="$dest/eclipse"
exec_path="${exec_path//\\/\\\\}"
exec_path="${exec_path//\"/\\\"}"
exec_path="${exec_path//\$/\\\$}"
exec_path="${exec_path//\`/\\\`}"
exec_path="${exec_path//%/%%}"
exec_path="${exec_path//\\/\\\\}"
install -Dm644 /dev/stdin "$prefix/applications/$app_id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Eclipse
Comment=Habits, to-dos and a journal
Exec="$exec_path"
Icon=$app_id
StartupWMClass=$app_id
Categories=Office;
Keywords=habits;todo;planner;journal;
DESKTOP

update-desktop-database -q "$prefix/applications" 2>/dev/null || true
gtk-update-icon-cache -q -t "$prefix/icons/hicolor" 2>/dev/null || true

echo "Installed Eclipse to $dest"
