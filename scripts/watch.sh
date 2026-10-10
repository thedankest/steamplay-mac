#!/bin/bash
# Steam update watcher (Phase 5). launchd runs a copy of this file from the LaunchAgent that
# `install.sh watch on` writes (label io.github.steamplay-mac.reapply): at login, when Steam's
# client or Steam.app changes on disk, and every few hours. It waits until Steam has stopped
# writing its files, then runs `install.sh reapply --auto`, which
#   - does nothing when nothing changed;
#   - re-installs the signatures and update blocks when Steam updated its client and a profile
#     fits (Steam.app is not touched);
#   - switches Steam Play off and notifies once when no profile fits (tools/make-signatures.md);
#   - asks in a dialog, and then hands over to Terminal, when Valve replaced Steam.app.
# It never changes Steam.app itself.
#
# Usage: steamplay-watch.sh <path to install.sh>
set -u
ENGINE="${1:-}"
NP_HOME="${NP_HOME:-$HOME}"
SUPPORT="${NP_SUPPORT:-$NP_HOME/Library/Application Support/notproton}"
INNER="${NP_STEAM_SUPPORT:-$NP_HOME/Library/Application Support/Steam}/Steam.AppBundle/Steam/Contents/MacOS"
APP="${NP_STEAM_APP:-/Applications/Steam.app}"
SETTLE="${NP_WATCH_SETTLE:-20}"        # seconds between two looks at the files
SETTLE_MAX="${NP_WATCH_SETTLE_MAX:-900}"
LOG="$SUPPORT/logs/watch.log"

mkdir -p "$SUPPORT/logs"
# Keep the log small. Truncated in place: launchd holds it open as stdout and stderr.
if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -c 262144 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG"
    rm -f "$LOG.tmp"
fi
note() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

if [ -z "$ENGINE" ] || [ ! -f "$ENGINE" ]; then
    note "install.sh not found at '$ENGINE'"
    marker="$SUPPORT/logs/.watch-engine-missing"
    if [ ! -e "$marker" ]; then
        touch "$marker"
        if [ "${NP_TEST_MODE:-0}" != 1 ]; then
            osascript -e 'display notification "The Steam update watcher cannot find install.sh (was the steamplay-mac folder moved?). Run install.sh watch on again from its new place." with title "Steam Play"' >/dev/null 2>&1 || true
        fi
    fi
    exit 0
fi
rm -f "$SUPPORT/logs/.watch-engine-missing"

# Size and mtime of what a Steam update rewrites. The same on two looks SETTLE seconds apart
# means Steam has stopped writing.
look() {
    stat -f '%N %z %m' "$INNER/steamclient.dylib" "$INNER/steamui.dylib" "$APP/Contents/Info.plist" \
        "$APP/Contents/_CodeSignature/CodeResources" 2>/dev/null
}
waited=0
prev="$(look)"
while :; do
    sleep "$SETTLE"
    waited=$((waited + SETTLE))
    cur="$(look)"
    [ "$cur" = "$prev" ] && break
    if [ "$waited" -ge "$SETTLE_MAX" ]; then
        note "files still changing after ${waited}s; trying at the next run"
        exit 0
    fi
    prev="$cur"
done

note "running reapply --auto"
/bin/bash "$ENGINE" reapply --auto >> "$LOG" 2>&1
note "reapply --auto exit $?"
exit 0
