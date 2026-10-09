# shellcheck shell=sh
# autofix/verbs.sh: pinned verb installer for notproton prefixes (sourced, POSIX sh).
#
#   np_verb NAME            install NAME into $WINEPREFIX unless its files are already there
#   np_verb_installed NAME  0 when the verb's payload is present (aliases resolved)
#   np_verb_list            the verb names in verbs.json
#
# The table is autofix/verbs.json, read with plutil (on every macOS, unlike python3).
# Rules:
#   - every download is pinned by SHA-256; a file with sha256 null or "unverified": true is
#     never fetched and the verb refuses to run (status 3)
#   - curl writes <cache>.part, the size and SHA-256 are checked, then it is moved into place
#   - "installed" checks look at the payload (DLLs, Program Files), never at registry run keys
#     alone, so a Steam installscript that "ran" but failed still counts as missing
#   - a verb that already ran in this prefix (marker in $WINEPREFIX/notproton-verbs/) but whose
#     files are still missing is not retried on every launch; NP_VERB_FORCE=1 retries
#   - verbs marked experimental (.NET) only run with NOTPROTON_VERBS_EXPERIMENTAL=1
# Status: 0 installed, 1 failed, 2 unknown verb or no prefix, 3 not pinned, 4 experimental.
#
# Uses $WINEPREFIX, $WINELOADER, $WINESERVER (optional), $log, $NP_EXE_DIR (exe_dir targets).
# Needs helpers.sh (af_note, set_reg). Settings: NP_VERBS_JSON, NOTPROTON_CACHE, NP_VERB_FORCE,
# NOTPROTON_VERBS_EXPERIMENTAL, NP_CURL_PROTO (default =https; the tests use file URLs),
# NP_VERB_TIMEOUT (seconds per installer run, default 1200; a verb's "timeout" wins).

NP_VERBS_JSON=${NP_VERBS_JSON:-"${AUTOFIX_DIR:-$HOME/Library/Application Support/notproton/autofix}/verbs.json"}
NOTPROTON_CACHE=${NOTPROTON_CACHE:-"$HOME/Library/Application Support/notproton/cache"}

_np_j() { plutil -extract "$1" raw -o - "$NP_VERBS_JSON" 2>/dev/null; }

_np_count() {
  _np_c=$(_np_j "$1") || _np_c=0
  case "$_np_c" in ''|*[!0-9]*) _np_c=0 ;; esac
  echo "$_np_c"
}

np_verb_list() { _np_j verbs; }

_np_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  else
    openssl dgst -sha256 -r "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

_np_is_wine_builtin() {
  head -c 512 "$1" 2>/dev/null | LC_ALL=C grep -a -q -e 'Wine builtin DLL' -e 'Wine placeholder DLL'
}

_np_resolve_alias() {
  _np_ra=$1
  _np_ra_n=0
  while _np_ra_next=$(_np_j "verbs.$_np_ra.alias") && [ "$_np_ra_n" -lt 4 ]; do
    _np_ra=$_np_ra_next
    _np_ra_n=$((_np_ra_n + 1))
  done
  echo "$_np_ra"
}

