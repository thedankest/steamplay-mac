# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by install.sh and the other libs
# Signature gate (rule 5) and the post-install log check.
#
# anchorcheck dlopens the inner client from
# $HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ (HOME=NP_HOME)
# and, run without a profile argument, checks every profile in signatures/macos.arm64 (relative
# to its working directory). The profile whose recorded addresses the anchors land on is marked
# "<path>  build <N>  [live client]": that one describes the installed client. Exit codes: 0 pass,
# 1 mismatch, 2 bad profile, 3 cannot check.
#
# The gate passes only if all of these hold: one "[live client]" block over all profiles, named
# by its own header as <build>.json, which exists; then anchorcheck on that one profile exits 0,
# confirms it as the live client and reads "N anchors resolved, 0 unresolved" with N = the
# number of entries in that profile. Only that profile is then installed, so the
# dylib (which loads the highest-numbered profile it finds) loads exactly the one that was checked.

# Highest-numbered "<digits>.json" in a dir (the dylib's pick_latest_sigdb rule).
gate_profile() { # sigdir
    local f n best="" bestn=""
    for f in "$1"/*.json; do
        [ -f "$f" ] || continue
        n="${f##*/}"
        n="${n%.json}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        if [ -z "$bestn" ] || [ "$(printf '%s\n%s\n' "$n" "$bestn" | sort -n | tail -1)" = "$n" ]; then
            best="${f##*/}"
            bestn="$n"
        fi
    done
    printf '%s\n' "$best"
}

# Profiles come from notproton (upstream) and from this repo's signatures/macos.arm64, which holds
# profiles made with tools/make-signatures.py for client builds upstream does not cover yet. The
# same file name in both with different content is an error, not a silent pick. A generated
# profile counts only once a person marked it reviewed (make-signatures.md): the tool's own checks
# rest on the anchor alone.
gate_stage_profiles() { # dest dir
    local d="$1" f n
    mkdir -p "$d" || return 1
    cp -f "$NP_SIG_SRC"/*.json "$d/" || { warn "no signatures in $NP_SIG_SRC"; return 1; }
    for f in "$NP_SIG_SRC_LOCAL"/*.json; do
        [ -f "$f" ] || continue
        n="${f##*/}"
        if [ "$(jq -r 'if has("generated") then (.generated.reviewed == true) else true end' "$f" 2>/dev/null)" != true ]; then
            warn "$n was made by tools/make-signatures.py and is not marked reviewed; skipped"
            continue
        fi
        if [ -e "$d/$n" ] && ! cmp -s "$f" "$d/$n"; then
            warn "$n is in $NP_SIG_SRC and in $NP_SIG_SRC_LOCAL with different content; remove the local one"
            return 1
        fi
        cp -f "$f" "$d/" || return 1
    done
}

gate_profile_total() { # number of profiles gate_stage_profiles would stage
    local d f
    for d in "$NP_SIG_SRC" "$NP_SIG_SRC_LOCAL"; do
        for f in "$d"/*.json; do if [ -f "$f" ]; then printf '%s\n' "${f##*/}"; fi; done
    done | sort -u | wc -l | tr -d ' '
}

