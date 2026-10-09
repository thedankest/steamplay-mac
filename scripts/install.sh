#!/bin/bash
# steamplay-mac installer (Phase 3). Design: INSTALLER-DESIGN.md. Uses NotProton's support layout:
#   ~/Library/Application Support/notproton/{runners/<ver>,runners/current,bridge,signatures,...}
#
#   install.sh all [--from dist|release] [--gptk-dmg PATH] [--plan]
#                                  everything: runner, D3DMetal, bridge, support files, signature
#                                  gate, backup + patch Steam.app, block updates, verify.
#                                  --plan only prints the plan and its confirmation token and
#                                  writes nothing (no lock, log or state). --gptk-dmg takes
#                                  D3DMetal from Apple's GPTK 4.0b2 disk image (default: GPTK 3.0).
#   install.sh doctor [--json] [--quick]
#                                  read-only checks; exit 0 OK, 1 FAIL, 2 warnings
#   install.sh uninstall [--remove-runners] [--remove-global-env] [--remove-prefixes]
#                                  restore Valve's Steam.app from the backup, undo everything else
#   install.sh reapply [--auto]    after a Steam update (the Phase 5 LaunchAgent runs this)
#   install.sh status
#   install.sh journal-clear       mark an interrupted run as handled (after doctor checks out)
# Low-level (kept for compatibility):
#   install.sh support [--gptk-dmg PATH] [runner-id]
#                                  runner, bridge, signatures, helpers from local build output
#                                  (refused once install.sh all has run)
#   install.sh steam               patch Steam.app (refused unless a verified backup is recorded)
#   install.sh block-updates       block bootstrapper updates in both steam.cfg files
#   install.sh hud on|off          Apple's Metal HUD for every game
#   install.sh uninstall-steam     restore Steam.app only (backup if recorded, else legacy detach)
#
# Global options (anywhere on the command line):
#   --json                  progress events on stdout (one JSON object per line), human text on
#                           stderr. NP_PROGRESS_FD=<n> sends the same events to fd n instead and
#                           keeps human text on stdout.
#   --confirmed-plan <tok>  a confirmation token (repeatable); same as NP_CONFIRM_TOKEN=<tok,...>
#
# GUI interface (stable, schema 1)
#   Events, one per line:
#     {"event":"step","id":"<step>","title":"…","status":"start|ok|warn|fail|skip","detail":"…"}
#     {"event":"confirm","id":"<prompt id>","text":"<exactly what the user must be shown>","token":"<sha256>"}
#        D3DMetal licence: {"event":"confirm","id":"d3dmetal_license","text":…,"license_path":"…",
#        "token":"<sha256 of the licence file>","env":"NP_D3DMETAL_LICENSE_TOKEN"}
#     {"event":"plan","op":"all","text":"…","token":"…"}           (all --plan)
#     {"event":"notify","text":"…"}
#     {"event":"result","op":"<command>","status":"ok|fail|needs_confirmation|pending|plan|interrupted","exit":N,"detail":"…"}
#   Step ids of `all`: preflight runner d3dmetal runner_install bridge support gate confirm
#   support_install quit_steam backup patch signatures block_updates register verify.
#   Signatures: only the profile anchorcheck marks as the live client is installed, after a
#   successful patch; a failed gate on a patched Steam.app moves them to signatures.disabled-<ts>
#   so no hooks load until reapply passes.
#   Confirmations: there is no --yes. A prompt is satisfied by a token, by "yes" typed on a
#   terminal (not with --json), or (test mode only) NP_TEST_ANSWER_<ID>. The token is
#   sha256("<id>\n<text>"), so it confirms only the exact text that was shown: the app runs the
#   command, gets a confirm event and exit 3, shows the text in its own dialog and, if the user
#   agrees, re-runs with --confirmed-plan <token> (or NP_CONFIRM_TOKEN). If anything in the plan
#   changed in between (Steam.app's cdhash, the runner, ...), the token no longer matches and the
#   engine asks again. The D3DMetal licence is accepted only with NP_D3DMETAL_LICENSE_TOKEN = the
#   SHA-256 of the licence file the app displayed. Prompt ids: plan, start_steam, uninstall,
#   restore_newest, restore_valve, detach, remove_prefixes, journal_clear, steam.
#   Exit codes: 0 ok, 1 failed (Steam.app unchanged or rolled back), 3 needs confirmation,
#   130 interrupted (rolled back). doctor: 0 OK, 1 FAIL, 2 warnings.
#   doctor --json (or doctor under --json) prints one line:
#     {"event":"doctor","schema":1,"verdict":"ok|warn|fail","exit":0|1|2,"quick":bool,
#      "checks":[{"id":"…","verdict":"ok|warn|fail|skip","detail":"…"}, …]}
#   Check ids: rosetta state journal steam_app insert dylib_hash codesign leftovers backup gate
#   client_changed last_session run_script runner runner_manifest d3dmetal bridge
#   update_block_outer update_block_inner autofix fixes global_env.
#
# Paths (env overrides; defaults in brackets):
#   NP_HOME [$HOME]  NP_STEAM_APP [/Applications/Steam.app]
#   NP_STEAM_SUPPORT [$NP_HOME/Library/Application Support/Steam]
#   NP_SUPPORT [$NP_HOME/Library/Application Support/notproton]  NP_BACKUP_DIR [$NP_HOME/SteamPlayBackup]
#   NP_CACHE [repo downloads/]  NP_DIST_DIR [repo dist/runners]  NP_LAUNCH_AGENTS [$NP_HOME/Library/LaunchAgents]
#   NP_RUNNER_ID [selfbuilt-cx26.3-r1]  NP_ADOPT_BACKUP (backup to adopt for a pre-patched Steam.app)
#   NP_VERIFY_TIMEOUT [180]  NP_QUIT_TIMEOUT [60]  NP_MIN_FREE_GB [4]
# Test mode (NP_TEST_MODE=1, tests/installer only): every path above must be set and lie under
#   NP_TEST_ROOT (a temp dir); Steam control, the support build, the bridge fetch, D3DMetal and
#   lsregister are replaced by NP_TEST_STEAMCTL, NP_TEST_BUILD_SUPPORT, NP_TEST_FETCH_BRIDGE,
#   NP_TEST_D3DMETAL_SCRIPT, NP_TEST_LSREGISTER; NP_TEST_TEAMID_OVERRIDE=TEAM@cdhash makes a fake
#   bundle count as Valve-signed; NP_TEST_FAIL_AT=<point> injects a failure. None of these are
#   honoured without NP_TEST_MODE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib"
# shellcheck source=lib/common.sh
. "$LIB/common.sh"
# shellcheck source=lib/state.sh
. "$LIB/state.sh"
# shellcheck source=lib/steamapp.sh
. "$LIB/steamapp.sh"
# shellcheck source=lib/gate.sh
. "$LIB/gate.sh"
# shellcheck source=lib/runner.sh
. "$LIB/runner.sh"

NP_ROLLBACK=""
NP_ROLLBACK_HASH=""
NP_ROLLBACK_VALVE=0
NP_RESULT_STATUS=""
NP_RESULT_DETAIL=""
NP_DIE_MSG=""
NP_STEAM_WAS_RUNNING=0
VERIFY_FAILED=0

install_file() { # src dst
    mkdir -p "$(dirname "$2")"
    cp -f "$1" "$2.new" && mv -f "$2.new" "$2"
}