# one check object at keypath $1
_np_check() (
  k=$1
  n=$(_np_count "$k.any")
  if [ "$n" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$n" ]; do
      _np_check "$k.any.$i" && exit 0
      i=$((i + 1))
    done
    exit 1
  fi
  if f=$(_np_j "$k.file"); then
    [ -f "$WINEPREFIX/$f" ] || exit 1
    if [ "$(_np_j "$k.native")" = true ] && _np_is_wine_builtin "$WINEPREFIX/$f"; then exit 1; fi
    exit 0
  fi
  if c=$(_np_j "$k.cache"); then
    [ -f "$NOTPROTON_CACHE/$c" ]
    exit
  fi
  if r=$(_np_j "$k.find"); then
    name=$(_np_j "$k.name") || exit 1
    depth=$(_np_j "$k.maxdepth") || depth=4
    [ -d "$WINEPREFIX/$r" ] || exit 1
    if ip=$(_np_j "$k.ipath"); then
      find "$WINEPREFIX/$r" -maxdepth "$depth" -type f -iname "$name" -ipath "$ip" 2>/dev/null | grep -q .
    else
      find "$WINEPREFIX/$r" -maxdepth "$depth" -type f -iname "$name" 2>/dev/null | grep -q .
    fi
    exit
  fi
  exit 1
)

# all "installed" checks of verb $1 (no alias resolution); a verb without checks is never installed
_np_installed() (
  n=$(_np_count "verbs.$1.installed")
  [ "$n" -gt 0 ] || exit 1
  i=0
  while [ "$i" -lt "$n" ]; do
    _np_check "verbs.$1.installed.$i" || exit 1
    i=$((i + 1))
  done
  exit 0
)

np_verb_installed() {
  _np_installed "$(_np_resolve_alias "$1")"
}

# download file $2 of verb $1, print the cached path
_np_fetch() (
  v=$1
  k="verbs.$v.files.$2"
  url=$(_np_j "$k.url") || exit 1
  sha=$(_np_j "$k.sha256") || sha=""
  size=$(_np_j "$k.size") || size=""
  cache=$(_np_j "$k.cache") || cache=$(basename "$url")
  dest="$NOTPROTON_CACHE/$cache"
  if [ -f "$dest" ] && [ "$(_np_sha256 "$dest")" = "$sha" ]; then
    echo "$dest"
    exit 0
  fi
  mkdir -p "$(dirname "$dest")" || exit 1
  rm -f "$dest.part"
  af_note "verb $v" "downloading $url"
  proto=${NP_CURL_PROTO:-=https}
  if ! curl -fsSL --proto "$proto" --proto-redir "$proto" --retry 2 --connect-timeout 20 \
      -o "$dest.part" "$url" 2>> "${log:-/dev/null}"; then
    rm -f "$dest.part"
    af_note "verb $v" "download failed: $url"
    exit 1
  fi
  got_size=$(stat -f %z "$dest.part" 2>/dev/null || echo 0)
  if [ -n "$size" ] && [ "$got_size" != "$size" ]; then
    rm -f "$dest.part"
    af_note "verb $v" "size mismatch for $url: got $got_size, want $size"
    exit 1
  fi
  got=$(_np_sha256 "$dest.part")
  if [ "$got" != "$sha" ]; then
    rm -f "$dest.part"
    af_note "verb $v" "sha256 mismatch for $url: got $got, want $sha"
    exit 1
  fi
  mv -f "$dest.part" "$dest" || exit 1
  echo "$dest"
)

# unpack archive $1 into new dir $2: libarchive (zip, cab, self-extracting cab), unzip, then Wine
_np_unarc() {
  mkdir -p "$2" || return 1
  if bsdtar -xf "$1" -C "$2" 2>/dev/null && find "$2" -mindepth 1 -type f | grep -q .; then
    return 0
  fi
  case "$1" in
    *.zip|*.ZIP) unzip -qo "$1" -d "$2" >/dev/null 2>&1 && return 0 ;;
  esac
  if [ -n "${WINELOADER:-}" ] && [ -x "$WINELOADER" ]; then
    _np_ua_dst="Z:$(printf '%s' "$2" | tr / '\\')"
    case "$1" in
      *.exe|*.EXE) (cd "$(dirname "$1")" && "$WINELOADER" "$(basename "$1")" /Q "/T:$_np_ua_dst") >> "${log:-/dev/null}" 2>&1 ;;
      *) (cd "$(dirname "$1")" && "$WINELOADER" expand.exe "$(basename "$1")" "-F:*" "$_np_ua_dst") >> "${log:-/dev/null}" 2>&1 ;;
    esac
    find "$2" -mindepth 1 -type f | grep -q . && return 0
  fi
  return 1
}

_np_dest_dir() {
  case "$1" in
    system32) echo "$WINEPREFIX/drive_c/windows/system32" ;;
    syswow64) echo "$WINEPREFIX/drive_c/windows/syswow64" ;;
    exe_dir) [ -n "${NP_EXE_DIR:-}" ] && [ -d "$NP_EXE_DIR" ] && echo "$NP_EXE_DIR" ;;
    *) return 1 ;;
  esac
}

