# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by install.sh and the other libs
# Steam.app: classification, tree hash, backup, patch, restore, update blocking, Steam control.
# All paths come from np_init_paths (NP_STEAM_APP, NP_STEAM_SUPPORT, NP_BACKUP_DIR, ...).

# --- reading -----------------------------------------------------------------------------------
sa_plist_get() { # app key
    plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}
sa_insert() { sa_plist_get "$1" LSEnvironment.DYLD_INSERT_LIBRARIES; }
sa_exe() { sa_plist_get "$1" CFBundleExecutable; }
sa_version() {
    local s b
    s="$(sa_plist_get "$1" CFBundleShortVersionString)"
    b="$(sa_plist_get "$1" CFBundleVersion)"
    printf '%s (%s)\n' "${s:-?}" "${b:-?}"
}
sa_codesign_info() { "$NP_CODESIGN" -dvvv "$1" 2>&1 || true; }
sa_cdhash() { sa_codesign_info "$1" | sed -n 's/^CDHash=//p' | head -1; }

# TeamIdentifier of the bundle's signature, "none" for ad-hoc or unsigned.
# Test mode only: NP_TEST_TEAMID_OVERRIDE="TEAM@cdhash[,TEAM@cdhash...]" reports TEAM for a
# bundle whose cdhash matches, so a fake ad-hoc-signed Steam.app can stand in for Valve's.
sa_team() {
    local info team cd e
    info="$(sa_codesign_info "$1")"
    team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    case "$team" in ''|'not set') team=none ;; esac
    if np_test_mode && [ -n "${NP_TEST_TEAMID_OVERRIDE:-}" ]; then
        cd="$(printf '%s\n' "$info" | sed -n 's/^CDHash=//p' | head -1)"
        local IFS=,
        for e in $NP_TEST_TEAMID_OVERRIDE; do
            [ -n "$cd" ] && [ "${e#*@}" = "$cd" ] && team="${e%%@*}"
        done
    fi
    printf '%s\n' "$team"
}
sa_verify() { "$NP_CODESIGN" --verify --deep --strict "$1" >/dev/null 2>&1; }

# Valve's own bundle: signature verifies, Valve's TeamID, no insert.
sa_is_valve() {
    [ -d "$1" ] || return 1
    [ -z "$(sa_insert "$1")" ] || return 1
    sa_verify "$1" || return 1
    [ "$(sa_team "$1")" = "$NP_VALVE_TEAM" ]
}

# pristine | ours | adoptable | foreign | missing
sa_classify() {
    local app="$1" ins
    [ -d "$app" ] || { echo missing; return 0; }
    ins="$(sa_insert "$app")"
    if [ -z "$ins" ]; then
        if sa_is_valve "$app"; then echo pristine; else echo foreign; fi
        return 0
    fi
    if [ "$ins" = "$app/Contents/MacOS/notproton.dylib" ] && [ -f "$ins" ]; then
        if [ -n "$(state_get '.steam.patched.dylib_sha256')" ] && [ -n "$(state_get '.steam.active_backup')" ]; then
            echo ours
        else
            echo adoptable
        fi
        return 0
    fi
    echo foreign
}

# sha256 over the sorted list of "<sha256>  <path>" for every regular file and
# "L <target>  <path>" for every symlink (hashed by target), paths relative to the bundle.
sa_tree_hash() {
    [ -d "$1" ] || return 1
    (
        set -o pipefail
        cd "$1" || exit 1
        {
            find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
            find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
                printf 'L %s  %s\n' "$(readlink "$p")" "$p"
            done
        } | LC_ALL=C sort | shasum -a 256 | cut -c1-64
    )
}

# --- Steam control (stubbable in test mode) ----------------------------------------------------
sa_steamctl() { # running|quit|start
    if np_test_mode; then
        "$NP_TEST_STEAMCTL" "$1"
        return
    fi
    case "$1" in
        running) pgrep -x steam_osx >/dev/null 2>&1 ;;
        quit) osascript -e 'quit app "Steam"' >/dev/null 2>&1 ;;
        start) open -a "$NP_STEAM_APP" ;;
        *) return 2 ;;
    esac
}
sa_steam_running() { sa_steamctl running; }

