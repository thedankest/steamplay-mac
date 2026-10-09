# shellcheck shell=sh
# autofix/autofix.sh: zero-per-game-setup layer for compat_run.sh (sourced, POSIX sh, set -e safe
# when called as "autofix_run ... || true").
#
# Installed copy: ~/Library/Application Support/notproton/autofix/ (this directory: autofix.sh,
# helpers.sh, verbs.sh, verbs.json, detectors.sh, pe_version.py, installscript.py).
#
# Integration in notproton/dylib/feats/compat_run.sh, in the "Per-game fixes" block, after
# fix_file=... and before "if [ "$verb" = waitforexitandrun ] && [ -r "$fix_file" ]":
#
#   autofix_dir="$HOME/Library/Application Support/notproton/autofix"
#   if [ "$verb" = waitforexitandrun ] && [ -r "$autofix_dir/autofix.sh" ]; then
#     AUTOFIX_DIR="$autofix_dir"
#     . "$autofix_dir/autofix.sh"
#     autofix_run "$1" || echo "=== autofix failed ===" >> "$log" 2>&1 || true
#   fi
#
# and right after the fix file was sourced (before target="$1"):
#
#   if command -v autofix_argv >/dev/null 2>&1; then
#     eval "set -- $(autofix_argv "$@")"
#   fi
#
# and after the game exited (after the wait loop, before kill_wine_prefix):
#
#   command -v autofix_post >/dev/null 2>&1 && { autofix_post || true; }
#
# (autofix_post reuses the exe autofix_run saw; by then "$@" holds the bundle arguments.)
#
# Variables used: $verb, "$1" (game exe, unix path), $app_id, $log, $WINEPREFIX, $WINELOADER,
# $WINESERVER, $STEAM_COMPAT_INSTALL_PATH, $fix_env (set_env appends to it, so the existing
# --env forwarding loop passes the values to the game).

AUTOFIX_DIR=${AUTOFIX_DIR:-"$HOME/Library/Application Support/notproton/autofix"}
# shellcheck source=autofix/helpers.sh
. "$AUTOFIX_DIR/helpers.sh"
# shellcheck source=autofix/verbs.sh
. "$AUTOFIX_DIR/verbs.sh"
# shellcheck source=autofix/detectors.sh
. "$AUTOFIX_DIR/detectors.sh"