# ---------------------------------------------------------------------------------------------
# Exit: roll Steam.app back if a patch was in flight, close the journal, clean staging, emit the
# result event, release the lock.
np_on_exit() {
    local rc=$? st p
    # No signal may cut the rollback or the journal update short (children inherit this too).
    trap '' INT TERM HUP
    trap - EXIT
    # shellcheck disable=SC2034 # read by np_critical_end (common.sh)
    NP_IN_EXIT=1
    set +e
    # A copy cut off mid-way (Ctrl-C during ditto) is not left behind as a hidden bundle.
    if [ -n "${SA_RESTORE_TMP:-}" ] && [ -e "$SA_RESTORE_TMP" ]; then rm -rf "$SA_RESTORE_TMP"; fi
    if [ -n "${SA_BACKUP_PARTIAL:-}" ] && [ -e "$SA_BACKUP_PARTIAL" ]; then rm -rf "$SA_BACKUP_PARTIAL"; fi
    SA_RESTORE_TMP="" SA_BACKUP_PARTIAL=""
    if [ -n "$NP_ROLLBACK" ]; then
        warn "restoring Steam.app from $NP_ROLLBACK"
        if np_test_mode && [ "${NP_TEST_ROLLBACK_SIGNAL:-0}" = 1 ]; then
            say "test: sending SIGINT, SIGTERM and SIGHUP to the rollback"
            kill -INT $$; kill -TERM $$; kill -HUP $$
        fi
        if sa_restore "$NP_ROLLBACK" "$NP_ROLLBACK_HASH" "$NP_ROLLBACK_VALVE" failed; then
            if np_test_mode && [ "${NP_TEST_ROLLBACK_SIGNAL:-0}" = 1 ]; then
                # sa_restore ran np_critical_end; signals must still be ignored here.
                say "test: signals again after the rollback's swap"
                kill -INT $$; kill -HUP $$
            fi
            say "Steam.app restored to its state before this run"
            [ "$NP_JOURNAL_OPEN" = 1 ] && journal_end failed "rolled back: ${NP_DIE_MSG:-exit $rc}"
        else
            warn "ROLLBACK FAILED. Steam.app may be half patched. The copy to restore by hand is $NP_ROLLBACK"
            [ "$NP_JOURNAL_OPEN" = 1 ] && journal_end failed_rollback "${NP_DIE_MSG:-exit $rc}"
        fi
        NP_ROLLBACK=""
        [ "$rc" = 0 ] && rc=1
    fi
    if [ "$NP_JOURNAL_OPEN" = 1 ]; then
        case "$rc" in
            0) journal_end "done" ;;
            3) journal_end aborted "needs confirmation" ;;
            *) journal_end failed "${NP_DIE_MSG:-exit $rc}" ;;
        esac
    fi
    for p in ${NP_CLEANUP_DIRS[@]+"${NP_CLEANUP_DIRS[@]}"}; do
        case "$p" in "$NP_SUPPORT"/*) rm -rf "$p" ;; esac
    done
    case "$rc" in
        0) st="${NP_RESULT_STATUS:-ok}" ;;
        3) st=needs_confirmation ;;
        130) st=interrupted ;;
        *) st=fail ;;
    esac
    [ -n "$NP_OP" ] && np_result "$st" "$rc" "${NP_RESULT_DETAIL:-$NP_DIE_MSG}"
    np_unlock
    exit "$rc"
}

np_begin() { # op
    NP_OP="$1"
    np_lock
    np_open_log "$1"
    state_init
}

# confirm_or_exit <id> <text>: exit 3 when a confirmation is needed, 1 when declined.
confirm_or_exit() {
    local rc=0
    np_confirm "$1" "$2" || rc=$?
    case "$rc" in
        0) return 0 ;;
        3) NP_RESULT_DETAIL="needs confirmation: $1"; exit 3 ;;
        *) NP_DIE_MSG="not confirmed ($1); nothing changed"; exit 1 ;;
    esac
}

backup_hash_for() { # path -> recorded tree hash
    [ -n "$1" ] && state_exists || return 0
    jq -r --arg p "$1" '[.steam.backups[]? | select(.path == $p) | .tree_sha256][0] // empty' "$NP_STATE_FILE"
}

# ---------------------------------------------------------------------------------------------
preflight() {
    local major d avail
    [ "$(uname -m)" = arm64 ] || step_fail "Apple Silicon only"
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -le 27 ] || step_fail "macOS $major: Runner A needs Rosetta 2, which ends after macOS 27 (Runner B is Phase 6)"
    arch -x86_64 /usr/bin/true 2>/dev/null || step_fail "Rosetta 2 is missing: softwareupdate --install-rosetta"
    command -v jq >/dev/null || step_fail "jq is missing (/usr/bin/jq ships with macOS 15 and later)"
    runner_need_zstd || step_fail "zstd is missing: brew install zstd"
    d="$NP_SUPPORT"
    while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
    avail="$(df -Pk "$d" | awk 'NR==2 {print int($4/1048576)}')"
    [ "$avail" -ge "$NP_MIN_FREE_GB" ] || step_fail "only ${avail} GB free, ${NP_MIN_FREE_GB} GB needed"
    [ -f "$NP_INNER_MACOS/steamclient.dylib" ] || step_fail "Steam's client is not downloaded yet ($NP_INNER_MACOS): start Steam once, log in, quit it, then run this again"
    CLASS="$(sa_classify "$NP_STEAM_APP")"
}

plan_text_all() { # from runner-version profile
    printf 'Install Steam Play (Runner A) into Steam on this Mac:\n'
    printf -- '- Steam.app: %s (%s, version %s, cdhash %s)\n' "$NP_STEAM_APP" "$CLASS" "$(sa_version "$NP_STEAM_APP")" "$(sa_cdhash "$NP_STEAM_APP")"
    printf -- '- Steam is asked to quit (never force-killed).\n'
    case "$CLASS" in
        pristine) printf -- '- A full copy of Steam.app goes to %s/Steam.app.<date> and is checked (signature, Valve TeamID %s, tree hash) before anything changes.\n' "$NP_BACKUP_DIR" "$NP_VALVE_TEAM" ;;
        adoptable) printf -- '- Steam.app is already patched (earlier manual install). %s (Valve-signed, tree %s) becomes the recorded original; the current Steam.app is first copied to %s/Steam.app.prepatch-<date>.\n' "$ADOPT_BK" "$ADOPT_HASH" "$NP_BACKUP_DIR" ;;
        ours) printf -- '- Steam.app is already patched by this installer; if the dylib changed it is replaced after a snapshot to %s/Steam.app.prepatch-<date>.\n' "$NP_BACKUP_DIR" ;;
    esac
    printf -- '- notproton.dylib goes into Steam.app with an Info.plist insert, and Steam.app is re-signed ad hoc. That replaces Valve'"'"'s signature until uninstall restores the backup; macOS may ask again for Input Monitoring.\n'
    printf -- '- Steam bootstrapper updates are blocked in both steam.cfg files (previous versions kept).\n'
    printf -- '- Runner: %s %s into %s/runners.\n' "$1" "$2" "$NP_SUPPORT"
    if [ -n "${NP_GPTK_DMG:-}" ]; then
        printf -- '- D3DMetal from %s (Apple GPTK disk image; its licence is shown first).\n' "$NP_GPTK_DMG"
    else
        printf -- '- D3DMetal from the GPTK 3.0 tarball (Gcenx repack, pinned), unless the runner already has D3DMetal with a licence record; Apple'"'"'s licence is asked for first.\n'
    fi
    printf -- '- The signature profile of the installed Steam client (anchorcheck over %s) must match it and resolve every anchor first, or nothing is changed.\n' "$3"
    printf 'Undo: scripts/install.sh uninstall\n'
}

# ---------------------------------------------------------------------------------------------
support_dobby() {
    local tgz="$NP_CACHE/dobby-5dfc8546954c.tar.gz"
    if [ ! -f "$ROOT/notproton/vendor/dobby/CMakeLists.txt" ]; then
        mkdir -p "$NP_CACHE" "$ROOT/notproton/vendor/dobby"
        local want=01a417233c40929aa21098c8a9724c00f6f05b5cde3f11abcac84b8e00053748
        if [ -f "$tgz" ] && [ "$(np_sha256 "$tgz")" != "$want" ]; then
            warn "cached $tgz has the wrong hash; deleting it"
            rm -f "$tgz"
        fi
        if [ ! -f "$tgz" ]; then
            rm -f "$tgz.part"
            np_quiet curl -fsSL --proto '=https' --proto-redir '=https' -o "$tgz.part" \
                https://github.com/jmpews/Dobby/archive/5dfc8546954ce3b3198132ab13fddb89ee92cdd7.tar.gz || { rm -f "$tgz.part"; return 1; }
            [ "$(np_sha256 "$tgz.part")" = "$want" ] || { rm -f "$tgz.part"; warn "Dobby tarball hash mismatch"; return 1; }
            mv -f "$tgz.part" "$tgz" || return 1
        fi
        tar -xzf "$tgz" -C "$ROOT/notproton/vendor/dobby" --strip-components 1 || return 1
    fi
    np_quiet make -C "$ROOT/notproton" dobby
}

# Builds dylib, helpers and anchorcheck into a staging dir, plus signatures and fixes.
support_build() { # stage
    local st="$1" p f
    rm -rf "$st" || return 1
    mkdir -p "$st/signatures/macos.arm64" "$st/fixes" || return 1
    if np_test_mode; then
        np_quiet "$NP_TEST_BUILD_SUPPORT" "$st" || { warn "test support build failed"; return 1; }
    else
        # Our changes to the notproton submodule (patches/notproton/*.patch), applied once as a
        # series (same helper as scripts/build-all.sh).
        np_quiet "$ROOT/scripts/apply-notproton-patches.sh" || { warn "applying patches/notproton failed (see the log)"; return 1; }
        [ -f "$ROOT/notproton/build/dobby/libdobby.a" ] || support_dobby || { warn "building Dobby failed (see the log)"; return 1; }
        np_quiet make -C "$ROOT/notproton" out/notproton.dylib overlay-shim iconmaker appinfo out/anchorcheck \
            || { warn "make in notproton failed (see the log)"; return 1; }
        for f in notproton.dylib overlay-shim.dylib iconmaker appinfo anchorcheck; do
            cp -f "$ROOT/notproton/out/$f" "$st/$f" || return 1
        done
        np_quiet clang -O2 -mmacosx-version-min=14.0 -o "$st/pe-d3d" "$ROOT/notproton/helpers/pe-d3d.c" || { warn "pe-d3d build failed"; return 1; }
        np_quiet swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework IOKit \
            -o "$st/syshud" "$ROOT/notproton/helpers/syshud.swift" || { warn "syshud build failed"; return 1; }
    fi
    cp -f "$NP_SIG_SRC"/*.json "$st/signatures/macos.arm64/" || { warn "no signatures in $NP_SIG_SRC"; return 1; }
    for f in "$NP_FIXES_SRC"/*.sh; do
        [ -f "$f" ] || continue
        if sh -n "$f" 2>/dev/null; then cp -f "$f" "$st/fixes/" || return 1; else warn "fix ${f##*/} does not parse (sh -n); skipped"; fi
    done
    autofix_stage "$st/autofix" || return 1
    sed -n 's/.*NOTPROTON_VERSION[^"]*"\([^"]*\)".*/\1/p' "$ROOT/notproton/dylib/version.h" | head -1 > "$st/dylib.version" || return 1
    [ -s "$st/dylib.version" ] || { warn "no NOTPROTON_VERSION in notproton/dylib/version.h"; return 1; }
    for f in notproton.dylib overlay-shim.dylib iconmaker appinfo pe-d3d syshud anchorcheck; do
        [ -s "$st/$f" ] || { warn "build produced no $f"; return 1; }
    done
    [ -x "$st/anchorcheck" ] || { warn "anchorcheck is not executable"; return 1; }
    return 0
}

# Installs exactly one profile, the one the gate found for the live client, replacing the whole
# signatures dir: the dylib loads the highest-numbered profile it finds, so with one profile it
# loads the one that was checked. Checked again after the swap.
signatures_install() { # dir with the profile, profile file name
    local src="$1" prof="$2" new="$NP_SUPPORT/signatures.new" old="$NP_SUPPORT/.signatures.old-$$"
    [ -n "$prof" ] && [ -f "$src/$prof" ] || { warn "no profile '$prof' to install"; return 1; }
    rm -rf "$new" || return 1
    mkdir -p "$new/macos.arm64" || return 1
    cp -f "$src/$prof" "$new/macos.arm64/" || return 1
    np_critical_begin
    if [ -e "$NP_SUPPORT/signatures" ]; then mv "$NP_SUPPORT/signatures" "$old" || { np_critical_end; return 1; }; fi
    if ! mv "$new" "$NP_SUPPORT/signatures"; then
        if [ -e "$old" ]; then mv "$old" "$NP_SUPPORT/signatures" || warn "the old signatures stay at $old"; fi
        np_critical_end
        return 1
    fi
    np_critical_end
    rm -rf "$old" "$NP_SUPPORT"/signatures.disabled-* || return 1
    [ "$(gate_profile "$NP_SUPPORT/signatures/macos.arm64")" = "$prof" ] || { warn "the dylib would not load $prof"; return 1; }
    state_exists || return 0   # legacy 'support' keeps no state
    state_update '.client.signatures = {profile: $p, disabled: false, at: $__now}' --arg p "$prof"
}

# After a failed gate on a patched Steam.app: take the signatures away, so the dylib loads no
# profile and installs no hooks at all (steamui hooks would otherwise install partially).
signatures_disable() { # reason
    local d
    d="$NP_SUPPORT/signatures.disabled-$(np_stamp)"
    if [ -d "$NP_SUPPORT/signatures" ]; then
        mv "$NP_SUPPORT/signatures" "$d" || { warn "could not disable the signatures"; return 1; }
    else
        d="$(state_get '.client.signatures.moved_to')"
    fi
    state_update '.client.signatures = {profile: null, disabled: true, reason: $r, moved_to: $d, at: $__now}' --arg r "$1" --arg d "$d"
    warn "signatures disabled ($d): Steam Play stays off until install.sh reapply passes the gate"
}

