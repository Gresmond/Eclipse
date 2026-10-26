#!/usr/bin/env bash
# Releases what is committed on main: gives pubspec.yaml the next version,
# <two-digit year>.<month>.<release that month>, counting from 1 each month
# (October 2026: 26.10.1, 26.10.2, ...; January 2027: 27.1.1), and the build
# number one up, then commits, tags v<version> and pushes. The tag makes the
# Release workflow build and publish the Linux, Windows and Mac downloads.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[[ $(git branch --show-current) == main ]] || { echo 'release: switch to main first.' >&2; exit 1; }
git diff --quiet -- pubspec.yaml && git diff --cached --quiet || {
  echo 'release: commit or unstage your changes (and any edit to pubspec.yaml) first.' >&2
  exit 1
}

current="$(sed -n 's/^version: *//p' pubspec.yaml)"
IFS=. read -r major month release <<<"${current%%+*}"
build="${current#*+}"
[[ $build == "$current" ]] && build=0

year_major=$((10#$(date +%y)))
this_month=$(date +%-m)
if [[ $major == "$year_major" && $month == "$this_month" ]]; then
  release=$((release + 1))
else
  release=1
fi
version="$year_major.$this_month.$release"

sed -i "s/^version: .*/version: $version+$((build + 1))/" pubspec.yaml
git commit -q -m "Release Eclipse $version" -- pubspec.yaml
git tag "v$version"
git push -q origin main "v$version"
echo "Released v$version; GitHub is building the downloads."