_np_ok_status() {
  # Windows exit codes reach us modulo 256: 1638 (newer version installed) -> 102,
  # 3010 (reboot required) -> 194
  case "$1" in 0|102|194) return 0 ;; esac
  return 1
}

# read value $3 of key $2 from a Wine registry file $1 (user.reg/system.reg), raw right-hand side
_np_regfile_get() {
  [ -f "$1" ] || return 1
  AF_K=$2 AF_V=$3 awk '
    BEGIN {
      k = tolower(ENVIRON["AF_K"]); gsub(/\\/, "\\\\", k)
      want = "[" k "]"; v = "\"" tolower(ENVIRON["AF_V"]) "\"="
    }
    /^\[/ { sub(/\r$/, ""); hdr = tolower($0); sub(/\][^]]*$/, "]", hdr); insec = (hdr == want); next }
    insec && index(tolower($0), v) == 1 { sub(/\r$/, ""); print substr($0, length(v) + 1); found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# 0 when key $2 has a section in the Wine registry file $1
_np_regfile_has_key() {
  [ -f "$1" ] || return 1
  AF_K=$2 awk '
    BEGIN { k = tolower(ENVIRON["AF_K"]); gsub(/\\/, "\\\\", k); want = "[" k "]" }
    /^\[/ { sub(/\r$/, ""); hdr = tolower($0); sub(/\][^]]*$/, "]", hdr); if (hdr == want) { found = 1; exit } }
    END { exit found ? 0 : 1 }
  ' "$1"
}