support_install() { # stage
    local st="$1" f
    for f in notproton.dylib overlay-shim.dylib iconmaker appinfo pe-d3d syshud dylib.version; do
        install_file "$st/$f" "$NP_SUPPORT/$f" || return 1
    done
    install_file "$st/anchorcheck" "$NP_SUPPORT/tools/anchorcheck" || return 1
    # make signs it already; signing again keeps it valid and identical to what goes into Steam.app
    "$NP_CODESIGN" --verify "$NP_SUPPORT/notproton.dylib" >/dev/null 2>&1 \
        || np_quiet "$NP_CODESIGN" -f -s - "$NP_SUPPORT/notproton.dylib" || return 1
    chmod 755 "$NP_SUPPORT/tools/anchorcheck" "$NP_SUPPORT/iconmaker" "$NP_SUPPORT/appinfo" "$NP_SUPPORT/pe-d3d" "$NP_SUPPORT/syshud" || return 1
    state_update '.support = {files: $f, run_script_sha256: $rs, version: $v, at: $__now} | .dylib_version = $v' \
        --argjson f "$(jq -n --arg d "$(np_sha256 "$NP_SUPPORT/notproton.dylib")" --arg o "$(np_sha256 "$NP_SUPPORT/overlay-shim.dylib")" \
            --arg i "$(np_sha256 "$NP_SUPPORT/iconmaker")" --arg a "$(np_sha256 "$NP_SUPPORT/appinfo")" \
            --arg p "$(np_sha256 "$NP_SUPPORT/pe-d3d")" --arg s "$(np_sha256 "$NP_SUPPORT/syshud")" \
            --arg c "$(np_sha256 "$NP_SUPPORT/tools/anchorcheck")" \
            '{"notproton.dylib": $d, "overlay-shim.dylib": $o, iconmaker: $i, appinfo: $a, "pe-d3d": $p, syshud: $s, "tools/anchorcheck": $c}')" \
        --arg rs "$(np_sha256 "$NP_RUN_SCRIPT_SRC")" --arg v "$(cat "$st/dylib.version")"
}

# --- autofix (notproton/autofix in the support dir, sourced by the run script) -------------------
NP_AUTOFIX_FILES="autofix.sh helpers.sh detectors.sh verbs.sh verbs.json NOTICE.umu-protonfixes"

autofix_stage() { # dest dir
    local d="$1" f
    rm -rf "$d" && mkdir -p "$d" || return 1
    for f in $NP_AUTOFIX_FILES; do
        [ -f "$ROOT/autofix/$f" ] || { warn "autofix/$f is missing"; return 1; }
        cp -f "$ROOT/autofix/$f" "$d/$f" || return 1
    done
    for f in "$ROOT"/autofix/*.py; do
        [ -f "$f" ] && { cp -f "$f" "$d/" || return 1; }
    done
    for f in "$d"/*.sh; do
        sh -n "$f" 2>/dev/null || { warn "autofix/${f##*/} does not parse (sh -n)"; return 1; }
    done
    jq -e . "$d/verbs.json" >/dev/null 2>&1 || { warn "autofix/verbs.json is not valid JSON"; return 1; }
}

# Installs a staged autofix dir as $NP_SUPPORT/autofix with autofix.files.sha256 and VERSION
# ("autofix <first 12 of the manifest's sha256> (repo <commit>)").
autofix_install() { # staged dir
    local src="$1" new="$NP_SUPPORT/autofix.new" old="$NP_SUPPORT/.autofix.old-$$" ver
    rm -rf "$new" && cp -R "$src" "$new" || return 1
    ( set -o pipefail; cd "$new" && find . -type f ! -name autofix.files.sha256 ! -name VERSION -print0 \
        | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) > "$new/autofix.files.sha256" || return 1
    ver="autofix $(np_sha256 "$new/autofix.files.sha256" | cut -c1-12) (repo $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    printf '%s\n' "$ver" > "$new/VERSION" || return 1
    np_critical_begin
    if [ -e "$NP_SUPPORT/autofix" ]; then mv "$NP_SUPPORT/autofix" "$old" || { np_critical_end; return 1; }; fi
    if ! mv "$new" "$NP_SUPPORT/autofix"; then
        if [ -e "$old" ]; then mv "$old" "$NP_SUPPORT/autofix" || warn "the old autofix stays at $old"; fi
        np_critical_end
        return 1
    fi
    np_critical_end
    rm -rf "$old" || return 1
    state_exists || return 0
    state_update '.support.autofix = {version: $v, manifest_sha256: $m, files: $f, at: $__now}' \
        --arg v "$ver" --arg m "$(np_sha256 "$NP_SUPPORT/autofix/autofix.files.sha256")" \
        --argjson f "$(np_files_json "$NP_SUPPORT/autofix")"
}

# global.env defaults, each only if the file has no line for that name yet (a user's own value,
# or a deliberate removal noted as "#NAME=...", is never overridden).
NP_GLOBAL_ENV_DEFAULTS="ROSETTA_ADVERTISE_AVX=1 WINEMSYNC=1"
global_env_defaults() {
    local env="$NP_SUPPORT/global.env" kv name
    if [ ! -e "$env" ]; then
        printf '%s\n' "# Defaults for every game, one NAME=value per line (a game's launch options win)." \
            "# Names: CX_GRAPHICS*, CX_FWD_COMPAT_GL_CTX, D3DM_*, DXMT_*, DXVK_*, MTL_*, NOTPROTON_*, ROSETTA_*, WINE*." \
            > "$env" || return 1
    fi
    for kv in $NP_GLOBAL_ENV_DEFAULTS; do
        name="${kv%%=*}"
        grep -Eq "^[[:space:]]*#?[[:space:]]*$name=" "$env" && continue
        printf '%s\n' "$kv" >> "$env" || return 1
    done
}

register_files() { # stage
    local st="$1" f
    mkdir -p "$NP_SUPPORT/fixes"
    for f in "$st"/fixes/*.sh; do
        [ -f "$f" ] || continue
        install_file "$f" "$NP_SUPPORT/fixes/${f##*/}" || return 1
    done
    autofix_install "$st/autofix" || { warn "installing autofix failed"; return 1; }
    global_env_defaults || { warn "could not write the global.env defaults"; return 1; }
    ln -sfn "$RUNNER_VER" "$NP_SUPPORT/runners/current"
    state_update '.current = $v' --arg v "$RUNNER_VER"
}

# ---------------------------------------------------------------------------------------------
# Quit Steam, back up (or snapshot), patch. A failure while patching restores the snapshot
# (np_on_exit), and so does Ctrl-C.
steam_patch_flow() { # class [adopt-backup adopt-hash]
    local class="$1" dylib="$NP_SUPPORT/notproton.dylib" app="$NP_STEAM_APP" rb rbh valve=0 team cd ver
    step_start quit_steam "Quitting Steam"
    if sa_steam_running; then
        NP_STEAM_WAS_RUNNING=1
        sa_quit_steam || step_fail "Steam did not quit within ${NP_QUIT_TIMEOUT}s. Quit it yourself and run this again (it is never force-killed)."
        step_end ok "Steam quit"
    else
        step_end ok "Steam is not running"
    fi
    # The gate checked the client before Steam quit; a client that changed meanwhile (Steam
    # updating itself on the way out) was never checked.
    local gate_sc="$GATE_SC_SHA" gate_ui="$GATE_UI_SHA"
    gate_client_hashes
    if [ "$GATE_SC_SHA" != "$gate_sc" ] || [ "$GATE_UI_SHA" != "$gate_ui" ]; then
        step_fail "Steam's client changed while Steam was quitting (an update?). Nothing was changed; run this again so the gate checks the new client."
    fi

    step_start backup "Backing up Steam.app"
    case "$class" in
        pristine)
            team="$(sa_team "$app")"
            cd="$(sa_cdhash "$app")"
            ver="$(sa_version "$app")"
            sa_backup "$app" original || step_fail "the backup failed or did not verify; Steam.app was not touched"
            state_update '.steam.backups += [{path: $p, kind: "original", created_at: $__now, tree_sha256: $h, team: $t, cdhash: $c, version: $v}]
                | .steam.active_backup = $p | .steam.original = {version: $v, team: $t, cdhash: $c, tree_sha256: $h} | .steam.app = $app' \
                --arg p "$SA_BK_PATH" --arg h "$SA_BK_HASH" --arg t "$team" --arg c "$cd" --arg v "$ver" --arg app "$app"
            rb="$SA_BK_PATH" rbh="$SA_BK_HASH" valve=1
            step_end ok "verified backup: $SA_BK_PATH"
            ;;
        adoptable|ours)
            if [ "$class" = adoptable ]; then
                sa_backup_ok "$2" "$3" || step_fail "$2 no longer verifies"
                state_update '.steam.backups += [{path: $p, kind: "original", adopted: true, created_at: $__now, tree_sha256: $h, team: $t, cdhash: $c, version: $v}]
                    | .steam.active_backup = $p | .steam.original = {version: $v, team: $t, cdhash: $c, tree_sha256: $h} | .steam.app = $app' \
                    --arg p "$2" --arg h "$3" --arg t "$(sa_team "$2")" --arg c "$(sa_cdhash "$2")" --arg v "$(sa_version "$2")" --arg app "$app"
            fi
            sa_backup "$app" snapshot || step_fail "the pre-patch snapshot failed; Steam.app was not touched"
            state_update '.steam.backups += [{path: $p, kind: "snapshot", created_at: $__now, tree_sha256: $h}]' \
                --arg p "$SA_BK_PATH" --arg h "$SA_BK_HASH"
            rb="$SA_BK_PATH" rbh="$SA_BK_HASH" valve=0
            step_end ok "original: $(state_get '.steam.active_backup'); snapshot: $SA_BK_PATH"
            ;;
        *) step_fail "Steam.app is $class; not patching" ;;
    esac

    step_start patch "Patching Steam.app"
    SA_PATCH_NOTHING_CHANGED=0
    NP_ROLLBACK_HASH="$rbh"
    NP_ROLLBACK_VALVE="$valve"
    NP_ROLLBACK="$rb"
    journal_set_snapshot "$rb"
    if ! sa_patch "$app" "$dylib"; then
        [ "$SA_PATCH_NOTHING_CHANGED" = 1 ] && NP_ROLLBACK=""
        step_fail "patching Steam.app failed"
    fi
    NP_ROLLBACK=""
    journal_set_snapshot ""
    state_update '.steam.patched = {at: $__now, dylib_sha256: $d, cdhash: $c, version: $v}' \
        --arg d "$(np_sha256 "$NP_DYLIB_DST")" --arg c "$(sa_cdhash "$app")" --arg v "$(sa_version "$app")"
    step_end ok "insert added, ad-hoc signed, signature verifies"
}