# Asks Steam to quit and waits; never force-kills. 1 if it is still running.
sa_quit_steam() {
    sa_steam_running || return 0
    say "    asking Steam to quit..."
    sa_steamctl quit || true
    local waited=0
    while sa_steam_running; do
        if [ "$(awk -v w="$waited" -v t="$NP_QUIT_TIMEOUT" 'BEGIN{print (w>=t)?1:0}')" = 1 ]; then
            return 1
        fi
        sleep "$NP_POLL_INTERVAL"
        waited="$(awk -v w="$waited" -v i="$NP_POLL_INTERVAL" 'BEGIN{print w+i}')"
    done
    return 0
}

sa_lsregister() { "$NP_LSREGISTER" -f "$1" >/dev/null 2>&1 || true; }

# --- backup ------------------------------------------------------------------------------------
# sa_backup <app> <kind: original|snapshot> -> sets SA_BK_PATH, SA_BK_HASH. Copies with ditto,
# then checks the copy: signature (and Valve's TeamID for an original) and tree hash equal.
sa_backup() {
    local app="$1" kind="$2" prefix dst src_hash tries=0
    case "$kind" in
        original) prefix="Steam.app." ;;
        snapshot) prefix="Steam.app.prepatch-" ;;
        *) return 1 ;;
    esac
    mkdir -p "$NP_BACKUP_DIR"
    # Names carry the time to the second (adoption reads it back); two backups within the same
    # second wait for the next one instead of colliding. Existing backups are never touched.
    dst="$NP_BACKUP_DIR/$prefix$(np_stamp)"
    while [ -e "$dst" ] || [ -e "$dst.partial" ]; do
        tries=$((tries + 1))
        [ "$tries" -le 3 ] || { warn "backup $dst already exists"; return 1; }
        sleep 1
        dst="$NP_BACKUP_DIR/$prefix$(np_stamp)"
    done
    src_hash="$(sa_tree_hash "$app")" || return 1
    SA_BACKUP_PARTIAL="$dst.partial"   # removed by np_on_exit if this is interrupted
    if ! ditto "$app" "$dst.partial" || ! np_fail_point backup.after_copy; then
        rm -rf "$dst.partial"
        SA_BACKUP_PARTIAL=""
        warn "ditto to $dst failed"
        return 1
    fi
    if ! sa_verify "$dst.partial"; then
        rm -rf "$dst.partial"
        warn "the copy's signature does not verify"
        return 1
    fi
    if [ "$kind" = original ] && [ "$(sa_team "$dst.partial")" != "$NP_VALVE_TEAM" ]; then
        rm -rf "$dst.partial"
        warn "the copy is not signed by Valve ($NP_VALVE_TEAM)"
        return 1
    fi
    SA_BK_HASH="$(sa_tree_hash "$dst.partial")" || return 1
    if [ "$SA_BK_HASH" != "$src_hash" ]; then
        rm -rf "$dst.partial"
        warn "the copy's tree hash differs from Steam.app"
        return 1
    fi
    mv "$dst.partial" "$dst" || return 1
    SA_BACKUP_PARTIAL=""
    SA_BK_PATH="$dst"
    return 0
}

# Checks a recorded or candidate backup: Valve-signed, no insert and (if given) the tree hash.
sa_backup_ok() { # path [expected_hash]
    [ -d "$1" ] || return 1
    sa_is_valve "$1" || return 1
    [ -z "${2:-}" ] && return 0
    [ "$(sa_tree_hash "$1")" = "$2" ]
}

# Newest Valve-verified bundle in NP_BACKUP_DIR. Only names made by a full backup count,
# Steam.app.YYYY-MM-DD-HHMM or Steam.app.YYYY-MM-DD-HHMMSS (never patched-, prepatch-,
# badrestore-, failed- or .partial copies); "newest" is by the date in the name.
sa_newest_valve_backup() {
    local d n key best="" bestkey=""
    [ -d "$NP_BACKUP_DIR" ] || return 0
    for d in "$NP_BACKUP_DIR"/Steam.app.*; do
        [ -d "$d" ] || continue
        n="${d##*/Steam.app.}"
        [[ "$n" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}([0-9]{2})?$ ]] || continue
        key="${n//-/}"
        [ "${#key}" = 12 ] && key="${key}00"
        [ -z "$bestkey" ] || [[ "$key" > "$bestkey" ]] || continue
        sa_is_valve "$d" || continue
        best="$d" bestkey="$key"
    done
    [ -n "$best" ] && printf '%s\n' "$best"
    return 0
}

