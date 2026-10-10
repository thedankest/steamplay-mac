# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by install.sh and the other libs
# Shared helpers for scripts/install.sh: paths, test mode, output (human text plus JSON
# progress events), confirmations, the run lock and the run log. Sourced, never executed.
# bash 3.2 (stock macOS): no associative arrays, no mapfile, no empty "${arr[@]}" under set -u.

NP_VALVE_TEAM=MXGJJ98X76
NP_UPDATE_LINE='BootStrapperInhibitUpdateOnLaunch=enable'
NP_STATE_SCHEMA=1

np_test_mode() { [ "${NP_TEST_MODE:-0}" = 1 ]; }

np_has_dotdot() { case "/$1/" in */../*) return 0 ;; esac; return 1; }

# Physical path of a path that may not exist yet: the nearest existing ancestor resolved with
# cd -P, plus the rest as written.
np_physical() {
    local p="$1" rest="" base
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ]; do
        base="${p##*/}"
        rest="/$base$rest"
        p="${p%/*}"
        [ -n "$p" ] || p=/
    done
    printf '%s%s\n' "$(cd -P "$p" && pwd -P)" "$rest"
}

# NP_TEST_ROOT: strictly below the user's temp dir (getconf DARWIN_USER_TEMP_DIR, not $TMPDIR,
# which the caller controls) or /private/tmp, both resolved; never one of them itself.
np_test_root_ok() {
    local t
    for t in "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" /private/tmp; do
        [ -n "$t" ] && [ -d "$t" ] || continue
        t="$(cd -P "$t" && pwd -P)"
        [ "$t" != / ] || continue
        case "$1" in "$t"/?*) return 0 ;; esac
    done
    return 1
}