verify_flow() { # [auto]
    local prof scn uin off rc=0
    prof="$NP_SUPPORT/signatures/macos.arm64/$(gate_profile "$NP_SUPPORT/signatures/macos.arm64")"
    scn="$(gate_count "$prof" steamclient.dylib)"
    uin="$(gate_count "$prof" steamui.dylib)"
    if sa_steam_running; then
        state_update '.verify = {result: "not_run", detail: "Steam was running", at: $__now}'
        step_end skip "Steam is running with the old state; quit and start it, then run: install.sh doctor"
        return 0
    fi
    if [ "${1:-}" = auto ]; then
        [ "$NP_STEAM_WAS_RUNNING" = 1 ] || rc=1
    else
        np_confirm start_steam "Start Steam now to check that Steam Play loads? (It waits up to ${NP_VERIFY_TIMEOUT}s for the result in notproton.log.)" || rc=$?
    fi
    if [ "$rc" != 0 ]; then
        state_update '.verify = {result: "not_run", detail: "Steam not started", at: $__now}'
        step_end skip "start Steam yourself, then run: install.sh doctor"
        return 0
    fi
    off="$(stat -f %z "$NP_DYLIB_LOG" 2>/dev/null || echo 0)"
    state_update '.verify = {log_offset: ($o|tonumber), result: "pending", at: $__now}' --arg o "$off"
    sa_steamctl start || { step_end warn "could not start Steam"; return 0; }
    verify_wait "$NP_DYLIB_LOG" "$off" "$scn" "$uin" "$NP_VERIFY_TIMEOUT"
    state_update '.verify = {log_offset: ($o|tonumber), result: $r, detail: $d, at: $__now}' \
        --arg o "$off" --arg r "$VERIFY_RESULT" --arg d "$VERIFY_DETAIL"
    case "$VERIFY_RESULT" in
        pass) step_end ok "$VERIFY_DETAIL" ;;
        pending)
            NP_RESULT_STATUS=pending
            NP_RESULT_DETAIL="verify pending: run install.sh doctor once Steam has started"
            step_end warn "no result within ${NP_VERIFY_TIMEOUT}s; once Steam is up run: install.sh doctor" ;;
        *) step_end fail "$VERIFY_DETAIL"; VERIFY_FAILED=1 ;;
    esac
}

next_steps() {
    say ""
    say "Next steps:"
    say "  1. In Steam: a Windows-only game > Properties > Compatibility > tick 'Force the use of a"
    say "     specific Steam Play compatibility tool' and pick 'Steam Play (Wine, self-built)'."
    say "  2. Launch options are NAME=value pairs without %command% (macOS Steam fails with OS Error 260),"
    say "     e.g. CX_GRAPHICS_BACKEND=dxmt"
    say "  3. macOS may ask for Input Monitoring for Steam (its signature changed): allow it."
    say "  4. Some games need manual steps (see COMPAT.md and fixes/)."
    say "  Check any time: scripts/install.sh doctor     Undo: scripts/install.sh uninstall"
}

# ---------------------------------------------------------------------------------------------
cmd_all() {
    local from=dist plan_only=0 rv="" profile plan stage token
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) from="${2:-}"; [ $# -gt 0 ] && shift ;;
            --from=*) from="${1#--from=}" ;;
            --plan) plan_only=1 ;;
            --gptk-dmg) NP_GPTK_DMG="${2:-}"; [ $# -gt 0 ] && shift ;;
            --gptk-dmg=*) NP_GPTK_DMG="${1#*=}" ;;
            *) np_die "all: unknown option $1" ;;
        esac
        [ $# -gt 0 ] && shift
    done
    case "$from" in dist|release) ;; *) np_die "all: --from dist|release" ;; esac
    # D3DMETAL_GPTK_DMG works too, but visibly: it becomes --gptk-dmg and shows in the plan.
    NP_GPTK_DMG="${NP_GPTK_DMG:-${D3DMETAL_GPTK_DMG:-}}"
    if [ -n "${NP_GPTK_DMG:-}" ]; then
        [ -f "$NP_GPTK_DMG" ] || np_die "--gptk-dmg: no such file: $NP_GPTK_DMG"
        NP_GPTK_DMG="$(cd "$(dirname "$NP_GPTK_DMG")" && pwd -P)/$(basename "$NP_GPTK_DMG")"
        export NP_GPTK_DMG
    fi
    if [ "$plan_only" = 1 ]; then
        # --plan writes nothing at all: no lock, no log, no state file.
        NP_OP=all
    else
        np_begin all
    fi
    journal_guard

    step_start preflight "Checking this Mac and Steam.app"
    preflight
    case "$CLASS" in
        missing) step_fail "$NP_STEAM_APP not found: install Steam from steampowered.com first" ;;
        foreign) step_fail "$NP_STEAM_APP is neither Valve's signed bundle nor patched by this installer (signature, TeamID or insert); not touching it" ;;
    esac
    ADOPT_BK="" ADOPT_HASH=""
    if [ "$CLASS" = adoptable ]; then
        ADOPT_BK="${NP_ADOPT_BACKUP:-}"
        [ -n "$ADOPT_BK" ] || ADOPT_BK="$(sa_newest_valve_backup)"
        [ -n "$ADOPT_BK" ] || step_fail "Steam.app is already patched (earlier manual install) and $NP_BACKUP_DIR has no Valve-signed copy to adopt. Set NP_ADOPT_BACKUP=<path> or reinstall Steam first."
        sa_backup_ok "$ADOPT_BK" || step_fail "$ADOPT_BK is not a Valve-signed, unpatched Steam.app; it cannot be the original"
        ADOPT_HASH="$(sa_tree_hash "$ADOPT_BK")"
    fi
    if [ "$from" = release ]; then
        runner_lock_read "$NP_RUNNER_LOCK" || step_fail "cannot install --from release with $NP_RUNNER_LOCK"
        rv="$LOCK_VERSION"
    else
        rv="$NP_RUNNER_ID"
        runner_valid_id "$rv" || step_fail "runner id '$rv' must be letters, digits, '.', '_', '-'"
        [ -f "$NP_DIST_DIR/$rv/runner.json" ] || step_fail "no local runner at $NP_DIST_DIR/$rv (build it with scripts/build-all.sh, or use --from release)"
    fi
    profile="$(find "$NP_SIG_SRC" -name '*.json' | wc -l | tr -d ' ') profiles in the repo"
    step_end ok "Steam.app is $CLASS ($(sa_version "$NP_STEAM_APP")); runner $from $rv"
    plan="$(plan_text_all "$from" "$rv" "$profile")"

    if [ "$plan_only" = 1 ]; then
        token="$(printf 'plan\n%s' "$plan" | shasum -a 256 | cut -c1-64)"
        np_emit "$(jq -cn --arg t "$plan" --arg k "$token" '{event:"plan",op:"all",text:$t,token:$k}')"
        say "$plan"
        say ""
        say "confirmation token: $token"
        NP_RESULT_STATUS=plan
        return 0
    fi

    journal_begin all
    state_update '.repo = {commit: $c, notproton_commit: $n}' \
        --arg c "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)" --arg n "$(git -C "$ROOT/notproton" rev-parse HEAD 2>/dev/null || true)"

    step_start runner "Runner ($from)"
    runner_install "$from" || step_fail "the runner could not be installed"
    runner_record
    if [ "$RUNNER_REUSED" = 1 ]; then step_end ok "runner $RUNNER_VER unchanged"; else step_end ok "runner $RUNNER_VER installed, manifest $RUNNER_MANIFEST"; fi

    step_start bridge "Steam bridge (Valve's Windows DLLs, hash-checked)"
    bridge_install "$NP_SUPPORT/runners/$RUNNER_VER" || step_fail "the bridge could not be installed"
    step_end ok "$NP_SUPPORT/bridge"

    step_start support "Building notproton.dylib, helpers and anchorcheck"
    stage="$NP_SUPPORT/.staging-support-$$"
    np_cleanup_add "$stage"
    support_build "$stage" || step_fail "building the support files failed"
    step_end ok "notproton $(cat "$stage/dylib.version"), dylib $(np_sha256 "$stage/notproton.dylib" | cut -c1-12)"

    step_start gate "Checking Steam's client against the signatures (rule 5)"
    if gate_run "$stage" "$stage/anchorcheck"; then
        gate_record pass
        step_end ok "$GATE_DETAIL"
    else
        gate_record fail
        [ "$CLASS" = ours ] && signatures_disable "gate failed: $GATE_DETAIL"
        np_notify "Steam Play: the signatures do not fit this Steam client ($GATE_DETAIL). Nothing was installed into Steam."
        step_fail "$GATE_DETAIL. Steam.app was not touched: the signatures do not fit this Steam client."
    fi

    step_start confirm "Confirmation"
    confirm_or_exit plan "$plan"
    step_end ok "confirmed"

    step_start support_install "Installing support files"
    support_install "$stage" || step_fail "installing the support files failed"
    step_end ok "$NP_SUPPORT"

    if [ "$CLASS" = ours ] && [ -f "$NP_DYLIB_DST" ] \
        && [ "$(np_sha256 "$NP_DYLIB_DST")" = "$(np_sha256 "$NP_SUPPORT/notproton.dylib")" ] && sa_verify "$NP_STEAM_APP"; then
        step_start patch "Patching Steam.app"
        step_end skip "already patched with this dylib"
    else
        steam_patch_flow "$CLASS" "$ADOPT_BK" "$ADOPT_HASH"
    fi

    # Only after a successful patch: the profile of the live client, alone.
    step_start signatures "Installing the signature profile"
    signatures_install "$stage/signatures/macos.arm64" "$GATE_PROFILE" || step_fail "could not install the signature profile"
    step_end ok "$GATE_PROFILE"

    step_start block_updates "Blocking Steam bootstrapper updates"
    if cfg_block_all; then step_end ok "outer and inner steam.cfg"; else step_end warn "update blocking incomplete (see above)"; fi

    step_start register "Registering fixes, global.env and the current runner"
    register_files "$stage" || step_fail "registering failed"
    journal_end "done"
    step_end ok "runners/current -> $RUNNER_VER"

    step_start verify "Checking that Steam loads it"
    verify_flow
    next_steps
    if [ "$VERIFY_FAILED" = 1 ]; then
        NP_DIE_MSG="installed, but the check in notproton.log failed: $VERIFY_DETAIL"
        exit 1
    fi
    return 0
}

