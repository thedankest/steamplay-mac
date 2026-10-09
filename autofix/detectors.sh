# shellcheck shell=sh
# autofix/detectors.sh: generic detect-then-fix rules run before every game launch (POSIX sh).
#
# Detectors (each idempotent, each logs "autofix: <name>: <action>" to $log, each can be turned
# off with NOTPROTON_AUTOFIX_DISABLE="name1,name2", or all of them with "all"):
#   opengl           the game exe (or the largest exe) imports opengl32 -> CX_FWD_COMPAT_GL_CTX=1
#   creative-openal  Creative's OpenAL router (wrap_oal.dll, ct_oal.dll, OpenAL32.dll by
#                    Creative) next to the exe -> OpenAL Soft as OpenAL32.dll, originals in
#                    <exe dir>/notproton-backup/ (autofix_restore_openal undoes it)
#   ue3-audio        Unreal Engine 3 + OpenAL Soft -> clear [ALAudio.ALAudioDevice] DeviceName= in
#                    the user's *Engine.ini (Creative-only "Generic Software" device is silent)
#   physx-legacy     PhysXLoader.dll in the game, or installscript asks for PhysX/UE3Redist, and
#                    no PhysXCore.dll in the prefix -> np_verb physx
#   installscript    Steam installscript.vdf redists -> verbs (see installscript.py); a redist
#                    whose HasRunKey is set but whose payload is missing counts as not installed
#
# Entry points: autofix_run EXE (before launch), autofix_post (after the game exited; the
# UE3 ini only exists after a first run). Inputs: $STEAM_COMPAT_INSTALL_PATH, $WINEPREFIX,
# $WINELOADER, $log, $AUTOFIX_DIR. Needs helpers.sh and verbs.sh.
# Settings: NOTPROTON_AUTOFIX_DISABLE, NOTPROTON_AUTOFIX_REDIST=all (also install optional
# installscript redists: DirectX, .NET, XNA), NOTPROTON_PE_D3D, NOTPROTON_PYTHON (path or none),
# NOTPROTON_OPENAL_CACHE.

af_pe_d3d=${NOTPROTON_PE_D3D:-"$HOME/Library/Application Support/notproton/pe-d3d"}
af_openal_cache=${NOTPROTON_OPENAL_CACHE:-"${NOTPROTON_CACHE:-$HOME/Library/Application Support/notproton/cache}/openal-soft-1.25.2"}
af_openal_soft=0
af_openal_swapped=0

af_enabled() {
  case ",${NOTPROTON_AUTOFIX_DISABLE:-}," in
    *",all,"*|*",$1,"*) af_note "$1" "disabled by NOTPROTON_AUTOFIX_DISABLE"; return 1 ;;
  esac
  return 0
}

# A python3 that will not pop the "install developer tools" dialog (/usr/bin/python3 is a stub
# without them).
af_python() {
  case "${NOTPROTON_PYTHON:-}" in
    none) return 1 ;;
    ?*) [ -x "$NOTPROTON_PYTHON" ] && { echo "$NOTPROTON_PYTHON"; return 0; }; return 1 ;;
  esac
  for af_py in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$af_py" ] && { echo "$af_py"; return 0; }
  done
  if [ -x /usr/bin/python3 ] && af_dev=$(/usr/bin/xcode-select -p 2>/dev/null) && [ -x "$af_dev/usr/bin/python3" ]; then
    echo /usr/bin/python3
    return 0
  fi
  return 1
}

# PE machine of $1: 014c (i386), 8664 (x86_64), aa64
af_pe_machine() {
  af_pm_off=$(od -A n -t u4 -j 60 -N 4 "$1" 2>/dev/null | tr -d ' ')
  case "$af_pm_off" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(od -A n -t x1 -j "$af_pm_off" -N 4 "$1" 2>/dev/null | tr -d ' \n')" = 50450000 ] || return 1
  od -A n -t x2 -j "$((af_pm_off + 4))" -N 2 "$1" 2>/dev/null | tr -d ' \n'
}

# first file in dir $1 named $2, any case
af_find_ci() {
  find "$1" -maxdepth 1 -type f -iname "$2" 2>/dev/null | head -1
}