# --- restore -----------------------------------------------------------------------------------
# Hidden bundles a restore leaves next to Steam.app only if it was cut off mid-way.
sa_leftovers() {
    local f parent
    parent="$(dirname "$NP_STEAM_APP")"
    for f in "$parent"/.Steam.app.aside-* "$parent"/.Steam.app.restore-*; do
        [ -e "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# sa_restore <src> <expected tree hash> <require valve 0|1> <label>
# ditto src to a temp copy next to Steam.app, verify it, move Steam.app aside, swap the copy in,
# verify again; swap back on any failure. The replaced bundle ends up as
# NP_BACKUP_DIR/Steam.app.<label>-<ts> (nothing is deleted). Every message says where each
# bundle really is.
sa_restore() {
    local src="$1" want="$2" valve="$3" label="$4" app="$NP_STEAM_APP" parent tmp aside keep bad
    parent="$(dirname "$app")"
    tmp="$parent/.Steam.app.restore-$$"
    aside="$parent/.Steam.app.aside-$$"
    keep="$NP_BACKUP_DIR/Steam.app.$label-$(np_stamp)"
    bad="$NP_BACKUP_DIR/Steam.app.badrestore-$(np_stamp)"
    SA_RESTORE_KEPT=""
    [ -d "$src" ] || { warn "restore source $src is missing"; return 1; }
    [ ! -e "$tmp" ] && [ ! -e "$aside" ] || { warn "leftover $tmp or $aside, check by hand"; return 1; }
    SA_RESTORE_TMP="$tmp"   # removed by np_on_exit if the copy is interrupted
    if ! ditto "$src" "$tmp" || ! np_fail_point restore.after_copy; then rm -rf "$tmp"; SA_RESTORE_TMP=""; warn "ditto $src failed; Steam.app was not changed"; return 1; fi
    if ! sa_restore_check "$tmp" "$want" "$valve"; then
        rm -rf "$tmp"
        SA_RESTORE_TMP=""
        warn "the restore copy does not verify; Steam.app was not changed"
        return 1
    fi
    # Aside + swap must not be split by a signal (a Steam.app that is only "aside" is missing).
    np_critical_begin
    if [ -e "$app" ]; then
        mv "$app" "$aside" || { np_critical_end; rm -rf "$tmp"; SA_RESTORE_TMP=""; warn "cannot move Steam.app aside (App Management permission?); Steam.app was not changed"; return 1; }
    fi
    if ! mv "$tmp" "$app"; then
        rm -rf "$tmp"
        SA_RESTORE_TMP=""
        if [ ! -e "$aside" ]; then
            warn "cannot move the restored copy into place; there was no Steam.app before"
        elif mv "$aside" "$app"; then
            warn "cannot move the restored copy into place; the previous Steam.app was put back"
        else
            warn "cannot move the restored copy into place, and the previous Steam.app could NOT be put back: it is at $aside"
        fi
        np_critical_end
        return 1
    fi
    SA_RESTORE_TMP=""
    np_critical_end
    if ! np_fail_point restore.after_swap || ! sa_restore_check "$app" "$want" "$valve"; then
        warn "restored Steam.app does not verify; swapping back"
        mkdir -p "$NP_BACKUP_DIR"
        np_critical_begin
        if ! mv "$app" "$tmp.bad"; then
            np_critical_end
            warn "cannot move the failed copy away; Steam.app is the unverified copy and the previous one is at $aside"
            return 1
        fi
        if [ ! -e "$aside" ]; then
            warn "there was no Steam.app before; none is in place now"
        elif mv "$aside" "$app"; then
            warn "the previous Steam.app was put back"
        else
            warn "the previous Steam.app could NOT be put back; it is at $aside"
        fi
        np_critical_end
        if mv "$tmp.bad" "$bad"; then warn "the copy that failed verification is kept at $bad"
        else warn "the copy that failed verification stays at $tmp.bad"; fi
        return 1
    fi
    if [ -e "$aside" ]; then
        mkdir -p "$NP_BACKUP_DIR"
        if mv "$aside" "$keep"; then SA_RESTORE_KEPT="$keep"
        else warn "the replaced bundle stays at $aside"; SA_RESTORE_KEPT="$aside"; fi
    fi
    sa_lsregister "$app"
    return 0
}
sa_restore_check() { # path want valve
    sa_verify "$1" || return 1
    [ "$(sa_tree_hash "$1")" = "$2" ] || return 1
    if [ "$3" = 1 ]; then [ "$(sa_team "$1")" = "$NP_VALVE_TEAM" ] || return 1; fi
    return 0
}

# --- patch -------------------------------------------------------------------------------------
# sa_patch <app> <dylib>: dylib first (EPERM there means App Management permission is missing
# and nothing has changed), then the Info.plist insert, ad-hoc signatures, lsregister, verify.
# Returns 1 on any failure; the caller restores the snapshot.
sa_patch() {
    local app="$1" src="$2" dst="$1/Contents/MacOS/notproton.dylib" plist="$1/Contents/Info.plist" exe err
    exe="$(sa_exe "$app")"
    [ -n "$exe" ] && [ -f "$app/Contents/MacOS/$exe" ] || { warn "no main executable in $app"; return 1; }
    np_fail_point patch.before_copy || return 1
    err="$(cp -f "$src" "$dst.new" 2>&1)" || {
        rm -f "$dst.new" 2>/dev/null || true
        case "$err" in
            *"Operation not permitted"*)
                warn "macOS blocked the write into Steam.app: allow your terminal (or the app) under System Settings > Privacy & Security > App Management. Nothing was changed." ;;
            *) warn "cannot copy the dylib into Steam.app: $err" ;;
        esac
        SA_PATCH_NOTHING_CHANGED=1
        return 1
    }
    mv -f "$dst.new" "$dst" || return 1
    np_fail_point patch.after_copy || return 1
    if ! plutil -extract LSEnvironment xml1 -o /dev/null "$plist" >/dev/null 2>&1; then
        plutil -insert LSEnvironment -dictionary "$plist" || return 1
    fi
    plutil -remove LSEnvironment.DYLD_INSERT_LIBRARIES "$plist" >/dev/null 2>&1 || true
    plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string "$dst" "$plist" || return 1
    np_fail_point patch.after_plist || return 1
    # The bootstrapper carries the hardened runtime, which drops DYLD_INSERT_LIBRARIES; an
    # ad-hoc signature without it lets the insert through (and replaces Valve's signature).
    # The support copy is already ad-hoc signed (support_install), so the copy in Steam.app keeps
    # the same bytes; it is only re-signed if its signature does not verify.
    "$NP_CODESIGN" --verify "$dst" >/dev/null 2>&1 || np_quiet "$NP_CODESIGN" -f -s - "$dst" || return 1
    np_quiet "$NP_CODESIGN" -f -s - "$app/Contents/MacOS/$exe" || return 1
    np_quiet "$NP_CODESIGN" -f -s - "$app" || return 1
    np_fail_point patch.after_sign || return 1
    sa_lsregister "$app"
    [ "$(sa_insert "$app")" = "$dst" ] || { warn "insert not in Info.plist after patching"; return 1; }
    [ "$(np_sha256 "$dst")" = "$(np_sha256 "$src")" ] || { warn "dylib in Steam.app differs from the built one"; return 1; }
    sa_verify "$app" || { warn "patched Steam.app does not verify"; return 1; }
    return 0
}