# ---------------------------------------------------------------------------------------------
cmd_reapply() {
    local auto=0 class cd sc_old ui_old cd_old stage plan rc
    while [ $# -gt 0 ]; do
        case "$1" in --auto) auto=1 ;; *) np_die "reapply: unknown option $1" ;; esac
        shift
    done
    np_begin reapply
    [ -n "$(state_get '.steam.patched.at')" ] || np_die "nothing to re-apply: install.sh all has not completed here"
    journal_guard
    gate_client_hashes
    class="$(sa_classify "$NP_STEAM_APP")"
    cd="$(sa_cdhash "$NP_STEAM_APP")"
    sc_old="$(state_get '.client.steamclient_sha256')"
    ui_old="$(state_get '.client.steamui_sha256')"
    cd_old="$(state_get '.steam.patched.cdhash')"
    if [ "$class" = ours ] && [ "$GATE_SC_SHA" = "$sc_old" ] && [ "$GATE_UI_SHA" = "$ui_old" ] && [ "$cd" = "$cd_old" ] \
        && [ "$(state_get '.client.signatures.disabled')" != true ]; then
        say "nothing changed since the last install (client, Steam.app)"
        NP_RESULT_DETAIL=unchanged
        return 0
    fi
    journal_begin reapply

    step_start gate "Checking the updated client against the signatures"
    stage="$NP_SUPPORT/.staging-sigs-$$"
    np_cleanup_add "$stage"
    rm -rf "$stage"
    mkdir -p "$stage/signatures/macos.arm64" || step_fail "cannot stage the signatures"
    cp -f "$NP_SIG_SRC"/*.json "$stage/signatures/macos.arm64/" || step_fail "no signatures in $NP_SIG_SRC"
    if ! gate_run "$stage" "$NP_SUPPORT/tools/anchorcheck"; then
        gate_record fail
        if [ "$class" = ours ]; then
            signatures_disable "gate failed after a Steam update: $GATE_DETAIL"
            np_notify "Steam was updated and no signature profile fits the new client. Steam Play is switched off (no hooks load) and Steam.app was not changed. Details: $GATE_DETAIL"
        else
            np_notify "Steam was updated and no signature profile fits the new client. Steam.app was not changed. Details: $GATE_DETAIL"
        fi
        step_fail "$GATE_DETAIL; Steam.app not changed"
    fi
    gate_record pass
    step_end ok "$GATE_DETAIL"

    case "$class" in
        ours)
            step_start signatures "Reinstalling the signatures"
            signatures_install "$stage/signatures/macos.arm64" "$GATE_PROFILE" || step_fail "could not install the signatures"
            step_end ok "$GATE_PROFILE"
            step_start block_updates "Blocking Steam bootstrapper updates"
            if cfg_block_all; then step_end ok "outer and inner steam.cfg"; else step_end warn "update blocking incomplete"; fi
            ;;
        pristine)
            [ -f "$NP_SUPPORT/notproton.dylib" ] || step_fail "no installed notproton.dylib; run install.sh all"
            CLASS=pristine
            plan="$(printf 'Steam replaced Steam.app with a new Valve version (%s). Re-apply Steam Play: quit Steam, back up the new Steam.app to %s/Steam.app.<date> (verified), patch it and re-sign it ad hoc.' \
                "$(sa_version "$NP_STEAM_APP")" "$NP_BACKUP_DIR")"
            step_start confirm "Confirmation"
            rc=0
            if [ "$auto" = 1 ]; then
                np_dialog reapply "$plan" || rc=1
            else
                np_confirm plan "$plan" || rc=$?
            fi
            case "$rc" in
                0) step_end ok "confirmed" ;;
                3) step_end warn "needs confirmation"; exit 3 ;;
                *) step_end skip "not confirmed; nothing changed"; NP_RESULT_DETAIL="declined"; return 0 ;;
            esac
            steam_patch_flow pristine
            step_start signatures "Installing the signature profile"
            signatures_install "$stage/signatures/macos.arm64" "$GATE_PROFILE" || step_fail "could not install the signatures"
            step_end ok "$GATE_PROFILE"
            step_start block_updates "Blocking Steam bootstrapper updates"
            if cfg_block_all; then step_end ok "outer and inner steam.cfg"; else step_end warn "update blocking incomplete"; fi
            journal_end "done"
            step_start verify "Checking that Steam loads it"
            if [ "$auto" = 1 ]; then verify_flow auto; else verify_flow; fi
            if [ "$VERIFY_FAILED" = 1 ]; then
                NP_DIE_MSG="re-applied, but the check in notproton.log failed: $VERIFY_DETAIL"
                exit 1
            fi
            ;;
        *)
            step_start steam_app "Steam.app"
            step_fail "Steam.app is $class; reapply only handles this installer's patch or a fresh Valve bundle"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------------------------
valve_bundle_fetch() { # -> VALVE_APP, VALVE_HASH
    local line kind file sha inner name b work dst app
    np_test_mode && { warn "test mode: Valve's bundle is not downloaded"; return 1; }
    line="$(grep '^bundle ' "$NP_VALVE_MANIFEST" | head -1)"
    read -r kind file sha inner name <<< "$line"
    [ "$kind" = bundle ] && [ -n "$sha" ] || { warn "no bundle line in $NP_VALVE_MANIFEST"; return 1; }
    dst="$NP_CACHE/valve/$file"
    mkdir -p "$NP_CACHE/valve"
    if ! { [ -f "$dst" ] && [ "$(np_sha256 "$dst")" = "$sha" ]; }; then
        for b in $(awk '$1=="base"{print $2}' "$NP_VALVE_MANIFEST"); do
            if np_quiet curl -fsSL --proto '=https' --connect-timeout 10 -o "$dst.part" "$b/$file" \
                && [ "$(np_sha256 "$dst.part")" = "$sha" ]; then
                mv -f "$dst.part" "$dst"
                break
            fi
            rm -f "$dst.part"
        done
    fi
    [ -f "$dst" ] && [ "$(np_sha256 "$dst")" = "$sha" ] || { warn "could not fetch Valve's bundle with the pinned hash"; return 1; }
    work="$NP_SUPPORT/.valve-bundle-$$"
    np_cleanup_add "$work"
    rm -rf "$work"
    mkdir -p "$work"
    np_quiet unzip -q -o "$dst" -d "$work" || return 1
    [ -f "$work/$inner" ] || { warn "$inner not in $file"; return 1; }
    tar -xzf "$work/$inner" -C "$work" || return 1
    app="$(find "$work" -maxdepth 3 -type d -name "$name" | head -1)"
    [ -n "$app" ] && sa_is_valve "$app" || { warn "Valve's bundle does not verify"; return 1; }
    VALVE_APP="$app"
    VALVE_HASH="$(sa_tree_hash "$app")"
}

remove_support_files() {
    local f plist
    for f in notproton.dylib overlay-shim.dylib iconmaker appinfo pe-d3d syshud dylib.version; do
        rm -f "$NP_SUPPORT/$f"
    done
    rm -rf "$NP_SUPPORT/signatures" "$NP_SUPPORT"/signatures.disabled-* "$NP_SUPPORT/tools" "$NP_SUPPORT/bridge" "$NP_SUPPORT/fixes" "$NP_SUPPORT/autofix"
    rm -rf "$NP_TOOL_DIR"
    plist="$NP_LAUNCH_AGENTS/$NP_AGENT_LABEL.plist"
    if [ -f "$plist" ]; then
        np_test_mode || launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
        rm -f "$plist"
    fi
}

prefix_dirs() { # compatdata of games that ran through notproton, plus its launchers
    local d
    for d in "$NP_STEAM_SUPPORT"/steamapps/compatdata/*; do
        [ -d "$d" ] || continue
        if [ -e "$d/notproton-run.log" ] || [ -e "$d/notproton-msync" ]; then printf '%s\n' "$d"; fi
    done
    [ -d "$NP_SUPPORT/launchers" ] && printf '%s\n' "$NP_SUPPORT/launchers"
    return 0
}

cmd_uninstall() {
    local rr=0 rg=0 rp=0 class bk bh cand ch mode=none src="" srch="" rc plan pdirs d what
    while [ $# -gt 0 ]; do
        case "$1" in
            --remove-runners) rr=1 ;;
            --remove-global-env) rg=1 ;;
            --remove-prefixes) rp=1 ;;
            *) np_die "uninstall: unknown option $1" ;;
        esac
        shift
    done
    np_begin uninstall
    # No journal_guard: uninstall is how an interrupted run is recovered.
    class="$(sa_classify "$NP_STEAM_APP")"
    d="$(sa_leftovers)"
    [ -z "$d" ] || warn "leftovers of an interrupted restore next to Steam.app (check them by hand): $(printf '%s' "$d" | tr '\n' ' ')"

    step_start source "Choosing what to restore Steam.app from"
    case "$class" in
        pristine) mode=none; step_end ok "Steam.app is already Valve's own bundle" ;;
        missing)
            bk="$(state_get '.steam.active_backup')"
            bh="$(backup_hash_for "$bk")"
            if [ -n "$bk" ] && [ -n "$bh" ] && sa_backup_ok "$bk" "$bh"; then
                mode=restore src="$bk" srch="$bh"
                step_end ok "Steam.app is missing; restoring the verified backup $bk"
            else
                mode=none
                step_end warn "$NP_STEAM_APP is missing and no verified backup is recorded; nothing to restore"
            fi
            ;;
        *)
            bk="$(state_get '.steam.active_backup')"
            bh="$(backup_hash_for "$bk")"
            if [ -n "$bk" ] && [ -n "$bh" ] && sa_backup_ok "$bk" "$bh"; then
                mode=restore src="$bk" srch="$bh"
            else
                [ -n "$bk" ] && warn "the recorded backup $bk does not verify"
                cand="$(sa_newest_valve_backup)"
                if [ -n "$cand" ]; then
                    ch="$(sa_tree_hash "$cand")"
                    rc=0
                    np_confirm restore_newest "There is no verified backup in the state. Restore Steam.app from $cand (Valve-signed, tree hash $ch)?" || rc=$?
                    [ "$rc" = 3 ] && exit 3
                    [ "$rc" = 0 ] && mode=restore src="$cand" srch="$ch"
                fi
                if [ "$mode" = none ]; then
                    rc=0
                    np_confirm restore_valve "Download Valve's Steam bootstrapper (SHA-256 pinned in valve-packages.manifest) and restore Steam.app from it?" || rc=$?
                    [ "$rc" = 3 ] && exit 3
                    if [ "$rc" = 0 ] && valve_bundle_fetch; then mode=restore src="$VALVE_APP" srch="$VALVE_HASH"; fi
                fi
                if [ "$mode" = none ]; then
                    rc=0
                    np_confirm detach "No Valve copy of Steam.app is available. Only remove the insert and dylib from Steam.app? It stays ad-hoc signed; reinstall Steam from steampowered.com to get Valve's signature back." || rc=$?
                    [ "$rc" = 3 ] && exit 3
                    [ "$rc" = 0 ] && mode=detach
                fi
                [ "$mode" = none ] && step_fail "nothing to restore Steam.app from; aborted without changes"
            fi
            step_end ok "$mode${src:+ from $src}"
            ;;
    esac

    case "$mode" in
        restore) what="restore $src (tree $srch); the patched bundle is kept as $NP_BACKUP_DIR/Steam.app.patched-<date>" ;;
        detach) what="remove the insert and dylib, re-sign ad hoc" ;;
        *) what="unchanged" ;;
    esac
    # Asked before anything changes, so a GUI can answer it with the rest (exit 3 until then).
    pdirs=""
    if [ "$rp" = 1 ]; then
        pdirs="$(prefix_dirs)"
        if [ -n "$pdirs" ]; then
            rc=0
            np_confirm remove_prefixes "Delete these game prefixes (Windows-side save data that Steam Cloud does not sync is lost):
$pdirs" || rc=$?
            case "$rc" in
                0) ;;
                3) NP_RESULT_DETAIL="needs confirmation: remove_prefixes"; exit 3 ;;
                *) warn "game prefixes will be kept"; rp=0 pdirs="" ;;
            esac
        fi
    fi
    plan="Uninstall Steam Play:
- Steam.app: $what
- Steam is asked to quit first (never force-killed).
- steam.cfg update blocks are undone; the compatibility tool, support files and LaunchAgent are removed.
- Runners: $( [ "$rr" = 1 ] && echo removed || echo kept ). global.env: $( [ "$rg" = 1 ] && echo removed || echo kept ). Game prefixes: $( [ "$rp" = 1 ] && [ -n "$pdirs" ] && echo "removed (confirmed separately)" || echo kept ).
- Backups in $NP_BACKUP_DIR are never deleted."
    step_start confirm "Confirmation"
    confirm_or_exit uninstall "$plan"
    step_end ok "confirmed"
    journal_begin uninstall

    step_start quit_steam "Quitting Steam"
    if sa_steam_running; then
        sa_quit_steam || step_fail "Steam did not quit within ${NP_QUIT_TIMEOUT}s; quit it and run this again"
        step_end ok "Steam quit"
    else
        step_end ok "Steam is not running"
    fi

    step_start restore "Restoring Steam.app"
    case "$mode" in
        restore)
            SA_RESTORE_KEPT=""
            sa_restore "$src" "$srch" 1 patched || step_fail "restore failed (see above for where each bundle is)"
            step_end ok "Valve's Steam.app is back (signature and tree hash verified); the patched one is kept at ${SA_RESTORE_KEPT:-?}"
            ;;
        detach)
            sa_detach "$NP_STEAM_APP" || step_fail "detaching failed"
            step_end warn "insert removed; reinstall Steam from steampowered.com for Valve's signature"
            ;;
        *) step_end skip "nothing to restore" ;;
    esac
    sa_clear_inner_insert

    step_start unblock "Undoing the update blocks"
    cfg_unblock_all
    step_end ok "steam.cfg files restored"

    step_start remove "Removing the compatibility tool and support files"
    remove_support_files
    if [ "$rr" = 1 ]; then rm -rf "$NP_SUPPORT/runners"; fi
    if [ "$rg" = 1 ]; then rm -f "$NP_SUPPORT/global.env"; fi
    if [ "$rp" = 1 ] && [ -n "$pdirs" ]; then
        while IFS= read -r d; do
            case "$d" in "$NP_STEAM_SUPPORT"/steamapps/compatdata/*|"$NP_SUPPORT"/launchers) rm -rf "$d" ;; esac
        done <<< "$pdirs"
    fi
    step_end ok "removed"
    journal_end "done"
    state_archive
    say "Uninstalled. Backups stay in $NP_BACKUP_DIR; the state is archived in $NP_SUPPORT/state-archive."
}

# ---------------------------------------------------------------------------------------------
# doctor: read-only.
DR_FILE=""
dr() { # id verdict detail
    printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ')" >> "$DR_FILE"
}

doctor_last_session() {
    local log="$NP_DYLIB_LOG" last start off prof scn uin
    [ -f "$log" ] || { dr last_session warn "no notproton.log yet: Steam has not started with the dylib"; return 0; }
    last="$(grep -n 'install_thread: signatures [0-9]*/[0-9]* resolved' "$log" | tail -1 | cut -d: -f1)"
    [ -n "$last" ] || { dr last_session warn "no Steam session with the dylib in the log yet"; return 0; }
    start="$(head -n "$last" "$log" | grep -n 'np_init: loaded into' | tail -1 | cut -d: -f1)"
    start="${start:-$last}"
    off=0
    [ "$start" -gt 1 ] && off="$(head -n "$((start - 1))" "$log" | wc -c | tr -d ' ')"
    prof="$NP_SUPPORT/signatures/macos.arm64/$(gate_profile "$NP_SUPPORT/signatures/macos.arm64")"
    scn="$(gate_count "$prof" steamclient.dylib || true)"
    uin="$(gate_count "$prof" steamui.dylib || true)"
    verify_scan "$log" "$off" "${scn:-0}" "${uin:-0}"
    case "$VERIFY_RESULT" in
        pass) dr last_session ok "$VERIFY_DETAIL" ;;
        fail) dr last_session fail "$VERIFY_DETAIL" ;;
        *) dr last_session warn "the last session is incomplete: $VERIFY_DETAIL" ;;
    esac
}