# largest .exe of the install, launcher/redist folders excluded (same filter as detect_d3d)
af_largest_exe() {
  [ -d "${STEAM_COMPAT_INSTALL_PATH:-}" ] || return 0
  find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 6 -type f -iname '*.exe' -size +200k 2>/dev/null \
    | grep -viE '/(_commonredist|commonredist|redist|redistributables|directx|vcredist|dotnet|support|easyanticheat|battleye|__installer|installers?|crashreport[a-z]*)/' \
    | while IFS= read -r af_le; do printf '%s\t%s\n' "$(stat -f %z "$af_le")" "$af_le"; done \
    | sort -rn | head -1 | cut -f2-
}

# version-resource field $2 of PE $1 ("" when absent); byte search when there is no python3
af_pe_field() {
  if af_pf_py=$(af_python); then
    "$af_pf_py" -I "$AUTOFIX_DIR/pe_version.py" --field "$2" "$1" 2>/dev/null
    return 0
  fi
  # UTF-16LE strings with the NULs dropped read "CompanyNameCreative Labs Inc."
  tr -d '\000' < "$1" 2>/dev/null | LC_ALL=C grep -a -o "$2[^[:alnum:]]\{0,4\}[[:print:]]\{1,80\}" | head -1 \
    | LC_ALL=C sed -E "s/^$2[^[:alnum:]]{0,4}//"
}

af_is_creative_openal() {
  af_pe_field "$1" CompanyName | grep -qi creative
}

af_is_openal_soft() {
  for af_ios in "$af_openal_cache/Win32/soft_oal.dll" "$af_openal_cache/Win64/soft_oal.dll"; do
    [ -f "$af_ios" ] && cmp -s "$1" "$af_ios" && return 0
  done
  af_is_creative_openal "$1" && return 1
  tr -d '\000' < "$1" 2>/dev/null | LC_ALL=C grep -a -q 'OpenAL Soft'
}

# ---- opengl ---------------------------------------------------------------------------------

af_detect_opengl() {
  af_enabled opengl || return 0
  if [ -n "${CX_FWD_COMPAT_GL_CTX+x}" ]; then
    af_note opengl "CX_FWD_COMPAT_GL_CTX=$CX_FWD_COMPAT_GL_CTX already set, left alone"
    return 0
  fi
  if [ ! -x "$af_pe_d3d" ]; then
    af_note opengl "skipped, no pe-d3d at $af_pe_d3d"
    return 0
  fi
  af_og_hit=""
  for af_og_f in "$af_exe" "$af_big_exe"; do
    [ -f "$af_og_f" ] || continue
    af_og_flags=$("$af_pe_d3d" "$af_og_f" 2>/dev/null | cut -d' ' -f1 | tr ',' ' ')
    case " $af_og_flags " in
      *" opengl:i "*) af_og_hit=$af_og_f; break ;;
    esac
  done
  if [ -n "$af_og_hit" ]; then
    set_env CX_FWD_COMPAT_GL_CTX 1
    af_note opengl "$(basename "$af_og_hit") imports opengl32, set CX_FWD_COMPAT_GL_CTX=1"
  else
    af_note opengl "no opengl32 import, nothing to do"
  fi
}

# ---- creative-openal ------------------------------------------------------------------------

# move $1 into backup dir $2 without ever overwriting a backup
af_backup_file() {
  af_bf_name=$(basename "$1")
  if [ ! -e "$2/$af_bf_name" ]; then
    mv "$1" "$2/$af_bf_name"
  elif cmp -s "$1" "$2/$af_bf_name"; then
    rm -f "$1"
  else
    mv "$1" "$2/$af_bf_name.$(date +%Y%m%d%H%M%S)"
  fi
}