# Detach without a Valve backup: snapshot first, then remove insert and dylib, ad-hoc re-sign,
# verify. On failure the snapshot is restored. SA_BK_PATH names the snapshot.
sa_detach() {
    local app="$1" exe snap snaph
    exe="$(sa_exe "$app")"
    [ -n "$exe" ] || { warn "no main executable in $app"; return 1; }
    sa_backup "$app" snapshot || { warn "could not snapshot Steam.app before detaching; nothing changed"; return 1; }
    snap="$SA_BK_PATH" snaph="$SA_BK_HASH"
    # From here on a failure or a signal restores the snapshot (np_on_exit).
    NP_ROLLBACK_HASH="$snaph"
    NP_ROLLBACK_VALVE=0
    NP_ROLLBACK="$snap"
    np_fail_point detach.after_snapshot || { warn "detaching failed; restoring the snapshot $snap"; return 1; }
    if plutil -remove LSEnvironment.DYLD_INSERT_LIBRARIES "$app/Contents/Info.plist" >/dev/null 2>&1 || [ -z "$(sa_insert "$app")" ]; then
        if rm -f "$app/Contents/MacOS/notproton.dylib" \
            && np_quiet "$NP_CODESIGN" -f -s - "$app/Contents/MacOS/$exe" \
            && np_quiet "$NP_CODESIGN" -f -s - "$app" \
            && [ -z "$(sa_insert "$app")" ] && sa_verify "$app"; then
            NP_ROLLBACK=""
            sa_lsregister "$app"
            return 0
        fi
    fi
    warn "detaching failed; the snapshot $snap is restored on exit"
    return 1
}

