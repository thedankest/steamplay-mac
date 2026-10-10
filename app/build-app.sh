#!/bin/bash
# Builds "Steam Play.app" from this Swift package: release build at background priority, -j4,
# then a bundle with Info.plist, ad-hoc signed. Downloads nothing (the package has no
# dependencies). Output: app/dist/Steam Play.app
#   app/build-app.sh [--test]     --test also runs the unit tests first
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
run() { taskpolicy -b nice -n 19 "$@"; }
if [ "${1:-}" = --test ]; then run swift test -j 4; fi
run swift build -c release -j 4 --product SteamPlay
bin="$(swift build -c release --show-bin-path)/SteamPlay"
app="$HERE/dist/Steam Play.app"
rm -rf "$app.new"
mkdir -p "$app.new/Contents/MacOS" "$app.new/Contents/Resources"
cp "$bin" "$app.new/Contents/MacOS/SteamPlay"
cp Info.plist "$app.new/Contents/Info.plist"
codesign -f -s - --options runtime "$app.new"
rm -rf "$app"
mv "$app.new" "$app"
codesign --verify --strict "$app"
echo "$app"