af_openal_swap_dir() {
  af_os_dir=$1
  af_os_wrap=$(af_find_ci "$af_os_dir" wrap_oal.dll)
  af_os_ct=$(af_find_ci "$af_os_dir" ct_oal.dll)
  af_os_oal=$(af_find_ci "$af_os_dir" OpenAL32.dll)
  af_os_why=""
  [ -n "$af_os_wrap" ] && af_os_why=" wrap_oal.dll"
  [ -n "$af_os_ct" ] && af_os_why="$af_os_why ct_oal.dll"
  af_os_oal_soft=0
  if [ -n "$af_os_oal" ]; then
    if af_is_openal_soft "$af_os_oal"; then
      af_os_oal_soft=1
    elif af_is_creative_openal "$af_os_oal"; then
      af_os_why="$af_os_why Creative OpenAL32.dll"
    fi
  fi
  if [ -z "$af_os_why" ]; then
    if [ "$af_os_oal_soft" = 1 ]; then
      af_openal_soft=1
      af_note creative-openal "$af_os_dir already uses OpenAL Soft"
    fi
    return 0
  fi
  case "$(af_pe_machine "$af_exe_for_dir")" in
    014c) af_os_arch=Win32 ;;
    8664) af_os_arch=Win64 ;;
    *) af_note creative-openal "found${af_os_why} in $af_os_dir, but the exe machine is unknown, skipped"; return 0 ;;
  esac
  af_os_soft="$af_openal_cache/$af_os_arch/soft_oal.dll"
  if [ ! -f "$af_os_soft" ]; then
    af_note creative-openal "found${af_os_why} in $af_os_dir, but no OpenAL Soft in the cache ($af_os_soft; np_verb openal-soft fills it), skipped"
    return 0
  fi
  af_os_bak="$af_os_dir/notproton-backup"
  mkdir -p "$af_os_bak" || return 0
  [ -n "$af_os_wrap" ] && af_backup_file "$af_os_wrap" "$af_os_bak"
  [ -n "$af_os_ct" ] && af_backup_file "$af_os_ct" "$af_os_bak"
  if [ -n "$af_os_oal" ] && [ "$af_os_oal_soft" = 0 ]; then
    af_backup_file "$af_os_oal" "$af_os_bak"
  elif [ -z "$af_os_oal" ]; then
    # nothing to restore for this name later: remember that we created it
    grep -qx OpenAL32.dll "$af_os_bak/notproton-created" 2>/dev/null || echo OpenAL32.dll >> "$af_os_bak/notproton-created"
  fi
  [ -n "$af_os_oal" ] && [ "$af_os_oal_soft" = 1 ] && rm -f "$af_os_oal"
  if cp "$af_os_soft" "$af_os_dir/OpenAL32.dll"; then
    af_openal_soft=1
    af_openal_swapped=1
    af_note creative-openal "replaced${af_os_why} in $af_os_dir with OpenAL Soft ($af_os_arch), originals in notproton-backup/"
  else
    af_note creative-openal "copying OpenAL Soft into $af_os_dir failed"
  fi
}

af_detect_creative_openal() {
  af_enabled creative-openal || return 0
  af_co_seen=""
  for af_co_exe in "$af_exe" "$af_big_exe"; do
    [ -f "$af_co_exe" ] || continue
    af_co_dir=$(dirname "$af_co_exe")
    case "|$af_co_seen|" in *"|$af_co_dir|"*) continue ;; esac
    af_co_seen="$af_co_seen|$af_co_dir"
    af_exe_for_dir=$af_co_exe
    af_openal_swap_dir "$af_co_dir"
  done
  [ "$af_openal_soft" = 1 ] || af_note creative-openal "no Creative OpenAL router next to the exe, nothing to do"
}

# Undo the swap: autofix_restore_openal [DIR...] (default: every notproton-backup/ in the install)
autofix_restore_openal() {
  if [ "$#" -eq 0 ]; then
    [ -d "${STEAM_COMPAT_INSTALL_PATH:-}" ] || return 0
    set --
    af_ro_list=$(find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 6 -type d -name notproton-backup 2>/dev/null)
    [ -n "$af_ro_list" ] || { af_note creative-openal "nothing to restore"; return 0; }
    af_ro_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2086 # split on newlines only
    set -- $af_ro_list
    IFS=$af_ro_ifs
    for af_ro_b in "$@"; do autofix_restore_openal "$(dirname "$af_ro_b")"; done
    return 0
  fi
  for af_ro_dir in "$@"; do
    af_ro_bak="$af_ro_dir/notproton-backup"
    [ -d "$af_ro_bak" ] || continue
    if [ -f "$af_ro_bak/notproton-created" ]; then
      while IFS= read -r af_ro_c; do
        [ -n "$af_ro_c" ] && [ ! -e "$af_ro_bak/$af_ro_c" ] && rm -f "$af_ro_dir/$af_ro_c"
      done < "$af_ro_bak/notproton-created"
      rm -f "$af_ro_bak/notproton-created"
    fi
    for af_ro_n in OpenAL32.dll wrap_oal.dll ct_oal.dll; do
      af_ro_src=$(af_find_ci "$af_ro_bak" "$af_ro_n")
      [ -n "$af_ro_src" ] || continue
      af_ro_cur=$(af_find_ci "$af_ro_dir" "$af_ro_n")
      [ -n "$af_ro_cur" ] && rm -f "$af_ro_cur"
      mv "$af_ro_src" "$af_ro_dir/$(basename "$af_ro_src")"
    done
    rmdir "$af_ro_bak" 2>/dev/null || true
    af_note creative-openal "restored the original OpenAL files in $af_ro_dir"
  done
}

