# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by install.sh and the other libs
# Runner install (dist copy or lock-pinned release archive), D3DMetal, file manifests, and the
# Steam bridge. Nothing here touches Steam.app.

# --- ci/runner-a.lock ----------------------------------------------------------------------------
# KEY=VALUE lines (version, url, sha256); read with sed, never sourced.
# Runner ids and versions become directory names under runners/.
runner_valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

runner_lock_read() { # lockfile -> LOCK_VERSION LOCK_URL LOCK_SHA
    local f="$1"
    [ -f "$f" ] || { warn "no runner lock at $f"; return 1; }
    LOCK_VERSION="$(sed -n 's/^version=//p' "$f" | tail -1 | tr -d '[:space:]')"
    LOCK_URL="$(sed -n 's/^url=//p' "$f" | tail -1 | tr -d '[:space:]')"
    LOCK_SHA="$(sed -n 's/^sha256=//p' "$f" | tail -1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ -z "$LOCK_SHA" ]; then
        warn "$f has no sha256 yet (it is filled in after the first CI release); use --from dist"
        return 1
    fi
    case "$LOCK_SHA" in *[!0-9a-f]*) warn "sha256 in $f is not hex"; return 1 ;; esac
    [ "${#LOCK_SHA}" = 64 ] || { warn "sha256 in $f is not 64 hex digits"; return 1; }
    runner_valid_id "$LOCK_VERSION" || { warn "version in $f must be letters, digits, '.', '_', '-'"; return 1; }
    case "$LOCK_URL" in
        https://*) ;;
        file://*) np_test_mode || { warn "file:// URLs are for tests only"; return 1; } ;;
        *) warn "url in $f must be https://"; return 1 ;;
    esac
    return 0
}

runner_need_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    warn "zstd is required to unpack the runner archive (/usr/bin/tar cannot read zstd): brew install zstd"
    return 1
}

# Downloads to <dst>.part, checks the SHA-256 and only then names it <dst>. A cached file with
# the right hash is reused.
runner_fetch() { # url sha dst
    local url="$1" sha="$2" dst="$3"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
        [ "$(np_sha256 "$dst")" = "$sha" ] && return 0
        warn "cached $dst has the wrong hash; deleting it"
        rm -f "$dst"
    fi
    rm -f "$dst.part"
    if np_test_mode; then
        np_quiet curl -fsSL --proto '=https,file' -o "$dst.part" "$url" || { rm -f "$dst.part"; warn "download failed: $url"; return 1; }
    else
        np_quiet curl -fsSL --proto '=https' --proto-redir '=https' -o "$dst.part" "$url" || { rm -f "$dst.part"; warn "download failed: $url"; return 1; }
    fi
    if [ "$(np_sha256 "$dst.part")" != "$sha" ]; then
        rm -f "$dst.part"
        warn "SHA-256 mismatch for $url (expected $sha from the lock)"
        return 1
    fi
    mv -f "$dst.part" "$dst"
}