_np_run_step() {
  _np_st_k="verbs.$_np_v.steps.$1"
  _np_st_t=$(_np_j "$_np_st_k.type") || return 1
  case "$_np_st_t" in
    exe_silent|msi_qn)
      _np_st_i=$(_np_j "$_np_st_k.file") || return 1
      _np_st_f=""
      eval "_np_st_f=\$_np_file_$_np_st_i"
      [ -f "$_np_st_f" ] || return 1
      (
        cd "$(dirname "$_np_st_f")" || exit 1
        n=$(_np_count "$_np_st_k.env")
        i=0
        while [ "$i" -lt "$n" ]; do
          e=$(_np_j "$_np_st_k.env.$i")
          case "${e%%=*}" in ''|[0-9]*|*[!A-Za-z0-9_]*) ;; *) export "${e%%=*}=${e#*=}" ;; esac
          i=$((i + 1))
        done
        if [ "$_np_st_t" = msi_qn ]; then
          set -- msiexec /i "$(basename "$_np_st_f")" /qn
        else
          set -- "$(basename "$_np_st_f")"
        fi
        n=$(_np_count "$_np_st_k.args")
        i=0
        while [ "$i" -lt "$n" ]; do
          set -- "$@" "$(_np_j "$_np_st_k.args.$i")"
          i=$((i + 1))
        done
        af_note "verb $_np_v" "running $*"
        # an installer waiting on a hidden dialog must not hold the game launch forever
        limit=$(_np_j "verbs.$_np_v.timeout") || limit=${NP_VERB_TIMEOUT:-1200}
        "$WINELOADER" "$@" >> "${log:-/dev/null}" 2>&1 &
        pid=$!
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
          if [ "$waited" -ge "$limit" ]; then
            af_note "verb $_np_v" "$1 timed out after ${limit}s, stopping it"
            kill "$pid" 2>/dev/null
            [ -n "${WINESERVER:-}" ] && [ -x "$WINESERVER" ] && "$WINESERVER" -k >> "${log:-/dev/null}" 2>&1
            break
          fi
          sleep 1
          waited=$((waited + 1))
        done
        rc=0
        { wait "$pid"; } 2>/dev/null || rc=$?
        [ "$waited" -ge "$limit" ] && exit 1
        if _np_ok_status "$rc"; then exit 0; fi
        af_note "verb $_np_v" "$1 exited with $rc"
        exit 1
      )
      ;;
    extract_dll_to)
      _np_st_i=$(_np_j "$_np_st_k.file") || return 1
      _np_st_f=""
      eval "_np_st_f=\$_np_file_$_np_st_i"
      _np_st_member=$(_np_j "$_np_st_k.member") || return 1
      _np_st_rename=$(_np_j "$_np_st_k.rename") || _np_st_rename=""
      _np_st_dest=$(_np_dest_dir "$(_np_j "$_np_st_k.dest")") || return 1
      mkdir -p "$_np_st_dest" || return 1
      _np_st_a="$_np_tmp/x$_np_st_i"
      if [ ! -d "$_np_st_a" ]; then
        _np_unarc "$_np_st_f" "$_np_st_a" || { af_note "verb $_np_v" "cannot unpack $_np_st_f"; return 1; }
      fi
      _np_st_src=$_np_st_a
      if _np_st_outer=$(_np_j "$_np_st_k.outer"); then
        _np_st_src="$_np_tmp/s$1"
        find "$_np_st_a" -type f -iname "$_np_st_outer" > "$_np_tmp/outer.lst"
        [ -s "$_np_tmp/outer.lst" ] || { af_note "verb $_np_v" "no $_np_st_outer in $(basename "$_np_st_f")"; return 1; }
        while IFS= read -r _np_st_cab; do
          _np_unarc "$_np_st_cab" "$_np_st_src/$(basename "$_np_st_cab")" || { af_note "verb $_np_v" "cannot unpack $_np_st_cab"; return 1; }
        done < "$_np_tmp/outer.lst"
      fi
      find "$_np_st_src" -type f -iname "$_np_st_member" > "$_np_tmp/member.lst"
      [ -s "$_np_tmp/member.lst" ] || { af_note "verb $_np_v" "no $_np_st_member found"; return 1; }
      while IFS= read -r _np_st_m; do
        _np_st_name=${_np_st_rename:-$(basename "$_np_st_m" | tr '[:upper:]' '[:lower:]')}
        cp -f "$_np_st_m" "$_np_st_dest/$_np_st_name" || return 1
        af_note "verb $_np_v" "installed $_np_st_name into $(basename "$_np_st_dest")"
      done < "$_np_tmp/member.lst"
      ;;
    zip_extract)
      _np_st_i=$(_np_j "$_np_st_k.file") || return 1
      _np_st_f=""
      eval "_np_st_f=\$_np_file_$_np_st_i"
      _np_st_dest="$NOTPROTON_CACHE/$(_np_j "$_np_st_k.dest")" || return 1
      _np_st_a="$_np_tmp/x$_np_st_i"
      if [ ! -d "$_np_st_a" ]; then
        _np_unarc "$_np_st_f" "$_np_st_a" || { af_note "verb $_np_v" "cannot unpack $_np_st_f"; return 1; }
      fi
      _np_st_n=$(_np_count "$_np_st_k.map")
      _np_st_j=0
      while [ "$_np_st_j" -lt "$_np_st_n" ]; do
        _np_st_member=$(_np_j "$_np_st_k.map.$_np_st_j.member") || return 1
        _np_st_to=$(_np_j "$_np_st_k.map.$_np_st_j.to") || return 1
        _np_st_m=$(find "$_np_st_a" -type f -ipath "$_np_st_member" | head -1)
        [ -n "$_np_st_m" ] || { af_note "verb $_np_v" "no $_np_st_member in archive"; return 1; }
        if _np_st_sha=$(_np_j "$_np_st_k.map.$_np_st_j.sha256"); then
          [ "$(_np_sha256 "$_np_st_m")" = "$_np_st_sha" ] || { af_note "verb $_np_v" "sha256 mismatch for $_np_st_to"; return 1; }
        fi
        mkdir -p "$(dirname "$_np_st_dest/$_np_st_to")" || return 1
        cp -f "$_np_st_m" "$_np_st_dest/$_np_st_to.part" && mv -f "$_np_st_dest/$_np_st_to.part" "$_np_st_dest/$_np_st_to" || return 1
        af_note "verb $_np_v" "cached $_np_st_to"
        _np_st_j=$((_np_st_j + 1))
      done
      ;;
    dll_override)
      _np_st_mode=$(_np_j "$_np_st_k.mode") || _np_st_mode=""
      _np_st_reg="$_np_tmp/overrides.reg"
      printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n' > "$_np_st_reg"
      _np_st_n=$(_np_count "$_np_st_k.dlls")
      _np_st_j=0
      while [ "$_np_st_j" -lt "$_np_st_n" ]; do
        printf '"%s"="%s"\r\n' "$(_np_j "$_np_st_k.dlls.$_np_st_j")" "$_np_st_mode" >> "$_np_st_reg"
        _np_st_j=$((_np_st_j + 1))
      done
      (cd "$_np_tmp" && "$WINELOADER" regedit /S overrides.reg) >> "${log:-/dev/null}" 2>&1 || return 1
      af_note "verb $_np_v" "set $_np_st_n DLL overrides to '$_np_st_mode'"
      ;;
    reg)
      set_reg "$(_np_j "$_np_st_k.key")" "$(_np_j "$_np_st_k.name")" "$(_np_j "$_np_st_k.regtype")" "$(_np_j "$_np_st_k.data")"
      ;;
    regsvr32)
      _np_st_d=$(_np_j "$_np_st_k.dir") || return 1
      _np_st_dest=$(_np_dest_dir "$_np_st_d") || return 1
      _np_st_g=$(_np_j "$_np_st_k.glob") || return 1
      (
        cd "$_np_st_dest" || exit 1
        for f in $_np_st_g; do
          [ -f "$f" ] || continue
          "$WINELOADER" "C:\\windows\\$_np_st_d\\regsvr32.exe" /s "$f" >> "${log:-/dev/null}" 2>&1 || true
        done
      )
      ;;
    winver)
      _np_st_ver=$(_np_j "$_np_st_k.version") || return 1
      if [ "$(_np_j "$_np_st_k.restore")" = true ]; then
        _np_prev_winver=$(_np_regfile_get "$WINEPREFIX/user.reg" 'Software\Wine' Version) || _np_prev_winver=""
        _np_winver_saved=1
      fi
      set_reg 'HKCU\Software\Wine' Version REG_SZ "$_np_st_ver"
      ;;
    winver_restore)
      [ "${_np_winver_saved:-0}" = 1 ] || return 0
      _np_prev_winver=$(printf '%s' "$_np_prev_winver" | tr -d '"')
      if [ -n "$_np_prev_winver" ]; then
        set_reg 'HKCU\Software\Wine' Version REG_SZ "$_np_prev_winver"
      else
        "$WINELOADER" reg delete 'HKCU\Software\Wine' /v Version /f >> "${log:-/dev/null}" 2>&1 || true
      fi
      ;;
    remove_mono)
      for _np_st_desc in 'Wine Mono Windows Support' 'Wine Mono Runtime' 'Wine Mono'; do
        _np_st_uuid=$("$WINELOADER" uninstaller --list 2>/dev/null | grep "$_np_st_desc" | head -1 | cut -f1 -d'|')
        if [ -n "$_np_st_uuid" ]; then
          "$WINELOADER" uninstaller --remove "$_np_st_uuid" >> "${log:-/dev/null}" 2>&1 || true
          af_note "verb $_np_v" "removed $_np_st_desc"
        fi
      done
      ;;
    touch)
      _np_st_p=$(_np_j "$_np_st_k.path") || return 1
      mkdir -p "$(dirname "$WINEPREFIX/$_np_st_p")" && : > "$WINEPREFIX/$_np_st_p"
      ;;
    *)
      af_note "verb $_np_v" "unknown step type $_np_st_t"
      return 1
      ;;
  esac
}