cmd_doctor() {
    local quick=0 json="$NP_JSON" st cls ins want app="$NP_STEAM_APP" bk bh cur r line name verdict exitc f bad
    while [ $# -gt 0 ]; do
        case "$1" in --json) json=1 ;; --quick) quick=1 ;; *) np_die "doctor: unknown option $1" ;; esac
        shift
    done
    DR_FILE="$(mktemp "${TMPDIR:-/tmp}/np-doctor.XXXXXX")"

    if arch -x86_64 /usr/bin/true 2>/dev/null; then dr rosetta ok "Rosetta 2 runs x86_64 code"; else dr rosetta fail "Rosetta 2 missing: softwareupdate --install-rosetta"; fi

    if ! state_exists; then
        dr state warn "no install-state.json: not installed with install.sh all"
    elif ! jq -e . "$NP_STATE_FILE" >/dev/null 2>&1; then
        dr state fail "install-state.json is not valid JSON"
    elif [ "$(state_get '.schema')" = "$NP_STATE_SCHEMA" ]; then
        dr state ok "schema $NP_STATE_SCHEMA"
    else
        dr state fail "unknown state schema $(state_get '.schema')"
    fi
    st="$(journal_state)"
    case "$st" in
        ''|idle|done) dr journal ok "${st:-idle}" ;;
        failed|aborted) dr journal warn "last $(state_get '.journal.op') run: $st (step $(state_get '.journal.step'))" ;;
        *) dr journal fail "$(state_get '.journal.op') run interrupted at step $(state_get '.journal.step') ($st): run install.sh uninstall, or journal-clear once Steam.app checks out" ;;
    esac

    cls="$(sa_classify "$app")"
    case "$cls" in
        ours) dr steam_app ok "patched by this installer ($(sa_version "$app"))" ;;
        pristine) dr steam_app warn "Valve's own bundle, not patched ($(sa_version "$app")): run install.sh reapply or all" ;;
        adoptable) dr steam_app warn "patched, but not recorded by install.sh all (earlier manual install)" ;;
        *) dr steam_app fail "Steam.app is $cls" ;;
    esac
    ins="$(sa_insert "$app")"
    if [ "$cls" = pristine ] || [ "$cls" = missing ]; then
        dr insert skip "not patched"
        dr dylib_hash skip "not patched"
    else
        if [ "$ins" = "$NP_DYLIB_DST" ] && [ -f "$NP_DYLIB_DST" ]; then dr insert ok "$ins"; else dr insert fail "insert is '${ins:-none}'"; fi
        want="$(state_get '.steam.patched.dylib_sha256')"
        if [ ! -f "$NP_DYLIB_DST" ]; then dr dylib_hash fail "no notproton.dylib in Steam.app"
        elif [ -z "$want" ]; then dr dylib_hash warn "no dylib hash recorded"
        elif [ "$(np_sha256 "$NP_DYLIB_DST")" != "$want" ]; then dr dylib_hash fail "dylib in Steam.app differs from the recorded one"
        elif [ -f "$NP_SUPPORT/notproton.dylib" ] && [ "$(np_sha256 "$NP_SUPPORT/notproton.dylib")" != "$want" ]; then dr dylib_hash warn "a newer dylib is in the support dir but not in Steam.app: run install.sh all"
        else dr dylib_hash ok "${want:0:16}"; fi
    fi
    if [ ! -d "$app" ]; then dr codesign fail "Steam.app missing"
    elif sa_verify "$app"; then dr codesign ok "codesign --verify --deep --strict passes (team $(sa_team "$app"))"
    else dr codesign fail "Steam.app's signature does not verify"; fi
    f="$(sa_leftovers)"
    if [ -z "$f" ]; then dr leftovers ok "no leftovers of an interrupted restore"
    else dr leftovers fail "an interrupted restore left bundles next to Steam.app; check by hand: $(printf '%s' "$f" | tr '\n' ' ')"; fi

    bk="$(state_get '.steam.active_backup')"
    if [ -z "$bk" ]; then
        if [ "$cls" = ours ] || [ "$cls" = adoptable ]; then dr backup fail "no backup recorded"; else dr backup warn "no backup recorded"; fi
    elif [ ! -d "$bk" ]; then
        dr backup fail "recorded backup $bk is missing"
    elif [ "$quick" = 1 ]; then
        if sa_is_valve "$bk"; then dr backup ok "$bk (signature, TeamID; tree hash skipped with --quick)"; else dr backup fail "$bk is not Valve-signed"; fi
    else
        bh="$(backup_hash_for "$bk")"
        if sa_backup_ok "$bk" "$bh"; then dr backup ok "$bk (signature, TeamID $NP_VALVE_TEAM, tree hash)"; else dr backup fail "$bk does not verify (signature, TeamID or tree hash)"; fi
    fi

    gate_client_hashes
    if [ "$(state_get '.client.signatures.disabled')" = true ]; then
        dr gate fail "signatures are disabled since a failed gate ($(state_get '.client.signatures.reason')); Steam Play is off until install.sh reapply passes"
    elif [ "$quick" = 1 ]; then
        dr gate skip "skipped with --quick"
    elif [ -x "$NP_SUPPORT/tools/anchorcheck" ] && [ -d "$NP_SUPPORT/signatures/macos.arm64" ]; then
        if gate_run "$NP_SUPPORT" "$NP_SUPPORT/tools/anchorcheck"; then dr gate ok "$GATE_DETAIL"; else dr gate fail "$GATE_DETAIL"; fi
    else
        dr gate warn "anchorcheck or signatures not installed"
    fi
    if [ -z "$(state_get '.client.steamclient_sha256')" ]; then
        dr client_changed warn "no client hashes recorded"
    elif [ "$GATE_SC_SHA" = "$(state_get '.client.steamclient_sha256')" ] && [ "$GATE_UI_SHA" = "$(state_get '.client.steamui_sha256')" ]; then
        dr client_changed ok "client unchanged since install (build $(state_get '.client.binary_build'))"
    else
        dr client_changed warn "Steam's client changed since install: run install.sh reapply"
    fi
    doctor_last_session

    want="$(state_get '.support.run_script_sha256')"
    if [ ! -f "$NP_TOOL_DIR/run" ]; then dr run_script warn "no compatibility tool yet: Steam has not started with the dylib"
    elif [ -z "$want" ]; then dr run_script warn "no run script hash recorded"
    elif [ "$(np_sha256 "$NP_TOOL_DIR/run")" = "$want" ]; then dr run_script ok "matches the repo's compat_run.sh"
    else dr run_script warn "differs from the repo's compat_run.sh (dylib older than the repo, or edited by hand)"; fi

    cur="$(readlink "$NP_SUPPORT/runners/current" 2>/dev/null || true)"
    r="$NP_SUPPORT/runners/$cur"
    if [ -z "$cur" ] || [ ! -d "$r" ]; then
        dr runner fail "runners/current is missing or dangling"
        dr runner_manifest skip "no runner"
        dr d3dmetal skip "no runner"
    else
        if grep -Eq '"kind"[[:space:]]*:[[:space:]]*"selfbuilt"' "$r/runner.json" 2>/dev/null && [ -x "$r/bin/wine" ]; then dr runner ok "$cur (selfbuilt)"; else dr runner fail "$cur is not a selfbuilt runner with bin/wine"; fi
        if [ ! -f "$NP_SUPPORT/runners/$cur.files.sha256" ]; then dr runner_manifest warn "no file manifest for $cur (installed before install.sh all)"
        elif [ "$quick" = 1 ]; then dr runner_manifest skip "skipped with --quick"
        elif runner_manifest_verify "$r" "$NP_SUPPORT/runners/$cur.files.sha256"; then dr runner_manifest ok "every file matches $cur.files.sha256"
        else dr runner_manifest fail "runner files differ from $cur.files.sha256"; fi
        st=""
        state_exists && st="$(jq -r --arg v "$cur" '.runners[$v].d3dmetal.status // empty' "$NP_STATE_FILE" 2>/dev/null || true)"
        if [ ! -f "$r/lib/external/D3DMetal.files.sha256" ]; then
            if [ "$st" = declined ]; then dr d3dmetal warn "not installed (licence not accepted)"; else dr d3dmetal warn "no D3DMetal file hashes in $cur"; fi
        elif [ "$quick" = 1 ]; then dr d3dmetal ok "present (hashes skipped with --quick)"
        elif (cd "$r" && shasum -a 256 -c --quiet lib/external/D3DMetal.files.sha256 >/dev/null 2>&1); then
            dr d3dmetal ok "hashes match; licence accepted $(jq -r --arg v "$cur" '.runners[$v].d3dmetal.accepted_at // "with the source build"' "$NP_STATE_FILE" 2>/dev/null || echo '?')"
        else dr d3dmetal fail "D3DMetal files differ from their hashes"; fi
    fi

    if [ -z "$(state_get '.bridge.at')" ]; then
        dr bridge warn "no bridge hashes recorded"
    elif [ ! -d "$NP_SUPPORT/bridge" ]; then
        dr bridge fail "the bridge folder is missing"
    else
        bad="$(jq -r '.bridge.files | to_entries[] | "\(.value)  ./\(.key)"' "$NP_STATE_FILE" | (cd "$NP_SUPPORT/bridge" && shasum -a 256 -c --quiet - 2>&1) || true)"
        if [ -z "$bad" ]; then dr bridge ok "every bridge file matches"; else dr bridge fail "bridge files differ: $(printf '%s' "$bad" | head -3 | tr '\n' ' ')"; fi
    fi

    if cfg_blocked "$NP_STEAM_SUPPORT/steam.cfg"; then dr update_block_outer ok "steam.cfg blocks updates"; else dr update_block_outer warn "outer steam.cfg does not block updates"; fi
    if [ ! -d "$NP_INNER_MACOS" ]; then dr update_block_inner skip "no inner client folder"
    elif cfg_blocked "$NP_INNER_MACOS/steam.cfg"; then dr update_block_inner ok "inner steam.cfg blocks updates"
    else dr update_block_inner warn "inner steam.cfg does not block updates"; fi

    if [ ! -f "$NP_SUPPORT/autofix/autofix.sh" ]; then
        dr autofix warn "autofix is not installed"
    elif [ ! -f "$NP_SUPPORT/autofix/autofix.files.sha256" ]; then
        dr autofix warn "autofix has no file manifest ($(cat "$NP_SUPPORT/autofix/VERSION" 2>/dev/null || echo 'no VERSION'))"
    elif (cd "$NP_SUPPORT/autofix" && shasum -a 256 -c --quiet autofix.files.sha256 >/dev/null 2>&1); then
        dr autofix ok "$(cat "$NP_SUPPORT/autofix/VERSION" 2>/dev/null || echo '?'): every file matches its hash"
    else
        dr autofix fail "autofix files differ from autofix.files.sha256 ($(cat "$NP_SUPPORT/autofix/VERSION" 2>/dev/null || echo '?'))"
    fi

    bad="" verdict=ok
    for f in "$NP_SUPPORT"/fixes/*.sh; do
        [ -f "$f" ] || continue
        if ! sh -n "$f" 2>/dev/null; then verdict=fail; bad="$bad ${f##*/}(syntax)"
        elif ! cmp -s "$f" "$NP_FIXES_SRC/${f##*/}"; then [ "$verdict" = ok ] && verdict=warn; bad="$bad ${f##*/}(differs from repo)"; fi
    done
    if [ "$verdict" = ok ]; then dr fixes ok "$(find "$NP_SUPPORT/fixes" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ') fix(es) parse and match the repo"; else dr fixes "$verdict" "${bad# }"; fi

    verdict=ok bad=""
    if [ -f "$NP_SUPPORT/global.env" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            name="${line%%=*}"
            if [ "$name" = "$line" ] || ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                verdict=fail
                bad="$bad invalid:'$name'"
                continue
            fi
            case "$name" in
                CX_GRAPHICS*|CX_FWD_COMPAT_GL_CTX|D3DM_*|DXMT_*|DXVK_*|MTL_*|NOTPROTON_*|ROSETTA_*|WINE*) ;;
                *) [ "$verdict" = ok ] && verdict=warn; bad="$bad ignored:$name" ;;
            esac
        done < "$NP_SUPPORT/global.env"
        if [ "$verdict" = ok ]; then dr global_env ok "names valid"; else dr global_env "$verdict" "${bad# }"; fi
    else
        dr global_env skip "no global.env"
    fi

    if grep -q $'\tfail\t' "$DR_FILE"; then verdict=fail exitc=1
    elif grep -q $'\twarn\t' "$DR_FILE"; then verdict=warn exitc=2
    else verdict=ok exitc=0; fi
    line="$(jq -R -s -c --arg v "$verdict" --argjson e "$exitc" --argjson q "$( [ "$quick" = 1 ] && echo true || echo false )" '
        {event: "doctor", schema: 1, verdict: $v, exit: $e, quick: $q,
         checks: (split("\n") | map(select(length > 0) | split("\t") | {id: .[0], verdict: .[1], detail: (.[2] // "")}))}' "$DR_FILE")"
    if [ "$json" = 1 ]; then
        printf '%s\n' "$line"
    else
        while IFS=$'\t' read -r name st f; do
            printf '%-5s %-19s %s\n' "$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')" "$name" "$f"
        done < "$DR_FILE"
        printf '\ndoctor: %s\n' "$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"
        np_emit "$line"
    fi
    rm -f "$DR_FILE"
    return "$exitc"
}

# ---------------------------------------------------------------------------------------------
cmd_status() {
    echo "runner:   $(readlink "$NP_SUPPORT/runners/current" 2>/dev/null || echo none)"
    echo "steam:    $(sa_classify "$NP_STEAM_APP"), insert=$(sa_insert "$NP_STEAM_APP" | grep . || echo none)"
    echo "dylib:    $( [ -f "$NP_DYLIB_DST" ] && np_sha256 "$NP_DYLIB_DST" | cut -c1-16 || echo absent)"
    echo "compat:   $(find "$NP_STEAM_SUPPORT/compatibilitytools.d" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
    if state_exists; then
        echo "state:    journal=$(journal_state), backup=$(state_get '.steam.active_backup'), verify=$(state_get '.verify.result')"
    else
        echo "state:    none (not installed with install.sh all)"
    fi
}

cmd_journal_clear() {
    np_begin journal-clear
    confirm_or_exit journal_clear "Mark the interrupted '$(state_get '.journal.op')' run (step $(state_get '.journal.step')) as handled? Only do this after install.sh doctor shows Steam.app is fine."
    state_update '.journal.state = "idle" | .journal.updated_at = $__now'
    history_add journal-clear "done" ""
    say "journal cleared"
}

# --- low-level commands (compatibility) ------------------------------------------------------
# Upstream's step-by-step install, for a Mac without install.sh all. Refused once install.sh all
# has run (it would bypass the gate and the state), so it never competes with the managed install.
cmd_support() {
    local id="" runner B f
    while [ $# -gt 0 ]; do
        case "$1" in
            --gptk-dmg) NP_GPTK_DMG="${2:-}"; [ $# -gt 0 ] && shift ;;
            --gptk-dmg=*) NP_GPTK_DMG="${1#*=}" ;;
            -*) np_die "support: unknown option $1" ;;
            *) id="$1" ;;
        esac
        [ $# -gt 0 ] && shift
    done
    id="${id:-$NP_RUNNER_ID}"
    NP_GPTK_DMG="${NP_GPTK_DMG:-${D3DMETAL_GPTK_DMG:-}}"
    np_lock
    np_open_log support
    state_exists && np_die "install.sh all manages this Mac ($NP_STATE_FILE exists); 'support' would bypass the signature gate. Use: install.sh all"
    case "$(sa_classify "$NP_STEAM_APP")" in
        adoptable|ours) np_die "Steam.app is already patched; 'support' would change what it loads without a backup or a gate. Use: install.sh all" ;;
    esac
    runner_valid_id "$id" || np_die "runner id '$id' must be letters, digits, '.', '_', '-'"
    if [ -n "${NP_GPTK_DMG:-}" ]; then [ -f "$NP_GPTK_DMG" ] || np_die "--gptk-dmg: no such file: $NP_GPTK_DMG"; fi
    runner="$NP_DIST_DIR/$id"
    [ -f "$runner/runner.json" ] || np_die "no runner at $runner (scripts/assemble-runner.sh)"
    [ -f "$ROOT/notproton/out/notproton.dylib" ] || np_die "notproton.dylib not built (make -C notproton out/notproton.dylib)"
    [ -f "$ROOT/build/bridge/steamclient64.dll" ] || np_die "Valve bridge files missing (scripts/fetch-valve-bridge.sh)"

    mkdir -p "$NP_SUPPORT/runners"
    rm -rf "$NP_SUPPORT/runners/$id.new"
    ditto "$runner" "$NP_SUPPORT/runners/$id.new"
    xattr -dr com.apple.quarantine "$NP_SUPPORT/runners/$id.new" 2>/dev/null || true
    rm -rf "$NP_SUPPORT/runners/$id"
    mv "$NP_SUPPORT/runners/$id.new" "$NP_SUPPORT/runners/$id"
    ln -sfn "$id" "$NP_SUPPORT/runners/current"
    echo "runner: $NP_SUPPORT/runners/current -> $id"
    if [ -n "${NP_GPTK_DMG:-}" ]; then
        D3DMETAL_CACHE="$NP_CACHE" D3DMETAL_LICENSE_SHA256="${NP_D3DMETAL_LICENSE_TOKEN:-}" D3DMETAL_LICENSE_FILE="${NP_D3DMETAL_LICENSE_FILE:-}" \
            "$NP_D3DMETAL_SCRIPT" --gptk-dmg "$NP_GPTK_DMG" "$NP_SUPPORT/runners/$id" || np_die "D3DMetal from $NP_GPTK_DMG was not installed"
    fi

    B="$NP_SUPPORT/bridge"
    mkdir -p "$B/legacycompat" "$B/i386-windows" "$B/x86_64-windows" "$B/x86_64-unix"
    for f in steamclient.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll; do
        install_file "$ROOT/build/bridge/$f" "$B/$f"
    done
    for f in "$ROOT"/build/bridge/legacycompat/*; do install_file "$f" "$B/legacycompat/${f##*/}"; done
    install_file "$runner/share/steamplay/steam.exe" "$B/steam.exe"
    install_file "$runner/lib/wine/x86_64-windows/lsteamclient.dll" "$B/lsteamclient.dll"
    install_file "$runner/lib/wine/x86_64-windows/lsteamclient.dll" "$B/x86_64-windows/lsteamclient.dll"
    install_file "$runner/lib/wine/i386-windows/lsteamclient.dll" "$B/i386-windows/lsteamclient.dll"
    install_file "$runner/lib/wine/x86_64-unix/lsteamclient.so" "$B/x86_64-unix/lsteamclient.so"
    codesign --remove-signature "$B/x86_64-unix/lsteamclient.so" 2>/dev/null || true
    rm -rf "$B/wine"
    echo "bridge: $B"

    # Rule 5 here too: only the live client's profile, and only if it resolves fully.
    [ -x "$ROOT/notproton/out/anchorcheck" ] || np_die "anchorcheck not built (make -C notproton out/anchorcheck)"
    f="$NP_SUPPORT/.staging-sigs-$$"
    np_cleanup_add "$f"
    rm -rf "$f"
    mkdir -p "$f/signatures/macos.arm64" && cp -f "$NP_SIG_SRC"/*.json "$f/signatures/macos.arm64/" || np_die "cannot stage the signatures"
    gate_run "$f" "$ROOT/notproton/out/anchorcheck" || np_die "signature gate failed: $GATE_DETAIL"
    signatures_install "$f/signatures/macos.arm64" "$GATE_PROFILE" || np_die "could not install the signature profile"
    echo "signatures: $GATE_PROFILE ($GATE_DETAIL)"
    install_file "$ROOT/notproton/out/overlay-shim.dylib" "$NP_SUPPORT/overlay-shim.dylib"
    install_file "$ROOT/notproton/out/iconmaker" "$NP_SUPPORT/iconmaker"
    install_file "$ROOT/notproton/out/appinfo" "$NP_SUPPORT/appinfo"
    install_file "$ROOT/build/helpers/pe-d3d" "$NP_SUPPORT/pe-d3d"
    install_file "$ROOT/build/helpers/syshud" "$NP_SUPPORT/syshud"
    install_file "$ROOT/notproton/out/notproton.dylib" "$NP_SUPPORT/notproton.dylib"
    mkdir -p "$NP_SUPPORT/fixes"
    for f in "$ROOT"/fixes/*.sh; do [ -f "$f" ] && install_file "$f" "$NP_SUPPORT/fixes/${f##*/}"; done
    sed -n 's/.*NOTPROTON_VERSION[^"]*"\([^"]*\)".*/\1/p' "$ROOT/notproton/dylib/version.h" | head -1 > "$NP_SUPPORT/dylib.version"
    autofix_stage "$NP_SUPPORT/.staging-autofix-$$" && autofix_install "$NP_SUPPORT/.staging-autofix-$$" || np_die "installing autofix failed"
    rm -rf "$NP_SUPPORT/.staging-autofix-$$"
    global_env_defaults || np_die "could not write the global.env defaults"
    echo "helpers, signatures, dylib, autofix ($(cat "$NP_SUPPORT/autofix/VERSION")): $NP_SUPPORT"
}