# 0 if a symlink at <relpath> (relative to the extraction root) pointing at <target> leaves the
# root, or is absolute.
runner_link_escapes() { # relpath target
    local rel="$1" target="$2" dir depth=0 comp
    case "$target" in /*|'') return 0 ;; esac
    dir="${rel%/*}"
    [ "$dir" = "$rel" ] && dir=""
    set -f
    local IFS=/
    for comp in $dir; do
        case "$comp" in ''|.) ;; ..) depth=$((depth - 1)) ;; *) depth=$((depth + 1)) ;; esac
    done
    for comp in $target; do
        case "$comp" in
            ''|.) ;;
            ..) depth=$((depth - 1)); [ "$depth" -lt 0 ] && { set +f; return 0; } ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
    set +f
    return 1
}

runner_bad_name() { # name -> 0 if absolute or has a .. component
    case "$1" in /*) return 0 ;; esac
    case "/$1/" in */../*) return 0 ;; esac
    return 1
}

# Checks every member of a .tar.zst before anything is extracted: one top-level directory, no
# absolute names, no .. components, only files/dirs/symlinks, no symlink leaving the tree,
# hardlink targets inside it too. Sets ARCHIVE_TOP. 1 with a warning on the first problem.
runner_validate_archive() { # archive
    local arc="$1" names n top="" count mcount line path kw t rel target
    names="$(zstd -dc "$arc" | tar -tf -)" || { warn "cannot list $arc"; return 1; }
    [ -n "$names" ] || { warn "$arc is empty"; return 1; }
    count=0
    while IFS= read -r n; do
        count=$((count + 1))
        runner_bad_name "$n" && { warn "archive member with an absolute or .. path: $n"; return 1; }
        n="${n#./}"
        [ -z "$top" ] && top="${n%%/*}"
        [ "${n%%/*}" = "$top" ] || { warn "archive has more than one top-level entry ($top, ${n%%/*})"; return 1; }
    done <<< "$names"
    case "$top" in ''|.|..) warn "archive has no top-level directory"; return 1 ;; esac
    ARCHIVE_TOP="$top"
    mcount=0
    while IFS= read -r line; do
        case "$line" in '#'*|/*|'') continue ;; esac
        mcount=$((mcount + 1))
        path="${line%% *}"
        path="${path#./}"
        t="" target=""
        set -f
        for kw in ${line#* }; do
            case "$kw" in type=*) t="${kw#type=}" ;; link=*) target="${kw#link=}" ;; esac
        done
        set +f
        case "$t" in
            file|dir) ;;
            link)
                rel="${path#"$top"}"
                rel="${rel#/}"
                [ -n "$rel" ] || { warn "the top-level entry is a symlink"; return 1; }
                runner_link_escapes "$rel" "$target" && { warn "symlink leaves the runner tree: $path -> $target"; return 1; }
                ;;
            *) warn "archive member of type '$t' refused: $path"; return 1 ;;
        esac
    done < <(zstd -dc "$arc" | tar -cf - --format=mtree --options='!all,type,link' @-)
    [ "$mcount" = "$count" ] || { warn "archive listing is inconsistent ($count names, $mcount entries)"; return 1; }
    while IFS= read -r line; do
        case "$line" in *" link to "*" link to "*) warn "ambiguous hardlink entry: $line"; return 1 ;; esac
        target="${line##* link to }"
        runner_bad_name "$target" && { warn "hardlink to an absolute or .. path: $target"; return 1; }
        target="${target#./}"
        [ "${target%%/*}" = "$top" ] || { warn "hardlink outside the runner tree: $target"; return 1; }
    done < <(zstd -dc "$arc" | tar -tvf - | grep ' link to ' || true)
    return 0
}

# After extraction or copy: only files, dirs and symlinks, and every symlink stays inside, both
# as written and resolved physically (a chain like l2 -> ., b -> l2/.. leaves the tree although
# each link looks harmless on its own). A dangling link is checked through its target's folder.
runner_check_tree() { # dir
    local d="$1" root odd p t r
    root="$(cd -P "$d" && pwd -P)" || return 1
    odd="$(find "$d" ! -type f ! -type d ! -type l | head -1)"
    [ -z "$odd" ] || { warn "unexpected file type in the runner: $odd"; return 1; }
    while IFS= read -r -d '' p; do
        t="$(readlink "$p")"
        runner_link_escapes "${p#"$d"/}" "$t" && { warn "symlink leaves the runner tree: $p -> $t"; return 1; }
        if ! r="$(/bin/realpath "$p" 2>/dev/null)"; then
            r="$(/bin/realpath "$(dirname "$p")/$(dirname "$t")" 2>/dev/null)" \
                || { warn "symlink cannot be resolved: $p -> $t"; return 1; }
        fi
        case "$r/" in "$root"/*) ;; *) warn "symlink resolves outside the runner tree: $p -> $t ($r)"; return 1 ;; esac
    done < <(find "$d" -type l -print0)
    return 0
}

# Manifest: shasum -a 256 lines for every regular file, paths relative to the runner ("./...").
runner_manifest_write() { # dir out
    ( set -o pipefail; cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) > "$2.tmp" || { rm -f "$2.tmp"; return 1; }
    mv -f "$2.tmp" "$2"
}
runner_manifest_verify() { # dir manifest
    [ -f "$2" ] || return 1
    ( cd "$1" && shasum -a 256 -c --quiet "$2" ) >/dev/null 2>&1
}

# Same list as install-d3dmetal.sh writes, for a runner whose D3DMetal came with the source.
d3dmetal_manifest_write() { # runner
    local r="$1" out="$1/lib/external/D3DMetal.files.sha256"
    (
        set -o pipefail
        cd "$r" || exit 1
        {
            find ./lib/external/D3DMetal.framework ./lib/renderers/d3dmetal -type f -print0
            printf '%s\0' ./lib/external/libd3dshared.dylib
            if [ -f ./lib/external/D3DMetal-License.rtf ]; then printf '%s\0' ./lib/external/D3DMetal-License.rtf; fi
        } | LC_ALL=C sort -z | xargs -0 shasum -a 256
    ) > "$out.tmp" || { rm -f "$out.tmp"; return 1; }
    mv -f "$out.tmp" "$out"
}

# D3DMetal into a staged runner. Sets D3D_STATUS (installed|from_source|declined), D3D_VERSION,
# D3D_SOURCE, D3D_ARCHIVE_SHA, D3D_LICENSE_SHA, D3D_ACCEPTED_AT. 1 only on a real failure.
# NP_GPTK_DMG (install.sh --gptk-dmg) selects Apple's GPTK disk image as the source;
# NP_D3DMETAL_LICENSE_TOKEN / NP_D3DMETAL_LICENSE_FILE carry a GUI's licence acceptance.
d3dmetal_read_source() { # runner
    local f="$1/lib/external/D3DMetal.source"
    D3D_SOURCE="" D3D_VERSION="" D3D_ARCHIVE_SHA="" D3D_LICENSE_SHA=""
    [ -f "$f" ] || return 0
    D3D_SOURCE="$(sed -n 's/^source=//p' "$f" | head -1)"
    D3D_VERSION="$(sed -n 's/^version=//p' "$f" | head -1)"
    D3D_ARCHIVE_SHA="$(sed -n 's/^archive_sha256=//p' "$f" | head -1)"
    D3D_LICENSE_SHA="$(sed -n 's/^license_sha256=//p' "$f" | head -1)"
    [ "$D3D_LICENSE_SHA" = none ] && D3D_LICENSE_SHA=""
    return 0
}

# A licence prompt nobody answered must not take away D3DMetal the user already accepted: when
# the installed runner of the same id has D3DMetal with a licence record and its file hashes still
# match, its D3DMetal files replace the staged ones (which may be the dist build's older copy).
d3dmetal_keep_installed() { # staging installed-runner
    local st="$1" r="$2" f
    [ -f "$r/lib/external/D3DMetal.source" ] && [ -d "$r/lib/external/D3DMetal.framework" ] || return 1
    [ -n "$(sed -n 's/^license_sha256=//p' "$r/lib/external/D3DMetal.source" | grep -v '^none$' | head -1)" ] || return 1
    runner_manifest_verify "$r" "$r/lib/external/D3DMetal.files.sha256" || return 1
    rm -rf "$st/lib/external/D3DMetal.framework" "$st/lib/renderers/d3dmetal" "$st/lib/external/libd3dshared.dylib" \
        "$st/lib/external/D3DMetal-License.rtf" "$st/lib/external/D3DMetal.source" "$st/lib/external/D3DMetal.files.sha256"
    mkdir -p "$st/lib/external" "$st/lib/renderers"
    ditto "$r/lib/external/D3DMetal.framework" "$st/lib/external/D3DMetal.framework" || return 1
    if [ -d "$r/lib/renderers/d3dmetal" ]; then ditto "$r/lib/renderers/d3dmetal" "$st/lib/renderers/d3dmetal" || return 1; fi
    for f in libd3dshared.dylib D3DMetal-License.rtf D3DMetal.source D3DMetal.files.sha256; do
        if [ -e "$r/lib/external/$f" ]; then cp -pR "$r/lib/external/$f" "$st/lib/external/$f" || return 1; fi
    done
    d3dmetal_read_source "$st"
    if [ -n "$D3D_VERSION" ] && [ -f "$st/runner.json" ]; then
        jq --arg v "$D3D_VERSION" '.renderers = ((.renderers // {}) + {d3dmetal: $v})' "$st/runner.json" > "$st/runner.json.tmp" \
            && mv -f "$st/runner.json.tmp" "$st/runner.json" || return 1
    fi
    runner_manifest_verify "$st" "$st/lib/external/D3DMetal.files.sha256"
}

runner_d3dmetal() { # staging
    local st="$1" rc=0 errf lic args=()
    D3D_STATUS="" D3D_ACCEPTED_AT=""
    d3dmetal_read_source "$st"
    # D3DMetal that came with the source counts only with its D3DMetal.source record (written by
    # install-d3dmetal.sh after the licence was accepted). Without one, nobody knows whether the
    # licence was accepted: install-d3dmetal.sh runs again and asks.
    if [ -d "$st/lib/external/D3DMetal.framework" ] && [ -z "${NP_GPTK_DMG:-}" ] && [ -f "$st/lib/external/D3DMetal.source" ]; then
        D3D_STATUS=from_source
        [ -f "$st/lib/external/D3DMetal.files.sha256" ] || d3dmetal_manifest_write "$st" || return 1
        [ -n "$D3D_VERSION" ] || D3D_VERSION="$(jq -r '.renderers.d3dmetal // empty' "$st/runner.json" 2>/dev/null || true)"
        if [ -z "$D3D_LICENSE_SHA" ] && [ -f "$st/lib/external/D3DMetal-License.rtf" ]; then
            D3D_LICENSE_SHA="$(np_sha256 "$st/lib/external/D3DMetal-License.rtf")"
        fi
        return 0
    fi
    [ -n "${NP_GPTK_DMG:-}" ] && args=(--gptk-dmg "$NP_GPTK_DMG")
    errf="$(mktemp "${TMPDIR:-/tmp}/np-d3d.XXXXXX")"
    # D3DMETAL_GPTK_DMG is never inherited silently: the source is what install.sh shows in the
    # plan (NP_GPTK_DMG, which defaults to D3DMETAL_GPTK_DMG), passed explicitly.
    if [ "$NP_JSON" != 1 ] && [ -t 0 ] && ! np_test_mode; then
        # Interactive: the script shows the licence and asks on the terminal itself. Its stderr
        # goes through tee into errf; the pipeline ends only after tee has written everything.
        { env -u D3DMETAL_GPTK_DMG D3DMETAL_CACHE="$NP_CACHE" D3DMETAL_LICENSE_SHA256="${NP_D3DMETAL_LICENSE_TOKEN:-}" \
            D3DMETAL_LICENSE_FILE="${NP_D3DMETAL_LICENSE_FILE:-}" \
            "$NP_D3DMETAL_SCRIPT" ${args[@]+"${args[@]}"} "$st" 2>&1 1>&3 3>&- | tee "$errf" >&2 3>&-
          rc="${PIPESTATUS[0]}"; } 3>&1
    else
        env -u D3DMETAL_GPTK_DMG D3DMETAL_CACHE="$NP_CACHE" D3DMETAL_LICENSE_SHA256="${NP_D3DMETAL_LICENSE_TOKEN:-}" \
            D3DMETAL_LICENSE_FILE="${NP_D3DMETAL_LICENSE_FILE:-}" \
            "$NP_D3DMETAL_SCRIPT" ${args[@]+"${args[@]}"} "$st" < /dev/null >> "${NP_RUN_LOG:-/dev/null}" 2> "$errf" || rc=$?
    fi
    [ -n "$NP_RUN_LOG" ] && cat "$errf" >> "$NP_RUN_LOG"
    case "$rc" in
        0)
            D3D_STATUS=installed
            D3D_ACCEPTED_AT="$(np_now)"
            d3dmetal_read_source "$st"
            [ -f "$st/lib/external/D3DMetal.files.sha256" ] || { rm -f "$errf"; warn "install-d3dmetal.sh wrote no file hashes"; return 1; }
            ;;
        2)
            D3D_STATUS=declined
            # "license-required <sha256 or -> <licence file, or Apple's URL when the source has none>"
            lic="$(sed -n 's/^license-required //p' "$errf" | head -1)"
            if [ -n "$lic" ]; then
                if [ "${lic%% *}" = - ]; then
                    np_emit "$(jq -cn --arg u "${lic#* }" '{event:"confirm",id:"d3dmetal_license",
                        text:("Apple'"'"'s Game Porting Toolkit licence is not in the GPTK 3.0 archive. Show the user Apple'"'"'s licence (it comes with the toolkit from " + $u + ") and pass its License.rtf, or use --gptk-dmg."),
                        license_path:null,url:$u,token:null,env:"NP_D3DMETAL_LICENSE_FILE"}')"
                    say "    D3DMetal: the licence is not in this archive; accept it on a terminal, pass NP_D3DMETAL_LICENSE_FILE=<Apple's License.rtf>, or use --gptk-dmg"
                else
                    np_emit "$(jq -cn --arg k "${lic%% *}" --arg p "${lic#* }" \
                        '{event:"confirm",id:"d3dmetal_license",text:("Apple Game Porting Toolkit licence: " + $p),license_path:$p,url:null,token:$k,env:"NP_D3DMETAL_LICENSE_TOKEN"}')"
                    say "    D3DMetal licence needs acceptance; a GUI re-runs with NP_D3DMETAL_LICENSE_TOKEN=${lic%% *}"
                fi
            fi
            if [ -n "${RUNNER_VER:-}" ] && d3dmetal_keep_installed "$st" "$NP_SUPPORT/runners/$RUNNER_VER"; then
                D3D_STATUS=kept
                say "    D3DMetal ${D3D_VERSION:-?} kept from the installed runner (its licence was accepted before)"
            fi
            ;;
        *) rm -f "$errf"; warn "install-d3dmetal.sh failed (exit $rc)"; return 1 ;;
    esac
    rm -f "$errf"
    return 0
}

# Installs the runner. Sets RUNNER_VER RUNNER_SOURCE RUNNER_URL RUNNER_TARBALL_SHA
# RUNNER_MANIFEST RUNNER_REUSED, plus the D3D_* values. 1 with a warning on failure.
runner_install() { # dist|release
    local from="$1" st arc rdir old
    RUNNER_URL="" RUNNER_TARBALL_SHA="" RUNNER_REUSED=0
    mkdir -p "$NP_SUPPORT/runners"
    st="$NP_SUPPORT/runners/.staging-$$"
    np_cleanup_add "$st"
    np_cleanup_add "$st.files.sha256"
    rm -rf "$st"
    case "$from" in
        dist)
            RUNNER_VER="$NP_RUNNER_ID"
            runner_valid_id "$RUNNER_VER" || { warn "runner id '$RUNNER_VER' must be letters, digits, '.', '_', '-'"; return 1; }
            RUNNER_SOURCE=dist
            [ -f "$NP_DIST_DIR/$RUNNER_VER/runner.json" ] || { warn "no runner at $NP_DIST_DIR/$RUNNER_VER (scripts/build-all.sh)"; return 1; }
            ditto "$NP_DIST_DIR/$RUNNER_VER" "$st" || { warn "copying the runner failed"; return 1; }
            ;;
        release)
            runner_need_zstd || return 1
            runner_lock_read "$NP_RUNNER_LOCK" || return 1
            RUNNER_VER="$LOCK_VERSION"
            RUNNER_SOURCE=release
            RUNNER_URL="$LOCK_URL"
            RUNNER_TARBALL_SHA="$LOCK_SHA"
            arc="$NP_CACHE/runner-a-$LOCK_VERSION.tar.zst"
            runner_fetch "$LOCK_URL" "$LOCK_SHA" "$arc" || return 1
            runner_validate_archive "$arc" || return 1
            mkdir -p "$st"
            ( set -o pipefail; zstd -dc "$arc" | tar -xf - -C "$st" --strip-components 1 ) || { warn "extracting $arc failed"; return 1; }
            # Rule 3: Apple's D3DMetal never comes from a downloaded runner, only from install-d3dmetal.sh.
            if [ -e "$st/lib/external/D3DMetal.framework" ] || [ -e "$st/lib/renderers/d3dmetal" ] \
                || [ -e "$st/lib/external/libd3dshared.dylib" ]; then
                warn "the release runner contains D3DMetal, which must never be redistributed; refusing it"
                return 1
            fi
            ;;
        *) warn "--from must be dist or release"; return 1 ;;
    esac
    xattr -dr com.apple.quarantine "$st" 2>/dev/null || true
    runner_check_tree "$st" || return 1
    [ -x "$st/bin/wine" ] || { warn "the runner has no bin/wine"; return 1; }
    grep -Eq '"kind"[[:space:]]*:[[:space:]]*"selfbuilt"' "$st/runner.json" || { warn "runner.json is not a selfbuilt runner"; return 1; }
    step_end ok "$RUNNER_SOURCE runner $RUNNER_VER staged"

    step_start d3dmetal "D3DMetal (Apple Game Porting Toolkit)"
    runner_d3dmetal "$st" || return 1
    case "$D3D_STATUS" in
        declined) step_end warn "D3DMetal not installed (licence not accepted); DX12 games fall back to other renderers" ;;
        *) step_end ok "D3DMetal $D3D_STATUS" ;;
    esac

    # D3DMetal brought new files and symlinks: the same tree rules apply to them.
    runner_check_tree "$st" || return 1

    step_start runner_install "Installing the runner"
    rdir="$NP_SUPPORT/runners/$RUNNER_VER"
    RUNNER_MANIFEST="$NP_SUPPORT/runners/$RUNNER_VER.files.sha256"
    runner_manifest_write "$st" "$st.files.sha256" || { warn "hashing the runner failed"; return 1; }
    if [ -d "$rdir" ] && [ -f "$RUNNER_MANIFEST" ] && cmp -s "$st.files.sha256" "$RUNNER_MANIFEST" \
        && runner_manifest_verify "$rdir" "$RUNNER_MANIFEST"; then
        RUNNER_REUSED=1
        rm -rf "$st" "$st.files.sha256"
        return 0
    fi
    old=""
    np_critical_begin
    if [ -e "$rdir" ]; then
        old="$NP_SUPPORT/runners/.old-$RUNNER_VER-$$"
        mv "$rdir" "$old" || { np_critical_end; warn "cannot move the old runner aside"; return 1; }
    fi
    if ! mv "$st" "$rdir"; then
        if [ -n "$old" ]; then mv "$old" "$rdir" || warn "the old runner stays at $old"; fi
        np_critical_end
        warn "cannot move the runner into place"
        return 1
    fi
    mv -f "$st.files.sha256" "$RUNNER_MANIFEST" || { np_critical_end; warn "cannot write $RUNNER_MANIFEST"; return 1; }
    np_critical_end
    if [ -n "$old" ]; then rm -rf "$old" || return 1; fi
    return 0
}

runner_record() {
    state_update '.runners[$v] = {source: $src, url: (if $u == "" then null else $u end),
            tarball_sha256: (if $t == "" then null else $t end), manifest: $m,
            manifest_sha256: $ms, installed_at: $__now,
            d3dmetal: {status: $ds, version: (if $dv == "" then null else $dv end), source: (if $dsrc == "" then null else $dsrc end), archive_sha256: (if $da == "" then null else $da end),
                       license_sha256: (if $dl == "" then null else $dl end),
                       accepted_at: (if $dt == "" then (.runners[$v].d3dmetal.accepted_at // null) else $dt end),
                       files_manifest: (if $ds == "declined" then null else ($r + "/lib/external/D3DMetal.files.sha256") end)}}' \
        --arg v "$RUNNER_VER" --arg src "$RUNNER_SOURCE" --arg u "$RUNNER_URL" --arg t "$RUNNER_TARBALL_SHA" \
        --arg m "$RUNNER_MANIFEST" --arg ms "$(np_sha256 "$RUNNER_MANIFEST")" --arg ds "$D3D_STATUS" \
        --arg da "$D3D_ARCHIVE_SHA" --arg dl "$D3D_LICENSE_SHA" --arg dv "${D3D_VERSION:-}" --arg dsrc "${D3D_SOURCE:-}" --arg dt "$D3D_ACCEPTED_AT" \
        --arg r "$NP_SUPPORT/runners/$RUNNER_VER"
}

# --- Steam bridge ------------------------------------------------------------------------------
# Valve's DLLs (fetch-valve-bridge.sh, manifest-pinned) plus the runner's steam.exe and
# lsteamclient into bridge.new; swapped in only when every Valve file matches the manifest.
bridge_install() { # runner dir
    local r="$1" new="$NP_SUPPORT/bridge.new" b="$NP_SUPPORT/bridge" kind rel pkg inner sha old
    rm -rf "$new"
    mkdir -p "$new"
    np_cleanup_add "$new"
    if np_test_mode; then
        CACHE="$NP_CACHE/valve" OUT="$new" np_quiet "${NP_TEST_FETCH_BRIDGE:?test mode needs NP_TEST_FETCH_BRIDGE}" || { warn "bridge fetch failed"; return 1; }
    else
        CACHE="$NP_CACHE/valve" OUT="$new" np_quiet "$ROOT/scripts/fetch-valve-bridge.sh" || { warn "fetching Valve's bridge files failed (see the log)"; return 1; }
    fi
    [ "$(grep -c '^file ' "$NP_VALVE_MANIFEST" 2>/dev/null || true)" -gt 0 ] \
        || { warn "$NP_VALVE_MANIFEST lists no bridge files"; return 1; }
    while read -r kind rel pkg inner sha; do
        [ "$kind" = file ] || continue
        [ -f "$new/$rel" ] && [ "$(np_sha256 "$new/$rel")" = "$sha" ] || { warn "bridge file $rel does not match the manifest ($pkg/$inner)"; return 1; }
    done < <(grep '^file ' "$NP_VALVE_MANIFEST")
    mkdir -p "$new/i386-windows" "$new/x86_64-windows" "$new/x86_64-unix"
    cp -f "$r/share/steamplay/steam.exe" "$new/steam.exe" || return 1
    cp -f "$r/lib/wine/x86_64-windows/lsteamclient.dll" "$new/lsteamclient.dll" || return 1
    cp -f "$r/lib/wine/x86_64-windows/lsteamclient.dll" "$new/x86_64-windows/lsteamclient.dll" || return 1
    cp -f "$r/lib/wine/i386-windows/lsteamclient.dll" "$new/i386-windows/lsteamclient.dll" || return 1
    cp -f "$r/lib/wine/x86_64-unix/lsteamclient.so" "$new/x86_64-unix/lsteamclient.so" || return 1
    "$NP_CODESIGN" --remove-signature "$new/x86_64-unix/lsteamclient.so" 2>/dev/null || true
    BRIDGE_REUSED=0
    if [ -d "$b" ] && [ "$(sa_tree_hash "$b")" = "$(sa_tree_hash "$new")" ]; then
        BRIDGE_REUSED=1
        rm -rf "$new"
    else
        old=""
        np_critical_begin
        if [ -e "$b" ]; then old="$NP_SUPPORT/.bridge.old-$$"; mv "$b" "$old" || { np_critical_end; return 1; }; fi
        if ! mv "$new" "$b"; then
            if [ -n "$old" ]; then mv "$old" "$b" || warn "the old bridge stays at $old"; fi
            np_critical_end
            return 1
        fi
        np_critical_end
        if [ -n "$old" ]; then rm -rf "$old" || return 1; fi
    fi
    state_update '.bridge = {files: $f, at: $__now}' --argjson f "$(np_files_json "$b")"
}

# {"<relpath>": "<sha256>", ...} for every regular file under a dir
np_files_json() {
    ( set -o pipefail; cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) \
        | jq -R -s 'split("\n") | map(select(length > 0) | capture("^(?<h>[0-9a-f]{64}) [ *](?<p>.*)$") | {key: (.p | ltrimstr("./")), value: .h}) | from_entries'
}