# Clears an insert NotProton may have put into the inner client's Info.plist.
sa_clear_inner_insert() {
    [ -f "$NP_INNER_PLIST" ] || return 0
    local ins
    ins="$(plutil -extract LSEnvironment.DYLD_INSERT_LIBRARIES raw -o - "$NP_INNER_PLIST" 2>/dev/null || true)"
    case "$ins" in
        *notproton*) plutil -remove LSEnvironment.DYLD_INSERT_LIBRARIES "$NP_INNER_PLIST" && say "    cleared the inner client's insert" ;;
    esac
}

# --- update blocking ---------------------------------------------------------------------------
# Outer $NP_STEAM_SUPPORT/steam.cfg and, if its folder exists, the inner client's steam.cfg.
# The first time a file is changed its previous content (without our line) is kept as .orig, or
# a .notproton-absent marker if it did not exist; uninstall puts that back.
cfg_paths() {
    printf '%s\n' "$NP_STEAM_SUPPORT/steam.cfg"
    [ -d "$NP_INNER_MACOS" ] && printf '%s\n' "$NP_INNER_MACOS/steam.cfg"
    return 0
}
cfg_block_one() {
    local f="$1" tmp
    mkdir -p "$(dirname "$f")"
    if [ ! -e "$f.orig" ] && [ ! -e "$f.notproton-absent" ]; then
        if [ -f "$f" ]; then
            grep -vxF "$NP_UPDATE_LINE" "$f" > "$f.orig.tmp" || true
            if [ ! -s "$f.orig.tmp" ] && grep -qxF "$NP_UPDATE_LINE" "$f"; then
                rm -f "$f.orig.tmp"            # only our line: it did not exist before us
                : > "$f.notproton-absent"
            else
                mv -f "$f.orig.tmp" "$f.orig"
            fi
        else
            : > "$f.notproton-absent"
        fi
    fi
    grep -qxF "$NP_UPDATE_LINE" "$f" 2>/dev/null && return 0
    tmp="$f.np-tmp"
    { [ -f "$f" ] && cat "$f"; printf '%s\n' "$NP_UPDATE_LINE"; } > "$tmp" || return 1
    mv -f "$tmp" "$f"
}
cfg_unblock_one() {
    local f="$1"
    if [ -f "$f.orig" ]; then
        mv -f "$f.orig" "$f"
    elif [ -e "$f.notproton-absent" ]; then
        rm -f "$f" "$f.notproton-absent"
    elif [ -f "$f" ] && grep -qxF "$NP_UPDATE_LINE" "$f"; then
        grep -vxF "$NP_UPDATE_LINE" "$f" > "$f.np-tmp" || true
        mv -f "$f.np-tmp" "$f"
    fi
    return 0
}
cfg_blocked() { grep -qxF "$NP_UPDATE_LINE" "$1" 2>/dev/null; }

# Blocks both; records them in the state; 1 if any failed (a warning for the caller).
cfg_block_all() {
    local f rc=0 outer="$NP_STEAM_SUPPORT/steam.cfg" inner="$NP_INNER_MACOS/steam.cfg" oi=false ii=false
    while IFS= read -r f; do
        cfg_block_one "$f" || { warn "could not block updates in $f"; rc=1; }
    done < <(cfg_paths)
    cfg_blocked "$outer" && oi=true
    cfg_blocked "$inner" && ii=true
    state_update '.update_block = {outer: {path: $o, applied: ($oi == "true")},
                                   inner: {path: $i, applied: ($ii == "true")}, at: $__now}' \
        --arg o "$outer" --arg i "$inner" --arg oi "$oi" --arg ii "$ii"
    return $rc
}
cfg_unblock_all() {
    local f
    for f in "$NP_STEAM_SUPPORT/steam.cfg" "$NP_INNER_MACOS/steam.cfg"; do
        cfg_unblock_one "$f"
    done
}
