# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by install.sh and the other libs
# install-state.json: what the installer did, so doctor, reapply and uninstall can check and
# undo it. Written only through jq into a temp file in the same dir, chmod 600, then mv (atomic).
# Holds no account data. Schema (version 1):
#   schema, created_at, repo{commit, notproton_commit}, dylib_version
#   steam{app, original{version, team, cdhash, tree_sha256}, backups[{path, kind, created_at,
#         tree_sha256, team, cdhash, version}], active_backup, patched{at, dylib_sha256, cdhash,
#         version}}
#   client{steamclient_sha256, steamui_sha256, binary_build, gate{profile, resolved, required,
#          result, anchorcheck_sha256, at}}
#   update_block{outer{path, applied}, inner{path, applied}}
#   runners{<ver>{source, url, tarball_sha256, manifest, manifest_sha256, installed_at,
#           d3dmetal{status, archive_sha256, license_sha256, accepted_at, files_manifest}}}
#   current, bridge{files{<rel>: sha256}, at}, support{files{<name>: sha256}, run_script_sha256,
#   version, at}, verify{log_offset, result, detail, at}
#   journal{state: idle|in_progress|done|failed|aborted|failed_rollback, op, step, pid,
#           started_at, updated_at, snapshot}
#   history[{at, op, result, note}]   (last 100)

state_exists() { [ -f "$NP_STATE_FILE" ]; }

state_write_raw() { # file-with-json -> installs it as the state file
    local src="$1" tmp
    tmp="$(mktemp "$NP_SUPPORT/.install-state.XXXXXX")"
    jq . "$src" > "$tmp" || { rm -f "$tmp"; np_die "state: refusing to write invalid JSON"; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$NP_STATE_FILE"
}

state_init() {
    state_exists && { jq -e . "$NP_STATE_FILE" >/dev/null 2>&1 || np_die "state file is not valid JSON: $NP_STATE_FILE"; return 0; }
    mkdir -p "$NP_SUPPORT"
    local tmp
    tmp="$(mktemp "$NP_SUPPORT/.install-state.XXXXXX")"
    jq -n --argjson schema "$NP_STATE_SCHEMA" --arg now "$(np_now)" --arg app "$NP_STEAM_APP" '{
        schema: $schema, created_at: $now, repo: {}, dylib_version: null,
        steam: {app: $app, original: null, backups: [], active_backup: null, patched: null},
        client: {}, update_block: {}, runners: {}, current: null,
        bridge: null, support: null, verify: null,
        journal: {state: "idle"}, history: []
    }' > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$NP_STATE_FILE"
}

# state_get <jq filter>: raw output; empty for null/missing
state_get() {
    state_exists || return 0
    jq -r "($1) // empty" "$NP_STATE_FILE" 2>/dev/null || true
}

# state_update <jq filter> [jq options like --arg k v ...]
state_update() {
    local filter="$1" tmp
    shift
    state_exists || state_init
    tmp="$(mktemp "$NP_SUPPORT/.install-state.XXXXXX")"
    if ! jq "$@" --arg __now "$(np_now)" "$filter" "$NP_STATE_FILE" > "$tmp"; then
        rm -f "$tmp"
        np_die "state update failed: $filter"
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$NP_STATE_FILE"
}

history_add() { # op result note
    state_update '.history = ((.history // []) + [{at: $__now, op: $op, result: $r, note: $n}])[-100:]' \
        --arg op "$1" --arg r "$2" --arg n "${3:-}"
}

# Journal: an interrupted run (power loss, kill -9) leaves "in_progress" behind.
NP_JOURNAL_OPEN=0
journal_state() { state_get '.journal.state'; }

journal_guard() {
    local st step op
    st="$(journal_state)"
    case "$st" in
        in_progress|failed_rollback)
            step="$(state_get '.journal.step')"
            op="$(state_get '.journal.op')"
            np_die "the last '$op' run stopped at step '$step' (journal: $st). Steam.app may be half changed.
Check it with: install.sh doctor
Then restore with: install.sh uninstall   (or, once Steam.app checks out: install.sh journal-clear)" ;;
    esac
}

journal_begin() { # op
    state_update '.journal = {state: "in_progress", op: $op, step: "start", pid: ($pid|tonumber),
        started_at: $__now, updated_at: $__now, snapshot: null}' --arg op "$1" --arg pid "$$"
    NP_JOURNAL_OPEN=1
}
journal_step() {
    state_update '.journal.step = $s | .journal.updated_at = $__now' --arg s "$1"
}
journal_set_snapshot() { # path or ""
    state_update '.journal.snapshot = (if $p == "" then null else $p end)' --arg p "$1"
}
journal_end() { # done|failed|aborted|failed_rollback [note]
    state_update '.journal.state = $s | .journal.updated_at = $__now' --arg s "$1"
    history_add "$(state_get '.journal.op')" "$1" "${2:-}"
    NP_JOURNAL_OPEN=0
}

state_archive() {
    state_exists || return 0
    mkdir -p "$NP_SUPPORT/state-archive"
    mv -f "$NP_STATE_FILE" "$NP_SUPPORT/state-archive/install-state.$(np_stamp).json"
}