# ---- ue3-audio ------------------------------------------------------------------------------

# clear KEY= in [SECTION] of an ini; keeps CRLF and UTF-16LE (BOM) files as they are.
# Status 0 when the file changed, 1 when it already had an empty value or no such key.
af_ini_clear_key() {
  af_ik_f=$1
  af_ik_tmp="$af_ik_f.notproton-tmp"
  af_ik_utf16=0
  [ "$(od -A n -t x1 -N 2 "$af_ik_f" 2>/dev/null | tr -d ' \n')" = fffe ] && af_ik_utf16=1
  if [ "$af_ik_utf16" = 1 ]; then
    iconv -f UTF-16LE -t UTF-8 "$af_ik_f" > "$af_ik_tmp.in" 2>/dev/null || { rm -f "$af_ik_tmp.in"; return 1; }
  else
    cp "$af_ik_f" "$af_ik_tmp.in" || return 1
  fi
  AF_SECT=$2 AF_KEY=$3 awk '
    BEGIN { sect = "[" tolower(ENVIRON["AF_SECT"]) "]"; key = tolower(ENVIRON["AF_KEY"]) }
    {
      line = $0; cr = ""
      if (sub(/\r$/, "", line)) cr = "\r"
      t = line; gsub(/^[ \t\357\273\277]+|[ \t]+$/, "", t)
      if (t ~ /^\[.*\]$/) insec = (tolower(t) == sect)
      else if (insec && (i = index(line, "=")) > 0) {
        k = substr(line, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (tolower(k) == key && substr(line, i + 1) != "") { line = substr(line, 1, i); changed = 1 }
      }
      printf "%s%s\n", line, cr
    }
    END { exit changed ? 0 : 1 }
  ' "$af_ik_tmp.in" > "$af_ik_tmp.out"
  af_ik_rc=$?
  if [ "$af_ik_rc" = 0 ]; then
    [ -e "$af_ik_f.bak-notproton" ] || cp -p "$af_ik_f" "$af_ik_f.bak-notproton"
    if [ "$af_ik_utf16" = 1 ]; then
      iconv -f UTF-8 -t UTF-16LE "$af_ik_tmp.out" > "$af_ik_tmp" && cat "$af_ik_tmp" > "$af_ik_f"
    else
      cat "$af_ik_tmp.out" > "$af_ik_f"
    fi
  fi
  rm -f "$af_ik_tmp" "$af_ik_tmp.in" "$af_ik_tmp.out"
  [ "$af_ik_rc" = 0 ]
}

af_detect_ue3_audio() {
  af_enabled ue3-audio || return 0
  [ -f "${STEAM_COMPAT_INSTALL_PATH:-}/Engine/Config/BaseEngine.ini" ] || return 0
  if [ "$af_openal_soft" != 1 ]; then
    af_note ue3-audio "Unreal Engine 3 game without OpenAL Soft, left alone"
    return 0
  fi
  [ "$af_openal_swapped" = 1 ] && af_note ue3-audio "OpenAL Soft was swapped in on this launch"
  af_ua_games="$WINEPREFIX/drive_c/users/steamuser/Documents/My Games"
  af_ua_list=$(find "$af_ua_games" -maxdepth 6 -type f -ipath '*/UnrealEngine3/*/Config/*Engine.ini' 2>/dev/null)
  if [ -z "$af_ua_list" ]; then
    af_note ue3-audio "no user Engine.ini yet (written on first run), will check after the game exits"
    return 0
  fi
  printf '%s\n' "$af_ua_list" > "${TMPDIR:-/tmp}/af_ue3.$$"
  while IFS= read -r af_ua_ini; do
    if af_ini_clear_key "$af_ua_ini" ALAudio.ALAudioDevice DeviceName; then
      af_note ue3-audio "cleared [ALAudio.ALAudioDevice] DeviceName in $af_ua_ini (backup .bak-notproton)"
    else
      af_note ue3-audio "DeviceName already empty or absent in $af_ua_ini"
    fi
  done < "${TMPDIR:-/tmp}/af_ue3.$$"
  rm -f "${TMPDIR:-/tmp}/af_ue3.$$"
}

# ---- physx-legacy ---------------------------------------------------------------------------

af_physx_present() {
  for af_px_root in "Program Files (x86)/NVIDIA Corporation/PhysX" "Program Files (x86)/AGEIA Technologies" \
      "Program Files/NVIDIA Corporation/PhysX" "Program Files/AGEIA Technologies"; do
    [ -d "$WINEPREFIX/drive_c/$af_px_root" ] || continue
    find "$WINEPREFIX/drive_c/$af_px_root" -maxdepth 5 -type f -iname PhysXCore.dll 2>/dev/null | grep -q . && return 0
  done
  return 1
}

af_detect_physx() {
  af_enabled physx-legacy || return 0
  [ -d "${STEAM_COMPAT_INSTALL_PATH:-}" ] || return 0
  af_px_why=""
  af_px_loader=$(find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 3 -type f -iname PhysXLoader.dll 2>/dev/null | head -1)
  if [ -n "$af_px_loader" ]; then
    if [ -n "$(af_find_ci "$(dirname "$af_px_loader")" PhysXCore.dll)" ]; then
      af_note physx-legacy "game ships its own PhysXCore.dll next to PhysXLoader.dll, nothing to do"
      return 0
    fi
    af_px_why="${af_px_loader#"$STEAM_COMPAT_INSTALL_PATH"/}"
  else
    af_px_vdf=$(find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 3 -type f -iname 'installscript*.vdf' 2>/dev/null \
      | while IFS= read -r af_px_v; do LC_ALL=C grep -l -i -E 'physx|ue3redist' "$af_px_v" 2>/dev/null; done | head -1)
    [ -n "$af_px_vdf" ] && af_px_why="$(basename "$af_px_vdf") asks for PhysX/UE3Redist"
  fi
  [ -n "$af_px_why" ] || return 0
  if af_physx_present; then
    af_note physx-legacy "PhysX runtime present in the prefix ($af_px_why)"
    return 0
  fi
  af_note physx-legacy "PhysX runtime missing ($af_px_why), installing verb physx"
  if np_verb physx; then
    af_note physx-legacy "verb physx done"
  else
    af_note physx-legacy "verb physx did not complete"
  fi
}

# ---- installscript --------------------------------------------------------------------------

# HasRunKey "HKEY_LOCAL_MACHINE\Software\Vendor\Game\Name" -> key + value "Name"; Steam's
# evaluator is 32-bit, so its writes land under Wow6432Node.
af_hasrunkey_set() {
  af_hk_key=${1%\\*}
  af_hk_val=${1##*\\}
  af_hk_rel=$(printf '%s' "$af_hk_key" | sed -E 's/^(HKEY_LOCAL_MACHINE|HKLM)\\//')
  [ "$af_hk_rel" != "$af_hk_key" ] || return 1
  case "$(printf '%s' "$af_hk_rel" | tr '[:upper:]' '[:lower:]')" in
    software\\wow6432node\\*) af_hk_wow=$af_hk_rel ;;
    software\\*) af_hk_wow="Software\\Wow6432Node\\${af_hk_rel#*\\}" ;;
    *) af_hk_wow=$af_hk_rel ;;
  esac
  # HasRunKey read as key + value name (what Steam's evaluator wrote for Alien Breed 3) or, as
  # some installscripts use it, as a key of its own
  _np_regfile_get "$WINEPREFIX/system.reg" "$af_hk_wow" "$af_hk_val" >/dev/null && return 0
  _np_regfile_get "$WINEPREFIX/system.reg" "$af_hk_rel" "$af_hk_val" >/dev/null && return 0
  _np_regfile_has_key "$WINEPREFIX/system.reg" "$af_hk_wow\\$af_hk_val" && return 0
  _np_regfile_has_key "$WINEPREFIX/system.reg" "$af_hk_rel\\$af_hk_val" && return 0
  return 1
}

