# shellcheck shell=sh
# autofix/helpers.sh: the per-game fix helper API, sourced by compat_run.sh (/bin/sh, set -e).
#
# Defines the helpers that compat_run.sh defines for fixes/<appid>.sh when they do not exist
# yet (same behaviour, so generated and hand-written fixes work either way):
#   set_env NAME VALUE              export to the game (name is added to $fix_env)
#   set_reg KEY NAME TYPE DATA      wine reg add
#   dll_override DLL MODE           HKCU\Software\Wine\DllOverrides (MODE '' disables the DLL)
#   set_winver EXE VERSION          per-exe Windows version
#   edit_file GLOB KEY VALUE        "key value"/"key=value" lines under the prefix user profile
# and adds two helpers for imported (umu-protonfixes) fixes:
#   append_arg ARG                  append ARG to the game's command line
#   replace_exe FROM TO             case-insensitive literal substring replacement in every
#                                   command line element (umu's replace_command); the launch
#                                   target keeps its old value when the new path does not exist
# append_arg/replace_exe only record the change; the run script applies it with
#   eval "set -- $(autofix_argv "$@")"
# right after the fix file was sourced and before it reads $1 again.
#
# Uses: $log, $WINELOADER, $WINEPREFIX. Every variable here is prefixed af_ so nothing the run
# script uses later is clobbered.

af_log() { echo "$*" >> "${log:-/dev/null}" 2>&1 || true; }

# autofix: <name>: <action>
af_note() { af_log "autofix: $1: $2"; }

if ! command -v set_env >/dev/null 2>&1; then
  set_env() { export "$1=$2"; fix_env="${fix_env:-} $1"; af_log "fix: env $1=$2"; }
fi
if ! command -v set_reg >/dev/null 2>&1; then
  set_reg() { "$WINELOADER" reg add "$1" /v "$2" /t "$3" /d "$4" /f >> "${log:-/dev/null}" 2>&1 || true; }
fi
if ! command -v dll_override >/dev/null 2>&1; then
  dll_override() { set_reg 'HKCU\Software\Wine\DllOverrides' "$1" REG_SZ "$2"; }
fi
if ! command -v set_winver >/dev/null 2>&1; then
  set_winver() { set_reg "HKCU\\Software\\Wine\\AppDefaults\\$1" Version REG_SZ "$2"; }
fi
if ! command -v edit_file >/dev/null 2>&1; then
  edit_file() {
    af_ef_base="$WINEPREFIX/drive_c/users/steamuser"
    af_ef_cr=$(printf '\r')
    find "$af_ef_base" -path "$af_ef_base/$1" -type f 2>/dev/null | while IFS= read -r af_ef_f; do
      sed -i '' -E "s/^($2)([ =])[^$af_ef_cr]*/\1\2$3/" "$af_ef_f" && af_log "fix: $af_ef_f: $2 -> $3" || true
    done
  }
fi

# 'it'\''s' style quoting for: eval "set -- ..."  Pure sh (no command substitution of the value,
# so trailing newlines survive): every ' becomes '\'' and the whole word is wrapped in '...'.
af_quote() {
  af_q_rest=$1
  af_q_out=
  while :; do
    case "$af_q_rest" in
      *\'*)
        af_q_out="$af_q_out${af_q_rest%%\'*}'\\''"
        af_q_rest=${af_q_rest#*\'}
        ;;
      *)
        af_q_out="$af_q_out$af_q_rest"
        break
        ;;
    esac
  done
  printf "'%s'" "$af_q_out"
}

af_argv_append=""
af_argv_replace=""

append_arg() {
  af_argv_append="$af_argv_append $(af_quote "$1")"
  af_log "fix: argument + $1"
}

replace_exe() {
  af_argv_replace="$af_argv_replace $(af_quote "$1") $(af_quote "$2")"
  af_log "fix: command line '$1' -> '$2'"
}

# case-insensitive literal substring replacement: af_subst_ci STRING FROM TO
af_subst_ci() {
  AF_S=$1 AF_O=$2 AF_R=$3 awk 'BEGIN {
    s = ENVIRON["AF_S"]; o = ENVIRON["AF_O"]; r = ENVIRON["AF_R"]
    if (o == "") { printf "%s", s; exit }
    ls = tolower(s); lo = tolower(o); out = ""
    while ((i = index(ls, lo)) > 0) {
      out = out substr(s, 1, i - 1) r
      s = substr(s, i + length(o)); ls = substr(ls, i + length(o))
    }
    printf "%s", out s
  }'
}

af_apply_replacements() {
  af_ar_s=$1
  eval "set -- $af_argv_replace"
  while [ "$#" -ge 2 ]; do
    af_ar_s=$(af_subst_ci "$af_ar_s" "$1" "$2")
    shift 2
  done
  printf '%s' "$af_ar_s"
}

# Prints the game's command line with the recorded replacements and appended arguments, quoted
# for: eval "set -- $(autofix_argv "$@")"
autofix_argv() {
  af_av_out=""
  af_av_first=1
  for af_av_a in "$@"; do
    af_av_new=$af_av_a
    if [ -n "$af_argv_replace" ]; then
      af_av_new=$(af_apply_replacements "$af_av_a")
      if [ "$af_av_first" = 1 ] && [ "$af_av_new" != "$af_av_a" ] && [ ! -f "$af_av_new" ]; then
        af_log "fix: replacement target $af_av_new does not exist, keeping $af_av_a"
        af_av_new=$af_av_a
      fi
    fi
    af_av_first=0
    af_av_out="$af_av_out $(af_quote "$af_av_new")"
  done
  printf '%s%s\n' "$af_av_out" "$af_argv_append"
}
