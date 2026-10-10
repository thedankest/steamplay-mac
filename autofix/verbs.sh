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

# NVIDIA installer (NVI2) package: read the copyFile/addRegistry/addPath phases of the .nvi
# manifest $1 and print "C<TAB>target<TAB>source", "R<TAB>view<TAB>key<TAB>name<TAB>type<TAB>value"
# (name "@" = default value, "-" = key only; view 32 = an x86 phase) and "P<TAB>dir" lines. NVI2's
# setup.exe refuses machines its <filter platform=...> does not list (FEX reports arm64), so the
# verb does what the manifest says instead of running it. NAME=VALUE arguments after $1 define
# the ${{NAME}} variables NVI2 itself supplies (install folders, NvidiaSoftwareKey).
_np_nvi_plan() {
  _np_nv_f=$1
  shift
  LC_ALL=C awk -v FS='\001' '
    function attr(l, n,   m) {
      if (match(l, " " n "=\"[^\"]*\"")) { m = substr(l, RSTART + length(n) + 3, RLENGTH - length(n) - 4); return m }
      return "\001"
    }
    function subst(v,   n, i, out, guard) {
      for (guard = 0; (i = index(v, "${{")) > 0 && guard < 20; guard++) {
        n = substr(v, i + 3); n = substr(n, 1, index(n, "}}") - 1)
        if (!(n in vars)) { bad = bad " " n; return v }
        v = substr(v, 1, i - 1) vars[n] substr(v, i + 3 + length(n) + 2)
      }
      return v
    }
    BEGIN { for (i = 1; i < ARGC - 1; i++) { e = ARGV[i]; vars[substr(e, 1, index(e, "=") - 1)] = substr(e, index(e, "=") + 1); ARGV[i] = "" } }
    { sub(/\r$/, ""); sub(/^\357\273\277/, "") }
    incomment { if (index($0, "-->")) incomment = 0; next }
    /<!--/ { if (!index($0, "-->")) incomment = 1; next }
    /<localized/ { inloc = 1 } /<\/localized>/ { inloc = 0; next }
    /<string / && !inloc { n = attr($0, "name"); v = attr($0, "value"); if (n != "\001" && v != "\001" && !(n in vars)) vars[n] = v; next }
    /<standard / { view = (attr($0, "platform") == "x86") ? 32 : 64; next }
    /<\/standard>/ { view = 0; next }
    /<copyFile / && view { lines[++nl] = "C\t" attr($0, "target") "\t" attr($0, "source"); next }
    /<addRegistry / && view {
      n = attr($0, "valueName"); t = attr($0, "type"); v = attr($0, "value")
      if (n == "\001") { n = "-"; t = "-"; v = "" } else if (n == "") n = "@"
      if (t == "REG_MULTI_SZ") { sp = attr($0, "split"); if (sp != "\001") gsub(sp == "|" ? "\\|" : sp, "\001", v) }
      lines[++nl] = "R\t" view "\t" attr($0, "keyName") "\t" n "\t" t "\t" v; next
    }
    /<addPath / && view { lines[++nl] = "P\t" attr($0, "target"); next }
    END {
      for (i = 1; i <= nl; i++) { l = subst(lines[i]); if (l ~ /\001\t|\t\001$/) bad = bad " attribute"; print l }
      if (bad != "") { print "unresolved:" bad > "/dev/stderr"; exit 1 }
    }
  ' "$@" "$_np_nv_f"
}

