#!/bin/bash
# A fake world for the app's end-to-end tests, like tests/installer/run-tests.sh new_world: a fake
# Steam.app (ad-hoc signed stub), inner client, dist runner and Valve manifest under <dir>, with
# install.sh in test mode (it refuses any path outside <dir>; Steam control, the support build,
# the bridge fetch and D3DMetal are the installer tests' stubs). Prints the environment as
# NAME=value lines. D3DMetal asks for its (fake) licence, like Apple's disk image does.
#   fake-world.sh <empty dir>
set -euo pipefail
T="$(cd "${1:?dir}" && pwd -P)"
REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
STUBS="$REPO/tests/installer/stubs"
W="$T/w"
mkdir -p "$T/bin" "$T/ctl" "$W"
printf 'int main(void){return 0;}\n' > "$T/bin/stub.c"
clang -arch arm64 -O1 -o "$T/bin/stub" "$T/bin/stub.c"
printf 'int np_variant_a(void){return 1;}\n' > "$T/bin/a.c"
clang -arch arm64 -dynamiclib -o "$T/bin/notproton-a.dylib" "$T/bin/a.c"

HOME_DIR="$W/home"
APP="$W/Applications Dir/Steam.app"
SSUP="$HOME_DIR/Library/Application Support/Steam"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$T/bin/stub" "$APP/Contents/MacOS/steam_osx"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>steam_osx</string>
<key>CFBundleIdentifier</key><string>test.fake.steam</string>
<key>CFBundleName</key><string>Steam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1788400362</string>
</dict></plist>
PL
codesign -f -s - "$APP" 2>/dev/null
CD="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"

mkdir -p "$SSUP/Steam.AppBundle/Steam/Contents/MacOS"
echo "steamclient v1" > "$SSUP/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
echo "steamui v1" > "$SSUP/Steam.AppBundle/Steam/Contents/MacOS/steamui.dylib"
cp "$APP/Contents/Info.plist" "$SSUP/Steam.AppBundle/Steam/Contents/Info.plist"
printf 'SomeUserSetting=1\n' > "$SSUP/steam.cfg"

r="$W/dist/runners/selfbuilt-test-r1"
mkdir -p "$r/bin" "$r/lib/wine/x86_64-windows" "$r/lib/wine/i386-windows" "$r/lib/wine/x86_64-unix" "$r/share/steamplay"
printf '#!/bin/sh\necho wine-11.0\n' > "$r/bin/wine"; chmod 755 "$r/bin/wine"
printf '{\n  "id": "selfbuilt-test-r1",\n  "kind": "selfbuilt",\n  "renderers": { "dxmt": "v0.80" }\n}\n' > "$r/runner.json"
echo lsc64 > "$r/lib/wine/x86_64-windows/lsteamclient.dll"
echo lsc32 > "$r/lib/wine/i386-windows/lsteamclient.dll"
echo lscso > "$r/lib/wine/x86_64-unix/lsteamclient.so"
echo steamexe > "$r/share/steamplay/steam.exe"
{
    echo "base     file:///nonexistent"
    for rel in legacycompat/steamclient.dll steamclient.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll; do
        printf 'file %s linux %s %s\n' "$rel" "$rel" "$(printf 'fake valve %s\n' "$rel" | shasum -a 256 | cut -c1-64)"
    done
} > "$W/valve.manifest"
echo pass > "$T/ctl/anchor-mode"
echo good > "$T/ctl/log-mode"
echo license > "$T/ctl/d3d-mode"
echo a > "$T/ctl/dylib-variant"

cat <<ENV
NP_TEST_MODE=1
NP_TEST_ROOT=$T
NP_TEST_REPO=$REPO
NP_HOME=$HOME_DIR
NP_STEAM_APP=$APP
NP_STEAM_SUPPORT=$SSUP
NP_SUPPORT=$HOME_DIR/Library/Application Support/notproton
NP_BACKUP_DIR=$HOME_DIR/SteamPlayBackup
NP_CACHE=$W/cache
NP_DIST_DIR=$W/dist/runners
NP_LAUNCH_AGENTS=$HOME_DIR/Library/LaunchAgents
NP_RUNNER_ID=selfbuilt-test-r1
NP_TEST_STEAMCTL=$STUBS/steamctl
NP_TEST_BUILD_SUPPORT=$STUBS/build-support
NP_TEST_FETCH_BRIDGE=$STUBS/fetch-bridge
NP_TEST_D3DMETAL_SCRIPT=$STUBS/d3dmetal
NP_TEST_VALVE_MANIFEST=$W/valve.manifest
NP_TEST_TEAMID_OVERRIDE=MXGJJ98X76@$CD
NP_POLL_INTERVAL=0.1
NP_QUIT_TIMEOUT=2
NP_VERIFY_TIMEOUT=2
NP_MIN_FREE_GB=1
ENV