# One hash over everything the gate's answer depends on: the client, Steam.app, the staged
# profiles and anchorcheck. reapply --auto uses it so the same failure is reported only once.
gate_fingerprint() { # staged signatures dir, anchorcheck
    {
        printf 'sc %s\nui %s\napp %s\nac %s\n' "$GATE_SC_SHA" "$GATE_UI_SHA" "$(sa_cdhash "$NP_STEAM_APP")" "$(np_sha256 "$2" 2>/dev/null)"
        ( cd "$1" && for f in *.json; do if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(np_sha256 "$f")"; fi; done )
    } | shasum -a 256 | cut -c1-64
}

gate_count() { # profile.json [module] -> number of signatures (non-deprecated when module given)
    if [ -n "${2:-}" ]; then
        jq --arg m "$2" '[.signatures[] | select(.deprecated != true) | select((.module // "steamclient.dylib") == $m)] | length' "$1" 2>/dev/null
    else
        jq '.signatures | length' "$1" 2>/dev/null
    fi
}

# gate_parse: anchorcheck output on stdin ->
#   "<live blocks> <live header path|-> <live build|-> <resolved|-> <unresolved|-> <summaries>"
# A block header is "<path>  build <N>[  [live client]]"; its summary is the next
# "<n> anchors resolved, <m> unresolved" line.
gate_parse() {
    awk '
        /^[^ \t].*\.json  build [0-9]+/ {
            p = $0; sub(/  build .*$/, "", p)
            b = $0; sub(/.*  build /, "", b); sub(/[^0-9].*$/, "", b)
            cur = NR
            if ($0 ~ /\[live client\][ \t]*$/) { nlive++; lp = p; lb = b; lrow = NR }
            next
        }
        /^[ \t]+[0-9]+ anchors resolved, [0-9]+ unresolved/ {
            nsum++
            if (lrow != "" && cur == lrow && r == "") { r = $1; u = $4 }
        }
        END {
            printf "%d %s %s %s %s %d\n", nlive, (lp == "" ? "-" : lp), (lb == "" ? "-" : lb),
                (r == "" ? "-" : r), (u == "" ? "-" : u), nsum
        }'
}

# gate_run <root containing signatures/macos.arm64> <anchorcheck> -> 0 pass, 1 fail.
# 1. anchorcheck without arguments over every profile finds the live client's block. Its overall
#    exit code is not used: rows of other profiles (cross-database disagreements, anchors of
#    builds that are not installed) may fail it without saying anything about the live one.
# 2. anchorcheck on that one profile must then exit 0 with exactly one live block, for that file,
#    and N/N resolved, 0 unresolved (N = entries in the profile).
# Sets GATE_PROFILE (<build>.json of the live client) GATE_BUILD GATE_REQUIRED GATE_RESOLVED
# GATE_UNRESOLVED GATE_RC GATE_DETAIL GATE_AC_SHA GATE_NOLIVE (1: no profile fits this client),
# and the client hashes (gate_client_hashes).
gate_run() {
    local root="$1" ac="$2" out rc1 nlive lpath lbuild r u nsum
    GATE_PROFILE="" GATE_REQUIRED=0 GATE_RESOLVED=0 GATE_UNRESOLVED=0 GATE_RC=99 GATE_BUILD="" GATE_DETAIL="" GATE_AC_SHA="" GATE_NOLIVE=0
    gate_client_hashes
    [ -x "$ac" ] || { GATE_DETAIL="anchorcheck missing: $ac"; return 1; }
    GATE_AC_SHA="$(np_sha256 "$ac")"
    [ -n "$(gate_profile "$root/signatures/macos.arm64")" ] || { GATE_DETAIL="no signature profile in $root/signatures/macos.arm64"; return 1; }

    out="$(cd "$root" && HOME="$NP_HOME" "$ac" 2>&1)" && rc1=0 || rc1=$?
    np_log_line "anchorcheck, all profiles (rc $rc1):"
    if [ -n "$NP_RUN_LOG" ]; then printf '%s\n' "$out" >> "$NP_RUN_LOG"; fi
    read -r nlive lpath lbuild r u nsum <<< "$(printf '%s\n' "$out" | gate_parse)"
    if [ "$nsum" = 0 ]; then
        GATE_RC=$rc1
        GATE_DETAIL="anchorcheck printed no summary (exit $rc1)"
        return 1
    fi
    if [ "$nlive" = 0 ]; then
        GATE_NOLIVE=1 GATE_RC=$rc1
        GATE_DETAIL="no signature profile describes this Steam client (no [live client] in anchorcheck, exit $rc1)"
        return 1
    fi
    if [ "$nlive" != 1 ]; then
        GATE_RC=$rc1
        GATE_DETAIL="anchorcheck marked $nlive profiles as the live client"
        return 1
    fi
    # The profile is named by the live block's own header, and must be <build>.json.
    if [ "${lpath##*/}" != "$lbuild.json" ]; then
        GATE_RC=$rc1
        GATE_DETAIL="the live block's header ($lpath) does not name $lbuild.json"
        return 1
    fi
    GATE_BUILD="$lbuild"
    GATE_PROFILE="$lbuild.json"
    if [ ! -f "$root/signatures/macos.arm64/$GATE_PROFILE" ]; then
        GATE_DETAIL="the live client is build $GATE_BUILD, but there is no $GATE_PROFILE"
        GATE_PROFILE=""
        return 1
    fi
    GATE_REQUIRED="$(gate_count "$root/signatures/macos.arm64/$GATE_PROFILE")"
    case "$GATE_REQUIRED" in ''|*[!0-9]*|0) GATE_DETAIL="cannot count the signatures in $GATE_PROFILE"; GATE_REQUIRED=0; return 1 ;; esac

    out="$(cd "$root" && HOME="$NP_HOME" "$ac" "signatures/macos.arm64/$GATE_PROFILE" 2>&1)" && GATE_RC=0 || GATE_RC=$?
    np_log_line "anchorcheck, live profile $GATE_PROFILE (rc $GATE_RC):"
    if [ -n "$NP_RUN_LOG" ]; then printf '%s\n' "$out" >> "$NP_RUN_LOG"; fi
    read -r nlive lpath lbuild r u nsum <<< "$(printf '%s\n' "$out" | gate_parse)"
    if [ "$nlive" != 1 ] || [ "${lpath##*/}" != "$GATE_PROFILE" ] || [ "$lbuild" != "$GATE_BUILD" ]; then
        GATE_DETAIL="anchorcheck on $GATE_PROFILE alone did not confirm it as the live client (live blocks: $nlive, exit $GATE_RC)"
        return 1
    fi
    case "$r$u" in *[!0-9]*|'') GATE_DETAIL="no summary for the live profile $GATE_PROFILE (exit $GATE_RC)"; return 1 ;; esac
    GATE_RESOLVED="$r" GATE_UNRESOLVED="$u"
    GATE_DETAIL="live client build $GATE_BUILD: $GATE_RESOLVED/$GATE_REQUIRED anchors resolved, $GATE_UNRESOLVED unresolved, anchorcheck exit $GATE_RC"
    [ "$GATE_RC" = 0 ] || return 1
    [ "$GATE_UNRESOLVED" = 0 ] || return 1
    [ "$GATE_RESOLVED" = "$GATE_REQUIRED" ] || return 1
    return 0
}