# .reg text for the R and P lines of a _np_nvi_plan on stdin; $1 = the prefix's current PATH.
# REGEDIT4, so hex(2)/hex(7) data is single-byte text: Wine's regedit reads an ASCII file with the
# 5.00 header the same way and would widen UTF-16 bytes a second time. ASCII only.
_np_nvi_reg() {
  LC_ALL=C AF_PATH=$1 awk -F '\t' '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function hexw(s, z,   i, c, o, out) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\001") o = 0; else { o = ord[c]; if (o == "") { bad = 1; o = 63 } }
        out = out sprintf("%02x,", o)
      }
      out = out "00"
      if (z) out = out ",00"
      return out
    }
    function key(view, k,   u) {
      u = toupper(k)
      if (u !~ /^HKEY_LOCAL_MACHINE\\SOFTWARE\\/ && u !~ /^HKEY_CURRENT_USER\\SOFTWARE\\/) { bad = 1; return k }
      if (view == 32 && u ~ /^HKEY_LOCAL_MACHINE\\SOFTWARE\\/ && u !~ /^HKEY_LOCAL_MACHINE\\SOFTWARE\\WOW6432NODE\\/)
        k = substr(k, 1, 28) "Wow6432Node\\" substr(k, 29)
      return k
    }
    BEGIN { for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i; print "REGEDIT4" }
    $1 == "R" {
      k = key($2, $3)
      if (k != last) { print ""; print "[" k "]"; last = k }
      if ($4 == "-") next
      n = ($4 == "@") ? "@" : "\"" q($4) "\""
      if ($5 == "REG_SZ") print n "=\"" q($6) "\""
      else if ($5 == "REG_DWORD") printf "%s=dword:%08x\n", n, $6 + 0
      else if ($5 == "REG_MULTI_SZ") print n "=hex(7):" hexw($6, 1)
      else if ($5 == "REG_EXPAND_SZ") print n "=hex(2):" hexw($6, 0)
      else bad = 1
      next
    }
    $1 == "P" { add = add ";" $2 }
    END {
      if (add != "") {
        p = ENVIRON["AF_PATH"]; n = split(substr(add, 2), dirs, ";")
        for (i = 1; i <= n; i++) if (index(";" tolower(p) ";", ";" tolower(dirs[i]) ";") == 0) p = p (p == "" ? "" : ";") dirs[i]
        if (p != ENVIRON["AF_PATH"]) {
          print ""; print "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Control\\Session Manager\\Environment]"
          print "\"PATH\"=hex(2):" hexw(p, 0)
        }
      }
      if (bad) exit 1
    }
  '
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
    nvi)
      _np_st_i=$(_np_j "$_np_st_k.file") || return 1
      _np_st_f=""
      eval "_np_st_f=\$_np_file_$_np_st_i"
      _np_st_off=$(_np_j "$_np_st_k.sfx_offset") || _np_st_off=0
      _np_st_a="$_np_tmp/x$_np_st_i"
      mkdir -p "$_np_st_a" || return 1
      tail -c "+$((_np_st_off + 1))" "$_np_st_f" > "$_np_tmp/payload" && bsdtar -xf "$_np_tmp/payload" -C "$_np_st_a" 2>/dev/null \
        || { af_note "verb $_np_v" "cannot unpack $_np_st_f at offset $_np_st_off"; return 1; }
      _np_st_m="$_np_st_a/$(_np_j "$_np_st_k.manifest")"
      [ -f "$_np_st_m" ] || { af_note "verb $_np_v" "no $(_np_j "$_np_st_k.manifest") in the package"; return 1; }
      set --
      _np_st_n=$(_np_count "$_np_st_k.vars")
      _np_st_j=0
      while [ "$_np_st_j" -lt "$_np_st_n" ]; do
        set -- "$@" "$(_np_j "$_np_st_k.vars.$_np_st_j")"
        _np_st_j=$((_np_st_j + 1))
      done
      _np_nvi_plan "$_np_st_m" "$@" > "$_np_tmp/plan" 2>> "${log:-/dev/null}" || { af_note "verb $_np_v" "cannot read the package manifest"; return 1; }
      _np_st_d=$(dirname "$_np_st_m")
      _np_st_c=0
      while IFS="$(printf '\t')" read -r _np_st_kind _np_st_to _np_st_from; do
        [ "$_np_st_kind" = C ] || continue
        case "$_np_st_to" in
          [Cc]:\\*) ;;
          *) af_note "verb $_np_v" "refusing target $_np_st_to"; return 1 ;;
        esac
        case "$_np_st_to$_np_st_from" in *..*) af_note "verb $_np_v" "refusing path with .."; return 1 ;; esac
        _np_st_dst="$WINEPREFIX/drive_c/$(printf '%s' "${_np_st_to#??\\}" | tr '\\' /)"
        _np_st_src="$_np_st_d/$(printf '%s' "$_np_st_from" | tr '\\' /)"
        [ -f "$_np_st_src" ] || { af_note "verb $_np_v" "package has no $_np_st_from"; return 1; }
        mkdir -p "$(dirname "$_np_st_dst")" && cp -f "$_np_st_src" "$_np_st_dst" || return 1
        _np_st_c=$((_np_st_c + 1))
      done < "$_np_tmp/plan"
      [ "$_np_st_c" -gt 0 ] || { af_note "verb $_np_v" "the package manifest lists no files"; return 1; }
      # PATH from the live registry: system.reg on disk lags while a wineserver is running
      if grep -q '^P' "$_np_tmp/plan"; then
        _np_st_path=$("$WINELOADER" reg query 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v PATH 2>/dev/null \
          | tr -d '\r' | sed -n -E 's/^[[:space:]]+PATH[[:space:]]+REG_(EXPAND_)?SZ[[:space:]]+//p' | head -1)
        if [ -z "$_np_st_path" ]; then
          af_note "verb $_np_v" "cannot read the prefix PATH, leaving it alone"
          grep -v '^P' "$_np_tmp/plan" > "$_np_tmp/plan.nopath"; mv -f "$_np_tmp/plan.nopath" "$_np_tmp/plan"
        fi
      fi
      _np_nvi_reg "${_np_st_path:-}" < "$_np_tmp/plan" > "$_np_tmp/nvi.reg" || { af_note "verb $_np_v" "cannot convert the package registry entries"; return 1; }
      (cd "$_np_tmp" && "$WINELOADER" regedit /S nvi.reg) >> "${log:-/dev/null}" 2>&1 || return 1
      af_note "verb $_np_v" "installed $_np_st_c files and $(grep -c '^R' "$_np_tmp/plan") registry entries from $(_np_j "$_np_st_k.manifest") without running its setup.exe"
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
      # a failing installer fails the same way next launch; do not hold every launch on it
      mkdir -p "$(dirname "$_np_marker")" && date '+%Y-%m-%d %H:%M:%S failed' > "$_np_marker"
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