af_hasrunkey_mark() {
  af_hk_key=${1%\\*}
  af_hk_val=${1##*\\}
  af_hk_rel=$(printf '%s' "$af_hk_key" | sed -E 's/^(HKEY_LOCAL_MACHINE|HKLM)\\//')
  case "$(printf '%s' "$af_hk_rel" | tr '[:upper:]' '[:lower:]')" in
    software\\wow6432node\\*) ;;
    software\\*) af_hk_rel="Software\\Wow6432Node\\${af_hk_rel#*\\}" ;;
  esac
  set_reg "HKLM\\$af_hk_rel" "$af_hk_val" REG_DWORD 1
}

af_detect_installscript() {
  af_enabled installscript || return 0
  [ -d "${STEAM_COMPAT_INSTALL_PATH:-}" ] || return 0
  af_is_vdfs=$(find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 3 -type f -iname 'installscript*.vdf' 2>/dev/null)
  [ -n "$af_is_vdfs" ] || return 0
  if ! af_is_py=$(af_python); then
    af_note installscript "found installscript.vdf but no python3 to read it, skipped"
    return 0
  fi
  af_is_tab=$(printf '\t')
  printf '%s\n' "$af_is_vdfs" | while IFS= read -r af_is_vdf; do
    "$af_is_py" -I "$AUTOFIX_DIR/installscript.py" --sh "$af_is_vdf" 2>> "${log:-/dev/null}" \
      | while IFS="$af_is_tab" read -r af_is_verb af_is_pol af_is_kind af_is_name af_is_key; do
        if [ "$af_is_verb" = - ]; then
          af_note installscript "$af_is_name ($af_is_kind) has no verb, left to Steam"
          continue
        fi
        if np_verb_installed "$af_is_verb"; then
          af_note installscript "$af_is_name: $af_is_verb present"
        elif [ "$af_is_pol" = auto ] || [ "${NOTPROTON_AUTOFIX_REDIST:-}" = all ]; then
          if [ -n "$af_is_key" ] && af_hasrunkey_set "$af_is_key"; then
            af_note installscript "$af_is_name: HasRunKey is set but $af_is_verb is missing, treating it as not installed"
          fi
          af_note installscript "$af_is_name: installing verb $af_is_verb"
          np_verb "$af_is_verb" || af_note installscript "$af_is_name: verb $af_is_verb did not complete"
        else
          af_note installscript "$af_is_name: optional $af_is_verb not installed (NOTPROTON_AUTOFIX_REDIST=all installs it)"
          continue
        fi
        if [ -n "$af_is_key" ] && np_verb_installed "$af_is_verb" && ! af_hasrunkey_set "$af_is_key"; then
          af_hasrunkey_mark "$af_is_key"
          af_note installscript "$af_is_name: marked $af_is_key as run so Steam skips its installer"
        fi
      done
  done
}

# ---- entry points ---------------------------------------------------------------------------

af_setup() {
  af_exe=${1:-}
  af_big_exe=$(af_largest_exe)
  [ "$af_big_exe" = "$af_exe" ] && af_big_exe=""
  # read by verbs.sh (extract_dll_to ... exe_dir)
  af_exe_dir=""
  [ -f "$af_exe" ] && af_exe_dir=$(dirname "$af_exe")
  # shellcheck disable=SC2034
  NP_EXE_DIR=$af_exe_dir
}

# before launch: autofix_run "$1"
autofix_run() {
  af_setup "${1:-}"
  af_note start "app ${app_id:-?}, exe ${af_exe:-none}, largest ${af_big_exe:-same}"
  af_detect_opengl
  af_detect_creative_openal
  af_detect_ue3_audio
  af_detect_installscript
  af_detect_physx
  return 0
}

# after the game exited: autofix_post (the UE3 user ini appears after the first run)
autofix_post() {
  [ -n "${af_exe+x}" ] || af_setup "${1:-}"
  af_detect_ue3_audio
  return 0
}