# ---------------------------------------------------------------------------------------------
# Paths. Every path the installer touches comes from here and can be overridden by env.
# In test mode every one of them must be set explicitly and lie under NP_TEST_ROOT, which must
# be a temp dir, so a test can never reach the real Steam, support dir or backups.
np_init_paths() {
    local v
    if np_test_mode; then
        [ -n "${NP_TEST_ROOT:-}" ] && [ -d "$NP_TEST_ROOT" ] || np_die "test mode needs NP_TEST_ROOT (a mktemp -d dir)"
        np_has_dotdot "$NP_TEST_ROOT" && np_die "test mode: NP_TEST_ROOT must not contain '..'"
        NP_TEST_ROOT="$(cd -P "$NP_TEST_ROOT" && pwd -P)"
        np_test_root_ok "$NP_TEST_ROOT" || np_die "test mode: NP_TEST_ROOT must be a subdirectory of a temp dir (TMPDIR or /private/tmp), not $NP_TEST_ROOT"
        for v in NP_HOME NP_STEAM_APP NP_STEAM_SUPPORT NP_SUPPORT NP_BACKUP_DIR NP_CACHE NP_DIST_DIR \
                 NP_LAUNCH_AGENTS NP_TEST_STEAMCTL NP_TEST_BUILD_SUPPORT; do
            [ -n "${!v:-}" ] || np_die "test mode: $v must be set explicitly"
        done
        for v in NP_HOME NP_STEAM_APP NP_STEAM_SUPPORT NP_SUPPORT NP_BACKUP_DIR NP_CACHE NP_DIST_DIR NP_LAUNCH_AGENTS; do
            np_has_dotdot "${!v}" && np_die "test mode: $v=${!v} contains a '..' component"
            case "$(np_physical "${!v}")/" in
                "$NP_TEST_ROOT"/*) ;;
                *) np_die "test mode: $v=${!v} is outside NP_TEST_ROOT" ;;
            esac
        done
    fi
    NP_HOME="${NP_HOME:-$HOME}"
    NP_STEAM_APP="${NP_STEAM_APP:-/Applications/Steam.app}"
    NP_STEAM_SUPPORT="${NP_STEAM_SUPPORT:-$NP_HOME/Library/Application Support/Steam}"
    NP_SUPPORT="${NP_SUPPORT:-$NP_HOME/Library/Application Support/notproton}"
    NP_BACKUP_DIR="${NP_BACKUP_DIR:-$NP_HOME/SteamPlayBackup}"
    NP_CACHE="${NP_CACHE:-$ROOT/downloads}"
    NP_DIST_DIR="${NP_DIST_DIR:-$ROOT/dist/runners}"
    NP_LAUNCH_AGENTS="${NP_LAUNCH_AGENTS:-$NP_HOME/Library/LaunchAgents}"
    NP_AGENT_LABEL="${NP_AGENT_LABEL:-io.github.steamplay-mac.reapply}"
    NP_RUNNER_ID="${NP_RUNNER_ID:-selfbuilt-cx26.3-r1}"
    NP_VERIFY_TIMEOUT="${NP_VERIFY_TIMEOUT:-180}"
    NP_QUIT_TIMEOUT="${NP_QUIT_TIMEOUT:-60}"
    NP_POLL_INTERVAL="${NP_POLL_INTERVAL:-1}"
    NP_MIN_FREE_GB="${NP_MIN_FREE_GB:-4}"
    NP_WATCH_ASK_AGAIN="${NP_WATCH_ASK_AGAIN:-86400}"

    NP_STATE_FILE="$NP_SUPPORT/install-state.json"
    NP_INNER_MACOS="$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS"
    NP_INNER_PLIST="$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/Info.plist"
    NP_DYLIB_LOG="$NP_SUPPORT/notproton.log"
    NP_SIG_SRC="$ROOT/notproton/signatures/macos.arm64"
    NP_SIG_SRC_LOCAL="$ROOT/signatures/macos.arm64"
    NP_FIXES_SRC="$ROOT/fixes"
    NP_RUN_SCRIPT_SRC="$ROOT/notproton/dylib/feats/compat_run.sh"
    NP_RUNNER_LOCK="$ROOT/ci/runner-a.lock"
    NP_VALVE_MANIFEST="$ROOT/notproton/app/Sources/NotProtonApp/Resources/valve-packages.manifest"
    NP_D3DMETAL_SCRIPT="$ROOT/scripts/install-d3dmetal.sh"
    NP_CODESIGN=/usr/bin/codesign
    NP_LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    if np_test_mode; then
        # Test-only substitutes; ignored outside test mode.
        NP_RUNNER_LOCK="${NP_TEST_RUNNER_LOCK:-$NP_RUNNER_LOCK}"
        NP_VALVE_MANIFEST="${NP_TEST_VALVE_MANIFEST:-$NP_VALVE_MANIFEST}"
        NP_D3DMETAL_SCRIPT="${NP_TEST_D3DMETAL_SCRIPT:-$NP_D3DMETAL_SCRIPT}"
        NP_CODESIGN="${NP_TEST_CODESIGN:-$NP_CODESIGN}"
        NP_LSREGISTER="${NP_TEST_LSREGISTER:-true}"
        NP_FIXES_SRC="${NP_TEST_FIXES_SRC:-$NP_FIXES_SRC}"
        NP_SIG_SRC_LOCAL="${NP_TEST_SIG_SRC_LOCAL:-$NP_SIG_SRC_LOCAL}"
    fi
    NP_TOOL_DIR="$NP_STEAM_SUPPORT/compatibilitytools.d/notproton"
    NP_DYLIB_DST="$NP_STEAM_APP/Contents/MacOS/notproton.dylib"
}

# ---------------------------------------------------------------------------------------------
# Output. Human text goes to stdout (stderr with --json). Progress events, one JSON object per
# line, go to stdout with --json or to the fd in NP_PROGRESS_FD. See the header of install.sh.
NP_JSON="${NP_JSON:-0}"
NP_EVENT_FD=""
NP_HUMAN_FD=1
NP_RUN_LOG=""
NP_OP=""
NP_RESULT_SENT=0
NP_STEP_ID=""

np_setup_output() {
    if [ "$NP_JSON" = 1 ]; then
        NP_EVENT_FD=1
        NP_HUMAN_FD=2
    elif [ -n "${NP_PROGRESS_FD:-}" ]; then
        case "$NP_PROGRESS_FD" in *[!0-9]*) np_die "NP_PROGRESS_FD must be a file descriptor number" ;; esac
        NP_EVENT_FD="$NP_PROGRESS_FD"
    fi
}

np_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
np_stamp() { date +%Y-%m-%d-%H%M%S; }

np_log_line() {
    [ -n "$NP_RUN_LOG" ] || return 0
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$NP_RUN_LOG" 2>/dev/null || true
}
say() { printf '%s\n' "$*" >&"$NP_HUMAN_FD"; np_log_line "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; np_log_line "warning: $*"; }
np_die() {
    printf 'error: %s\n' "$*" >&2
    np_log_line "error: $*"
    NP_DIE_MSG="$*"
    exit 1
}

np_emit() { # json object
    [ -n "$NP_EVENT_FD" ] || return 0
    { printf '%s\n' "$1" >&"$NP_EVENT_FD"; } 2>/dev/null || true
}

# step_start <id> <title>; step_end <ok|warn|fail|skip> [detail]
step_start() {
    NP_STEP_ID="$1"
    NP_STEP_TITLE="$2"
    say "==> $2"
    np_emit "$(jq -cn --arg id "$1" --arg t "$2" '{event:"step",id:$id,title:$t,status:"start",detail:""}')"
    if [ "${NP_JOURNAL_OPEN:-0}" = 1 ]; then journal_step "$1"; fi
}
step_end() {
    local st="$1" detail="${2:-}"
    case "$st" in
        ok) [ -n "$detail" ] && say "    ok: $detail" ;;
        warn) warn "$detail" ;;
        fail) printf 'FAILED: %s\n' "$detail" >&2; np_log_line "FAILED: $detail" ;;
        skip) [ -n "$detail" ] && say "    skipped: $detail" ;;
    esac
    np_emit "$(jq -cn --arg id "$NP_STEP_ID" --arg t "${NP_STEP_TITLE:-}" --arg s "$st" --arg d "$detail" \
        '{event:"step",id:$id,title:$t,status:$s,detail:$d}')"
}
# step_fail <detail>: ends the current step as failed and exits 1.
step_fail() { step_end fail "$1"; NP_DIE_MSG="$1"; exit 1; }

np_result() { # status exit detail
    [ "$NP_RESULT_SENT" = 1 ] && return 0
    NP_RESULT_SENT=1
    np_emit "$(jq -cn --arg op "$NP_OP" --arg s "$1" --argjson e "$2" --arg d "${3:-}" \
        '{event:"result",op:$op,status:$s,exit:$e,detail:$d}')"
}

np_sha256() { shasum -a 256 "$1" | cut -c1-64; }
np_sha256_str() { printf '%s' "$1" | shasum -a 256 | cut -c1-64; }

# ---------------------------------------------------------------------------------------------
# Confirmations. There is no --yes. A prompt is satisfied by:
#   1. a token: NP_CONFIRM_TOKEN (comma-separated) or --confirmed-plan <token> containing
#      sha256("<id>\n<text>") of exactly the text the engine would show. A GUI gets the token
#      from a {"event":"confirm"} line, shows the text in its own dialog and re-runs with it.
#   2. the user typing "yes" on a terminal (not in --json mode).
#   3. test mode only: NP_TEST_ANSWER_<ID>=yes|no.
# Returns 0 confirmed, 1 declined, 3 needs confirmation (a confirm event was emitted).
NP_CONFIRMED_PLANS="${NP_CONFIRMED_PLANS:-}"
np_confirm() {
    local id="$1" text="$2" token ans var
    token="$(printf '%s\n%s' "$id" "$text" | shasum -a 256 | cut -c1-64)"
    NP_LAST_TOKEN="$token"
    case ",${NP_CONFIRM_TOKEN:-},$NP_CONFIRMED_PLANS," in
        *",$token,"*) say "confirmed by token: $id"; return 0 ;;
    esac
    if np_test_mode; then
        var="NP_TEST_ANSWER_$(printf '%s' "$id" | tr '[:lower:]-' '[:upper:]_')"
        ans="${!var:-}"
        if [ -n "$ans" ]; then
            np_log_line "test answer $id: $ans"
            [ "$ans" = yes ] && return 0
            return 1
        fi
    elif [ "$NP_JSON" != 1 ] && [ -t 0 ]; then
        printf '\n%s\n\nType yes to continue: ' "$text" >&"$NP_HUMAN_FD"
        IFS= read -r ans || ans=""
        np_log_line "confirm $id: answered '${ans}'"
        [ "$ans" = yes ] && return 0
        return 1
    fi
    np_emit "$(jq -cn --arg id "$id" --arg t "$text" --arg k "$token" '{event:"confirm",id:$id,text:$t,token:$k}')"
    say "needs confirmation ($id): show the text below to the user, then re-run with NP_CONFIRM_TOKEN=$token"
    say "$text"
    return 3
}

# macOS dialog for reapply --auto; no answer within the timeout means no.
np_dialog() { # id text -> 0 "Re-apply", 1 "Not now", 2 no answer (timeout, or the dialog failed)
    local ans
    if np_test_mode; then
        ans="${NP_TEST_DIALOG_ANSWER:-none}"
        np_log_line "test dialog $1: $ans"
        case "$ans" in yes) return 0 ;; no) return 1 ;; *) return 2 ;; esac
    fi
    ans="$(osascript - "$2" <<'OSA' 2>/dev/null || true
on run argv
    set r to display dialog (item 1 of argv) with title "Steam Play" buttons {"Not now", "Re-apply"} default button "Not now" giving up after 600
    if gave up of r then return "none"
    return button returned of r
end run
OSA
)"
    np_log_line "dialog $1: $ans"
    case "$ans" in "Re-apply") return 0 ;; "Not now") return 1 ;; *) return 2 ;; esac
}

# reapply --auto hands a Valve-replaced Steam.app to an interactive reapply in Terminal.
np_open_terminal_reapply() {
    local cmdf="$NP_SUPPORT/tools/reapply-now.command"
    mkdir -p "$NP_SUPPORT/tools" || return 1
    {
        printf '#!/bin/bash\n# Written by install.sh reapply --auto: re-apply Steam Play after a Steam update.\n'
        printf 'export NP_HOME=%q NP_STEAM_APP=%q NP_STEAM_SUPPORT=%q NP_SUPPORT=%q NP_BACKUP_DIR=%q\n' \
            "$NP_HOME" "$NP_STEAM_APP" "$NP_STEAM_SUPPORT" "$NP_SUPPORT" "$NP_BACKUP_DIR"
        # The watcher that opened this may still be finishing; wait for its lock.
        printf 'for i in $(seq 30); do [ -L %q ] || break; sleep 1; done\n' "$NP_SUPPORT/.install.lock"
        printf 'exec /bin/bash %q reapply\n' "$ROOT/scripts/install.sh"
    } > "$cmdf.tmp" && chmod 755 "$cmdf.tmp" && mv -f "$cmdf.tmp" "$cmdf" || return 1
    if np_test_mode; then
        echo "open-terminal $cmdf" >> "$NP_TEST_ROOT/ctl/open.log"
        return 0
    fi
    /usr/bin/open -a Terminal "$cmdf"
}

np_notify() { # text
    NP_NOTIFIED=1
    np_log_line "notify: $1"
    np_emit "$(jq -cn --arg t "$1" '{event:"notify",text:$t}')"
    np_test_mode && return 0
    osascript - "$1" >/dev/null 2>&1 <<'OSA' || true
on run argv
    display notification (item 1 of argv) with title "Steam Play"
end run
OSA
}

# Test-only fault injection: NP_TEST_FAIL_AT=<point> makes that point fail;
# NP_TEST_FAIL_SIGNAL=1 sends SIGINT to the installer instead (Ctrl-C).
np_fail_point() {
    np_test_mode || return 0
    [ "${NP_TEST_FAIL_AT:-}" = "$1" ] || return 0
    say "test: injected failure at $1"
    if [ "${NP_TEST_FAIL_SIGNAL:-0}" = 1 ]; then
        # Wait without a child process: bash drops a SIGINT that arrives while it waits for a
        # foreground child which then exits normally (a real Ctrl-C reaches the child too).
        local end=$((SECONDS + 3))
        kill -INT $$
        while [ "$SECONDS" -lt "$end" ]; do :; done
    fi
    return 1
}

# ---------------------------------------------------------------------------------------------
# Lock and run log.
NP_LOCKED=0
# The lock is a symlink whose target is the owner's pid: creating it is atomic, so there is no
# moment where the lock exists without a pid in it.
np_lock() {
    local l="$NP_SUPPORT/.install.lock" pid
    mkdir -p "$NP_SUPPORT"
    if ! ln -s "$$" "$l" 2>/dev/null; then
        pid="$(readlink "$l" 2>/dev/null || true)"
        case "$pid" in ''|*[!0-9]*) [ -d "$l" ] && pid="$(cat "$l/pid" 2>/dev/null || true)" ;; esac   # pre-symlink lock dir
        if [ -n "$pid" ] && np_pid_alive "$pid" && np_pid_is_installer "$pid"; then
            np_die "another install.sh is running (pid $pid)"
        fi
        # Stale (dead, or the pid now belongs to something else): remove it only if it still names
        # the same owner, then race for it again.
        if [ -L "$l" ] && [ "$(readlink "$l")" = "$pid" ]; then rm -f "$l"; elif [ -d "$l" ] && [ ! -L "$l" ]; then rm -rf "$l"; fi
        ln -s "$$" "$l" 2>/dev/null || np_die "cannot take the lock $l (another run just took it?)"
    fi
    NP_LOCKED=1
}
# kill -0 fails with EPERM for a live process of another user: that counts as alive.
np_pid_alive() {
    local err
    err="$(kill -0 "$1" 2>&1)" && return 0
    case "$err" in *"not permitted"*) return 0 ;; esac
    return 1
}
# The pid may have been reused; only an install.sh counts. If ps cannot tell, assume it is one.
np_pid_is_installer() {
    local cmd
    cmd="$(ps -o command= -p "$1" 2>/dev/null)" || return 0
    case "$cmd" in *install.sh*) return 0 ;; esac
    return 1
}
np_unlock() {
    [ "$NP_LOCKED" = 1 ] || return 0
    [ "$(readlink "$NP_SUPPORT/.install.lock" 2>/dev/null)" = "$$" ] && rm -f "$NP_SUPPORT/.install.lock"
    NP_LOCKED=0
}

# Staging dirs removed at exit (an array, so paths are never word-split or globbed).
NP_CLEANUP_DIRS=()
np_cleanup_add() { NP_CLEANUP_DIRS+=("$1"); }

# A few moves that must not be cut in half (swap of runner, bridge, signatures): signals are
# held off and then re-installed as the main handler.
# Inside np_on_exit (NP_IN_EXIT=1) signals stay ignored: re-arming them there would let a second
# Ctrl-C cut the rollback short.
NP_IN_EXIT=0
NP_SIGNAL_TRAP='trap "" INT TERM HUP; NP_DIE_MSG="interrupted"; exit 130'
np_critical_begin() { trap '' INT TERM HUP; }
# shellcheck disable=SC2064 # NP_SIGNAL_TRAP is a fixed handler string
np_critical_end() { [ "$NP_IN_EXIT" = 1 ] || trap "$NP_SIGNAL_TRAP" INT TERM HUP; }

np_open_log() { # op
    mkdir -p "$NP_SUPPORT/logs"
    NP_RUN_LOG="$NP_SUPPORT/logs/$1-$(np_stamp)-$$.log"
    : > "$NP_RUN_LOG"
    np_log_line "install.sh $1 (repo $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'), test mode ${NP_TEST_MODE:-0})"
}

# Runs a command with its output in the run log only. Status is the command's.
np_quiet() {
    if [ -n "$NP_RUN_LOG" ]; then "$@" >> "$NP_RUN_LOG" 2>&1; else "$@" >/dev/null 2>&1; fi
}
