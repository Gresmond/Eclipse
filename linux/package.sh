#!/usr/bin/env bash
# Package a prebuilt Arch x86_64 release for installation by an ordinary user.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="$PWD/build/linux/x64/release/bundle"
[[ -x $bundle/eclipse ]] || { echo 'Build the Linux release bundle first.' >&2; exit 1; }
[[ ! -e $bundle/lib/libsqlite3.so ]] || { echo 'Rebuild with the system SQLite hook in pubspec.yaml.' >&2; exit 1; }
version="$(sed -n 's/^version: *//p' pubspec.yaml)"
app_version="${version%%+*}"
build="${version#*+}"
[[ $app_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[1-9][0-9]*$ ]]
stage="$(mktemp -d "$PWD/build/user-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Eclipse"
cp -R "$bundle" "$stage/Eclipse/bundle"
rm -f "$stage/Eclipse/bundle/build-info" "$stage/Eclipse/bundle/lib/libdartjni.so"
printf '%s\n' "$app_version" > "$stage/Eclipse/bundle/version"
printf '%s\n' "$build" > "$stage/Eclipse/bundle/package-release"
install -m755 linux/install-release.sh "$stage/Eclipse/install.sh"
install -m644 linux/icons/hicolor/scalable/apps/dev.nicholas.productivity_app.svg "$stage/Eclipse/eclipse.svg"
cp -R linux/icons "$stage/Eclipse/icons"
tar --zstd -cf build/Eclipse.tar.zst -C "$stage" Eclipse
echo 'Created build/Eclipse.tar.zst'