# Rule 1: refused unless a verified Valve backup is recorded. Never quits Steam by itself.
cmd_steam() {
    local bk bh class stage
    np_begin steam
    journal_guard
    bk="$(state_get '.steam.active_backup')"
    bh="$(backup_hash_for "$bk")"
    [ -n "$bk" ] && [ -n "$bh" ] && sa_backup_ok "$bk" "$bh" \
        || np_die "no verified backup of Steam.app is recorded (rule 1). Use: install.sh all"
    [ -f "$NP_SUPPORT/notproton.dylib" ] || np_die "run install.sh all (or support) first"
    sa_steam_running && np_die "quit Steam first"
    class="$(sa_classify "$NP_STEAM_APP")"
    case "$class" in pristine|ours) ;; *) np_die "Steam.app is $class; not patching it" ;; esac
    # Rule 5 before the question: the live client must have a matching, fully resolving profile.
    stage="$NP_SUPPORT/.staging-sigs-$$"
    np_cleanup_add "$stage"
    rm -rf "$stage"
    mkdir -p "$stage/signatures/macos.arm64" && cp -f "$NP_SIG_SRC"/*.json "$stage/signatures/macos.arm64/" || np_die "cannot stage the signatures"
    if ! gate_run "$stage" "$NP_SUPPORT/tools/anchorcheck"; then
        gate_record fail
        [ "$class" = ours ] && signatures_disable "gate failed: $GATE_DETAIL"
        np_die "signature gate failed: $GATE_DETAIL. Steam.app was not touched."
    fi
    gate_record pass
    confirm_or_exit steam "Patch $NP_STEAM_APP ($class) with $NP_SUPPORT/notproton.dylib and re-sign it ad hoc? Backup: $bk. Signature profile: $GATE_PROFILE"
    journal_begin steam
    # The recorded original stays as it is; a snapshot of the current bundle is the rollback.
    steam_patch_flow ours
    signatures_install "$stage/signatures/macos.arm64" "$GATE_PROFILE" || np_die "could not install the signature profile"
    journal_end "done"
    say "Steam patched. Start Steam; Windows games get 'Steam Play (Wine, self-built)'."
}

cmd_block_updates() {
    np_begin block-updates
    if cfg_block_all; then say "updates blocked in: $(cfg_paths | tr '\n' ' ')"; else np_die "could not block updates everywhere"; fi
}

# global.env holds defaults for every game (a game's launch options still win).
cmd_hud() {
    local env="$NP_SUPPORT/global.env"
    mkdir -p "$NP_SUPPORT"
    touch "$env"
    grep -v '^MTL_HUD_ENABLED=' "$env" > "$env.new" || true
    case "${1:-}" in
        on) echo 'MTL_HUD_ENABLED=1' >> "$env.new"; echo "Metal HUD on for all games (next launch)" ;;
        off) echo "Metal HUD off" ;;
        *) rm -f "$env.new"; np_die "usage: $0 hud on|off" ;;
    esac
    mv "$env.new" "$env"
}

cmd_uninstall_steam() {
    local bk bh
    np_begin uninstall-steam
    sa_steam_running && np_die "quit Steam first"
    bk="$(state_get '.steam.active_backup')"
    bh="$(backup_hash_for "$bk")"
    if [ -n "$bk" ] && [ -n "$bh" ] && sa_backup_ok "$bk" "$bh"; then
        confirm_or_exit uninstall "Restore $NP_STEAM_APP from the verified backup $bk (tree $bh)? The patched bundle is kept in $NP_BACKUP_DIR."
        journal_begin uninstall-steam
        sa_restore "$bk" "$bh" 1 patched || np_die "restore failed (see above for where each bundle is)"
        state_update '.steam.patched = null'
        journal_end "done"
        say "Steam.app restored from $bk (Valve's signature)."
        return 0
    fi
    confirm_or_exit detach "No verified backup is recorded. Remove the insert and dylib from $NP_STEAM_APP and re-sign it ad hoc (a snapshot is taken first; Valve's signature does not come back, reinstall Steam for that)?"
    journal_begin uninstall-steam
    sa_detach "$NP_STEAM_APP" || np_die "detach failed (see above)"
    journal_end "done"
    say "Steam restored (ad-hoc signed; reinstall Steam from steampowered.com for Valve's signature)."
}

usage() { sed -n '2,25p' "$0"; }

main() {
    local args=() cmd
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) NP_JSON=1 ;;
            --confirmed-plan)
                [ $# -ge 2 ] || { echo "--confirmed-plan needs a token" >&2; exit 2; }
                NP_CONFIRMED_PLANS="${NP_CONFIRMED_PLANS}${NP_CONFIRMED_PLANS:+,}$2"
                shift ;;
            --confirmed-plan=*) NP_CONFIRMED_PLANS="${NP_CONFIRMED_PLANS}${NP_CONFIRMED_PLANS:+,}${1#*=}" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    set -- ${args[@]+"${args[@]}"}
    np_setup_output
    cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        ''|-h|--help|help) usage; exit 2 ;;
    esac
    [ "$(id -u)" != 0 ] || { echo "error: do not run install.sh as root (sudo); it works on your own user's files" >&2; exit 1; }
    np_init_paths
    trap np_on_exit EXIT
    # shellcheck disable=SC2064 # NP_SIGNAL_TRAP is a fixed handler string
    trap "$NP_SIGNAL_TRAP" INT TERM HUP
    case "$cmd" in
        all) cmd_all "$@" ;;
        doctor) cmd_doctor "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        reapply) cmd_reapply "$@" ;;
        status) cmd_status ;;
        journal-clear) cmd_journal_clear ;;
        support) NP_OP=support; cmd_support "$@" ;;
        steam) cmd_steam ;;
        block-updates) cmd_block_updates ;;
        hud) cmd_hud "$@" ;;
        uninstall-steam) cmd_uninstall_steam ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