gate_client_hashes() {
    GATE_SC_SHA="" GATE_UI_SHA=""
    [ -f "$NP_INNER_MACOS/steamclient.dylib" ] && GATE_SC_SHA="$(np_sha256 "$NP_INNER_MACOS/steamclient.dylib")"
    [ -f "$NP_INNER_MACOS/steamui.dylib" ] && GATE_UI_SHA="$(np_sha256 "$NP_INNER_MACOS/steamui.dylib")"
    return 0
}

gate_record() { # pass|fail
    state_update '.client = (.client // {}) + {steamclient_sha256: $sc, steamui_sha256: $ui,
            binary_build: (if $b == "" then null else ($b|tonumber) end),
            gate: {profile: $p, resolved: ($r|tonumber), required: ($n|tonumber), result: $res,
                   anchorcheck_sha256: $ac, at: $__now}}' \
        --arg sc "$GATE_SC_SHA" --arg ui "$GATE_UI_SHA" --arg b "$GATE_BUILD" --arg p "$GATE_PROFILE" \
        --arg r "${GATE_RESOLVED:-0}" --arg n "${GATE_REQUIRED:-0}" --arg res "$1" --arg ac "$GATE_AC_SHA"
}

# --- notproton.log check -----------------------------------------------------------------------
# Lines written by notproton/dylib/core/loader.c:
#   install_thread: signatures S/S resolved                    (steamclient)
#   install_thread: ready, H/H hooks installed
#   install_thread: steamui.dylib signatures U/U resolved
#   install_thread: steamui.dylib ready, K/K hooks installed
# verify_scan <log> <offset> <steamclient required> <steamui required>
# -> VERIFY_RESULT pass|fail|pending, VERIFY_DETAIL
verify_scan() {
    local log="$1" off="$2" scn="$3" uin="$4" size chunk sc hk us uh
    VERIFY_RESULT=pending VERIFY_DETAIL="no complete session in the log yet"
    [ -f "$log" ] || return 0
    size="$(stat -f %z "$log" 2>/dev/null || echo 0)"
    [ "$size" -lt "$off" ] && off=0   # the dylib rotated (truncated) the log
    chunk="$(tail -c +"$((off + 1))" "$log" 2>/dev/null || true)"
    sc="$(printf '%s\n' "$chunk" | sed -nE 's/.*install_thread: signatures ([0-9]+)\/([0-9]+) resolved.*/\1 \2/p' | tail -1)"
    hk="$(printf '%s\n' "$chunk" | sed -nE 's/.*install_thread: ready, ([0-9]+)\/([0-9]+) hooks installed.*/\1 \2/p' | tail -1)"
    us="$(printf '%s\n' "$chunk" | sed -nE 's/.*install_thread: steamui\.dylib signatures ([0-9]+)\/([0-9]+) resolved.*/\1 \2/p' | tail -1)"
    uh="$(printf '%s\n' "$chunk" | sed -nE 's/.*install_thread: steamui\.dylib ready, ([0-9]+)\/([0-9]+) hooks installed.*/\1 \2/p' | tail -1)"
    if printf '%s\n' "$chunk" | grep -q 'install_thread: .*installing nothing'; then
        VERIFY_RESULT=fail VERIFY_DETAIL="the dylib installed nothing: signatures $(verify_frac "$sc")"
        return 0
    fi
    if printf '%s\n' "$chunk" | grep -q 'install_thread: steamui\.dylib absent after'; then
        VERIFY_RESULT=fail VERIFY_DETAIL="steamui.dylib never loaded, its hooks stayed off"
        return 0
    fi
    [ -n "$sc" ] && [ -n "$hk" ] && [ -n "$uh" ] || return 0
    VERIFY_DETAIL="signatures $(verify_frac "$sc") (need $scn), hooks $(verify_frac "$hk"), steamui signatures $(verify_frac "$us") (need $uin), steamui hooks $(verify_frac "$uh")"
    VERIFY_RESULT=fail
    verify_full "$sc" "$scn" || return 0
    verify_full "$hk" "" || return 0
    verify_full "$us" "$uin" || return 0
    verify_full "$uh" "" || return 0
    VERIFY_RESULT=pass
}

verify_frac() { if [ -n "$1" ]; then printf '%s/%s' "${1%% *}" "${1#* }"; else printf '?'; fi; }
# verify_full "<got> <total>" [required total]: got == total > 0 (and total == required if given)
verify_full() {
    local got="${1%% *}" tot="${1#* }"
    [ -n "$1" ] && [ "$got" = "$tot" ] && [ "$tot" -gt 0 ] || return 1
    [ -z "$2" ] || [ "$tot" = "$2" ]
}

# verify_wait <log> <offset> <sc required> <ui required> <timeout s>
verify_wait() {
    local waited=0
    while :; do
        verify_scan "$1" "$2" "$3" "$4"
        [ "$VERIFY_RESULT" = pending ] || return 0
        [ "$(awk -v w="$waited" -v t="$5" 'BEGIN{print (w>=t)?1:0}')" = 1 ] && return 0
        sleep "$NP_POLL_INTERVAL"
        waited="$(awk -v w="$waited" -v i="$NP_POLL_INTERVAL" 'BEGIN{print w+i}')"
    done
}
