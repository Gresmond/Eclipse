#!/usr/bin/env bash
# Distributed as Eclipse/install.sh beside the prebuilt bundle. No root needed.
set -euo pipefail
cd "$(dirname "$0")"
[[ $(id -u) != 0 ]] || { echo 'Run this installer as your normal user, without sudo.' >&2; exit 1; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'This download requires x86_64 Linux (Arch or an Arch-based distribution).' >&2; exit 1; }
root="$HOME/.local/opt/eclipse-release"
if [[ $# != 0 ]]; then
  [[ $# == 2 && $1 == --update && $2 == "$root" ]] || { echo 'Unexpected installation location or arguments.' >&2; exit 1; }
fi
app_id=dev.nicholas.productivity_app
prefix="${XDG_DATA_HOME:-$HOME/.local/share}"
[[ $prefix == /* ]] || { echo 'XDG_DATA_HOME must be an absolute path.' >&2; exit 1; }
version="$(cat bundle/version)"
build="$(cat bundle/package-release)"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[1-9][0-9]*$ && -x bundle/eclipse && -f eclipse.svg ]]
# Check before changing the active installation. SQLite is loaded dynamically.
missing=''
for binary in bundle/eclipse bundle/lib/*.so; do
  [[ -e $binary ]] || continue
  dependencies="$(ldd "$binary" 2>&1)" || { echo "Cannot inspect runtime dependencies: $binary" >&2; exit 1; }
  absent="$(awk '/not found/ {print $1}' <<< "$dependencies")"
  [[ -z $absent ]] || missing+="$absent"$'\n'
done
if ! /usr/bin/ldconfig -p 2>/dev/null | awk '/libsqlite3\.so / {found=1} END {exit !found}'; then
  missing+=$'libsqlite3.so\n'
fi
if [[ -n $missing ]]; then
  printf 'Missing runtime libraries:\n%s\nOn Arch, install the required dependencies once:\nsudo pacman -S --needed gtk3 libdbusmenu-glib sqlite libglvnd libx11 xdg-utils\nThen run this installer again.\n' "$missing" >&2
  exit 1
fi
# Versioned directories leave the running copy untouched. Switching current is atomic.
mkdir -p "$root/releases" "$prefix/applications" "$prefix/icons/hicolor/scalable/apps"
stage="$(mktemp -d "$root/releases/$version-$build.XXXXXX")"
link="$root/.current-$(basename "$stage")"
committed=false
cleanup() {
  rm -f "$link"
  if [[ $committed == false ]]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
cp -R bundle/. "$stage/"
printf '%s\n' "$root" > "$stage/user-install-root"
# Desktop Exec has its own quoting rules, including field-code percent escapes.
exec_path="$root/current/eclipse"
exec_path="${exec_path//\\/\\\\}"
exec_path="${exec_path//\"/\\\"}"
exec_path="${exec_path//\$/\\\$}"
exec_path="${exec_path//\`/\\\`}"
exec_path="${exec_path//%/%%}"
# Desktop string values also require backslashes to be escaped.
exec_path="${exec_path//\\/\\\\}"
cat > "$stage/launcher.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Eclipse
Comment=Habits, to-dos and a journal
Exec="$exec_path"
Icon=$app_id
StartupWMClass=$app_id
Categories=Office;
Keywords=habits;todo;planner;journal;
Terminal=false
DESKTOP
install -m644 eclipse.svg "$prefix/icons/hicolor/scalable/apps/$app_id.svg"
if [[ -d icons/hicolor ]]; then
  cp -R icons/hicolor/. "$prefix/icons/hicolor/"
fi
install -m644 "$stage/launcher.desktop" "$prefix/applications/$app_id.desktop"
previous="$(readlink "$root/current" 2>/dev/null || true)"
ln -s "$stage" "$link"
mv -Tf "$link" "$root/current"
committed=true
# Keep the new copy and the one that may still be running; older ones go.
for old in "$root/releases"/*; do
  [[ $old == "$stage" || $old == "$previous" ]] || rm -rf -- "$old"
done
update-desktop-database -q "$prefix/applications" 2>/dev/null || true
gtk-update-icon-cache -q -t "$prefix/icons/hicolor" 2>/dev/null || true
echo "Installed Eclipse $version to $root/current"
echo 'Open Eclipse from your application menu. Future updates install without a password.'