np_verb() (
  _np_v=$(_np_resolve_alias "$1")
  [ "$_np_v" = "$1" ] || af_note "verb $1" "served by $_np_v"
  if ! _np_j "verbs.$_np_v.title" >/dev/null; then
    af_note "verb $1" "unknown verb"
    exit 2
  fi
  _np_needs_prefix=1
  [ "$(_np_j "verbs.$_np_v.prefix")" = false ] && _np_needs_prefix=0
  if [ "$_np_needs_prefix" = 1 ]; then
    if [ -z "${WINEPREFIX:-}" ] || [ ! -d "$WINEPREFIX/drive_c" ] || [ ! -x "${WINELOADER:-}" ]; then
      af_note "verb $_np_v" "no prefix or Wine loader, skipped"
      exit 2
    fi
    _np_marker="$WINEPREFIX/notproton-verbs/$_np_v"
  else
    _np_marker="$NOTPROTON_CACHE/.verbs/$_np_v"
  fi
  if [ "${NP_VERB_FORCE:-0}" != 1 ] && _np_installed "$_np_v"; then
    af_note "verb $_np_v" "already installed"
    exit 0
  fi
  if [ "${NP_VERB_FORCE:-0}" != 1 ] && [ -f "$_np_marker" ]; then
    af_note "verb $_np_v" "ran before ($(head -1 "$_np_marker")) but its files are missing; not retrying (NP_VERB_FORCE=1 retries)"
    exit 1
  fi
  if [ "$(_np_j "verbs.$_np_v.experimental")" = true ] && [ "${NOTPROTON_VERBS_EXPERIMENTAL:-0}" != 1 ]; then
    af_note "verb $_np_v" "experimental, skipped (NOTPROTON_VERBS_EXPERIMENTAL=1 enables it)"
    exit 4
  fi

  _np_n=$(_np_count "verbs.$_np_v.requires")
  _np_i=0
  while [ "$_np_i" -lt "$_np_n" ]; do
    _np_req=$(_np_j "verbs.$_np_v.requires.$_np_i")
    np_verb "$_np_req" || { af_note "verb $_np_v" "requirement $_np_req failed"; exit 1; }
    _np_i=$((_np_i + 1))
  done

  # refuse before downloading anything when one file is not pinned
  _np_n=$(_np_count "verbs.$_np_v.files")
  _np_i=0
  while [ "$_np_i" -lt "$_np_n" ]; do
    _np_sha=$(_np_j "verbs.$_np_v.files.$_np_i.sha256") || _np_sha=""
    _np_unv=$(_np_j "verbs.$_np_v.files.$_np_i.unverified") || _np_unv=false
    if [ "$_np_unv" = true ] || [ "${#_np_sha}" != 64 ] || [ -n "$(printf '%s' "$_np_sha" | tr -d '0-9a-f')" ]; then
      af_note "verb $_np_v" "refusing to run: $(_np_j "verbs.$_np_v.files.$_np_i.url") has no pinned sha256"
      exit 3
    fi
    _np_i=$((_np_i + 1))
  done

  _np_tmp=$(mktemp -d "${TMPDIR:-/tmp}/npverb.XXXXXX") || exit 1
  trap 'rm -rf "$_np_tmp"' EXIT
  _np_i=0
  while [ "$_np_i" -lt "$_np_n" ]; do
    _np_p=$(_np_fetch "$_np_v" "$_np_i") || exit 1
    eval "_np_file_$_np_i=\$_np_p"
    _np_i=$((_np_i + 1))
  done

  _np_n=$(_np_count "verbs.$_np_v.steps")
  _np_i=0
  while [ "$_np_i" -lt "$_np_n" ]; do
    if ! _np_run_step "$_np_i"; then
      af_note "verb $_np_v" "step $_np_i ($(_np_j "verbs.$_np_v.steps.$_np_i.type")) failed"
      exit 1
    fi
    _np_i=$((_np_i + 1))
  done
  if [ "$_np_needs_prefix" = 1 ] && [ -n "${WINESERVER:-}" ] && [ -x "$WINESERVER" ]; then
    "$WINESERVER" -w >> "${log:-/dev/null}" 2>&1 || true
  fi
  mkdir -p "$(dirname "$_np_marker")" && date '+%Y-%m-%d %H:%M:%S' > "$_np_marker"
  if _np_installed "$_np_v"; then
    af_note "verb $_np_v" "installed"
    exit 0
  fi
  af_note "verb $_np_v" "installer finished but the expected files are missing"
  exit 1
)
