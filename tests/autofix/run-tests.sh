#!/bin/sh
# tests/autofix/run-tests.sh: offline tests for autofix/ and tools/umu2np.py.
#
# Everything runs in a mktemp -d tree: fake prefix, fake game folders, fake Wine loader, fake
# OpenAL Soft cache, file:// downloads. Synthetic PE files are built with the mingw-w64 cross
# compilers (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc + windres) and pe-d3d from
# notproton/helpers/pe-d3d.c with cc. Nothing touches Steam, real prefixes or the network.
#
#   sh tests/autofix/run-tests.sh        exit 0 when every check passes

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
AF="$repo/autofix"
fixtures="$here/fixtures"

T=$(mktemp -d "${TMPDIR:-/tmp}/autofix-tests.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT INT TERM

pass=0
failed=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
check() { # check NAME CMD...
  name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name" "$*"; fi
}
has_line() { grep -Fqx -- "$2" "$1"; }
has_text() { grep -Fq -- "$2" "$1"; }

for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc i686-w64-mingw32-windres x86_64-w64-mingw32-windres cc python3 plutil bsdtar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing $tool"; exit 2; }
done
PY=$(command -v python3)
# shell for the sourced code, like compat_run.sh (/bin/sh); AUTOFIX_TEST_SH=/bin/dash works too
SH=${AUTOFIX_TEST_SH:-/bin/sh}

# ---- fixtures: PE files ---------------------------------------------------------------------
B="$T/build"
mkdir -p "$B" "$T/bin"
cc -O1 -o "$T/bin/pe-d3d" "$repo/notproton/helpers/pe-d3d.c" || { echo "pe-d3d build failed"; exit 2; }

cat > "$B/gl.c" <<'EOF'
#include <windows.h>
#include <GL/gl.h>
int main(void) { return glGetString(GL_VENDOR) != 0; }
EOF
cat > "$B/d3d.c" <<'EOF'
#include <d3d9.h>
int main(void) { return Direct3DCreate9(D3D_SDK_VERSION) != 0; }
EOF
echo 'int main(void) { return 0; }' > "$B/plain.c"
echo 'int __stdcall DllMain(void *a, unsigned b, void *c) { (void)a; (void)b; (void)c; return 1; }' > "$B/dll.c"

rcfile() { # rcfile OUT COMPANY PRODUCT VERSION
  cat > "$1" <<EOF
1 VERSIONINFO
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "$2"
      VALUE "ProductName", "$3"
      VALUE "ProductVersion", "$4"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
EOF
}
dll32() { # dll32 OUT [COMPANY PRODUCT VERSION]
  if [ "$#" -gt 1 ]; then
    rcfile "$B/r.rc" "$2" "$3" "$4"
    i686-w64-mingw32-windres "$B/r.rc" -O coff -o "$B/r32.o" && i686-w64-mingw32-gcc -shared -nostdlib -e _DllMain@12 -o "$1" "$B/dll.c" "$B/r32.o"
  else
    i686-w64-mingw32-gcc -shared -nostdlib -e _DllMain@12 -o "$1" "$B/dll.c"
  fi
}
dll64() {
  rcfile "$B/r.rc" "$2" "$3" "$4"
  x86_64-w64-mingw32-windres "$B/r.rc" -O coff -o "$B/r64.o" && x86_64-w64-mingw32-gcc -shared -nostdlib -e DllMain -o "$1" "$B/dll.c" "$B/r64.o"
}
x86_64-w64-mingw32-gcc -o "$B/gl64.exe" "$B/gl.c" -lopengl32 || exit 2
i686-w64-mingw32-gcc -o "$B/d3d32.exe" "$B/d3d.c" -ld3d9 || exit 2
i686-w64-mingw32-gcc -o "$B/game32.exe" "$B/plain.c" || exit 2
x86_64-w64-mingw32-gcc -o "$B/game64.exe" "$B/plain.c" || exit 2
dll32 "$B/creative_OpenAL32.dll" "Creative Labs Inc." "OpenAL" "2.0.7.0" || exit 2
dll32 "$B/wrap_oal.dll" || exit 2
dll32 "$B/soft32.dll" "" "OpenAL Soft" "1.25.2" || exit 2
dll64 "$B/soft64.dll" "" "OpenAL Soft" "1.25.2" || exit 2
rcfile "$B/vc.rc" "Microsoft Corporation" "Microsoft Visual C++ 2005 Redistributable" "8.0.50727.6195"
i686-w64-mingw32-windres "$B/vc.rc" -O coff -o "$B/vc.o" && i686-w64-mingw32-gcc -o "$B/vcredist_x86.exe" "$B/plain.c" "$B/vc.o" || exit 2
check "fixture: synthetic PE files built" test -s "$B/soft64.dll"

# ---- fake Wine loader -----------------------------------------------------------------------
cat > "$T/bin/wine" <<'EOF'
#!/bin/sh
# fake loader: records every call; "installers" create $FAKE_WINE_CREATE (prefix-relative)
echo "$*" >> "$WINE_CALLS"
case "$1" in
  regedit) [ -n "${FAKE_WINE_SAVE:-}" ] && cp "$3" "$FAKE_WINE_SAVE"; exit 0 ;;
  reg) [ "$2" = query ] && [ -n "${FAKE_WINE_PATH:-}" ] && printf '\r\nHKEY_LOCAL_MACHINE\\System\r\n    PATH    REG_EXPAND_SZ    %s\r\n' "$FAKE_WINE_PATH"; exit 0 ;;
  uninstaller) exit 0 ;;
esac
[ -n "${FAKE_WINE_SLEEP:-}" ] && sleep "$FAKE_WINE_SLEEP"
if [ -n "${FAKE_WINE_CREATE:-}" ]; then
  mkdir -p "$(dirname "$WINEPREFIX/$FAKE_WINE_CREATE")"
  echo native > "$WINEPREFIX/$FAKE_WINE_CREATE"
fi
exit "${FAKE_WINE_RC:-0}"
EOF
chmod +x "$T/bin/wine"

# common environment for scenarios
cache="$T/cache"
mkdir -p "$cache/openal-soft-1.25.2/Win32" "$cache/openal-soft-1.25.2/Win64"
cp "$B/soft32.dll" "$cache/openal-soft-1.25.2/Win32/soft_oal.dll"
cp "$B/soft64.dll" "$cache/openal-soft-1.25.2/Win64/soft_oal.dll"
export AUTOFIX_DIR="$AF" NOTPROTON_CACHE="$cache" NOTPROTON_PE_D3D="$T/bin/pe-d3d" \
  WINELOADER="$T/bin/wine" WINE_CALLS="$T/wine.calls" NOTPROTON_PYTHON="$PY"
unset CX_FWD_COMPAT_GL_CTX NOTPROTON_AUTOFIX_DISABLE NOTPROTON_AUTOFIX_REDIST WINESERVER 2>/dev/null || true

new_prefix() { # new_prefix DIR
  rm -rf "$1"
  mkdir -p "$1/drive_c/windows/system32" "$1/drive_c/windows/syswow64" \
    "$1/drive_c/users/steamuser/Documents" "$1/drive_c/Program Files (x86)"
  printf 'WINE REGISTRY Version 2\n' > "$1/system.reg"
  printf 'WINE REGISTRY Version 2\n' > "$1/user.reg"
}

# run one scenario like compat_run.sh does: /bin/sh, set -e, autofix_run "$exe" || true
scenario() { # scenario NAME INSTALL PREFIX EXE [extra shell code]
  sc_log="$T/$1.log"
  : > "$sc_log"
  STEAM_COMPAT_INSTALL_PATH=$2 WINEPREFIX=$3 log=$sc_log app_id=1 "$SH" -e -c '
    fix_env=""
    . "$AUTOFIX_DIR/autofix.sh"
    '"${5:-}"'
    autofix_run "$1" || echo "autofix_run failed" >> "$log"
    printf "CX_FWD_COMPAT_GL_CTX=%s\nfix_env=%s\n" "${CX_FWD_COMPAT_GL_CTX:-unset}" "$fix_env" >> "$log"
  ' scenario "$4"
}

# ---- 1. opengl ------------------------------------------------------------------------------
G="$T/games/gl"
mkdir -p "$G/bin"
cp "$B/gl64.exe" "$G/bin/Game.exe"
P="$T/pfx-gl"
new_prefix "$P"
scenario gl "$G" "$P" "$G/bin/Game.exe"
check "opengl: opengl32 import sets CX_FWD_COMPAT_GL_CTX=1" has_line "$T/gl.log" "CX_FWD_COMPAT_GL_CTX=1"
check "opengl: name forwarded through fix_env" has_line "$T/gl.log" "fix_env= CX_FWD_COMPAT_GL_CTX"
check "opengl: logged as autofix: opengl:" has_text "$T/gl.log" "autofix: opengl: Game.exe imports opengl32, set CX_FWD_COMPAT_GL_CTX=1"

# launcher stub in front of the GL exe: the largest exe is scanned too
mkdir -p "$G/launcher"
cp "$B/game32.exe" "$G/launcher/Launcher.exe"
dd if=/dev/zero bs=1024 count=300 >> "$G/bin/Game.exe" 2>/dev/null
scenario gl2 "$G" "$P" "$G/launcher/Launcher.exe"
check "opengl: largest exe behind a launcher is scanned" has_line "$T/gl2.log" "CX_FWD_COMPAT_GL_CTX=1"

D3="$T/games/d3d"
mkdir -p "$D3"
cp "$B/d3d32.exe" "$D3/Game.exe"
scenario d3d "$D3" "$P" "$D3/Game.exe"
check "opengl: D3D9 game left alone" has_line "$T/d3d.log" "CX_FWD_COMPAT_GL_CTX=unset"

(export CX_FWD_COMPAT_GL_CTX=0; scenario glpre "$G" "$P" "$G/bin/Game.exe")
check "opengl: user value (launch option) wins" has_line "$T/glpre.log" "CX_FWD_COMPAT_GL_CTX=0"
(export NOTPROTON_AUTOFIX_DISABLE=physx-legacy,opengl; scenario gloff "$G" "$P" "$G/bin/Game.exe")
check "opengl: NOTPROTON_AUTOFIX_DISABLE=opengl" has_line "$T/gloff.log" "CX_FWD_COMPAT_GL_CTX=unset"
check "opengl: disable is logged" has_text "$T/gloff.log" "autofix: opengl: disabled by NOTPROTON_AUTOFIX_DISABLE"

# ---- 2. creative-openal + 3. ue3-audio ------------------------------------------------------
A="$T/games/ab3"
mkdir -p "$A/Binaries" "$A/Engine/Config"
cp "$B/game32.exe" "$A/Binaries/AlienBreed3Descent.exe"
cp "$B/creative_OpenAL32.dll" "$A/Binaries/OpenAL32.dll"
cp "$B/wrap_oal.dll" "$A/Binaries/wrap_oal.dll"
printf '[Engine.Engine]\r\n' > "$A/Engine/Config/BaseEngine.ini"
P="$T/pfx-ab3"
new_prefix "$P"
cfg="$P/drive_c/users/steamuser/Documents/My Games/UnrealEngine3/AlienBreed3DescentGame/Config"
mkdir -p "$cfg"
ini="$cfg/AlienBreed3DescentEngine.ini"
printf '[Engine.Engine]\r\nDeviceName=KeepMe\r\n[ALAudio.ALAudioDevice]\r\nMaxChannels=32\r\nDeviceName=Generic Software\r\nUseEffectsProcessing=True\r\n[Other]\r\nDeviceName=AlsoKeep\r\n' > "$ini"
cp "$ini" "$T/ini.orig"
crlf_before=$(grep -c "$(printf '\r')$" "$ini")

scenario ab3 "$A" "$P" "$A/Binaries/AlienBreed3Descent.exe"
check "creative-openal: OpenAL32.dll is now OpenAL Soft Win32" cmp -s "$A/Binaries/OpenAL32.dll" "$B/soft32.dll"
check "creative-openal: wrap_oal.dll moved out" test ! -e "$A/Binaries/wrap_oal.dll"
check "creative-openal: Creative OpenAL32.dll in notproton-backup" cmp -s "$A/Binaries/notproton-backup/OpenAL32.dll" "$B/creative_OpenAL32.dll"
check "creative-openal: wrap_oal.dll in notproton-backup" cmp -s "$A/Binaries/notproton-backup/wrap_oal.dll" "$B/wrap_oal.dll"
check "creative-openal: logged" has_text "$T/ab3.log" "autofix: creative-openal: replaced wrap_oal.dll Creative OpenAL32.dll in $A/Binaries with OpenAL Soft (Win32)"
check "ue3-audio: DeviceName cleared in [ALAudio.ALAudioDevice]" grep -q "^DeviceName=$(printf '\r')\$" "$ini"
check "ue3-audio: other sections keep DeviceName" grep -q '^DeviceName=KeepMe' "$ini"
check "ue3-audio: [Other] keeps DeviceName" grep -q '^DeviceName=AlsoKeep' "$ini"
check "ue3-audio: CRLF kept on every line" test "$(grep -c "$(printf '\r')$" "$ini")" = "$crlf_before"
check "ue3-audio: line count unchanged" test "$(wc -l < "$ini")" = "$(wc -l < "$T/ini.orig")"
check "ue3-audio: .bak-notproton holds the original" cmp -s "$ini.bak-notproton" "$T/ini.orig"
check "ue3-audio: logged" has_text "$T/ab3.log" "autofix: ue3-audio: cleared [ALAudio.ALAudioDevice] DeviceName"

cp "$ini" "$T/ini.after1"
scenario ab3again "$A" "$P" "$A/Binaries/AlienBreed3Descent.exe"
check "creative-openal: second run is a no-op" has_text "$T/ab3again.log" "already uses OpenAL Soft"
check "creative-openal: backup untouched on second run" cmp -s "$A/Binaries/notproton-backup/OpenAL32.dll" "$B/creative_OpenAL32.dll"
check "ue3-audio: second run leaves the ini alone" cmp -s "$ini" "$T/ini.after1"
check "creative-openal: no extra backups" test "$(ls "$A/Binaries/notproton-backup" | wc -l | tr -d ' ')" = 2

# Steam "verify files" puts the Creative files back: swapped again, backups never overwritten
cp "$B/creative_OpenAL32.dll" "$A/Binaries/OpenAL32.dll"
cp "$B/wrap_oal.dll" "$A/Binaries/wrap_oal.dll"
scenario ab3verify "$A" "$P" "$A/Binaries/AlienBreed3Descent.exe"
check "creative-openal: re-swapped after Steam verify" cmp -s "$A/Binaries/OpenAL32.dll" "$B/soft32.dll"
check "creative-openal: identical originals not duplicated" test "$(ls "$A/Binaries/notproton-backup" | wc -l | tr -d ' ')" = 2

# restore
STEAM_COMPAT_INSTALL_PATH=$A log="$T/restore.log" "$SH" -e -c '. "$AUTOFIX_DIR/autofix.sh"; autofix_restore_openal'
check "restore: Creative OpenAL32.dll back" cmp -s "$A/Binaries/OpenAL32.dll" "$B/creative_OpenAL32.dll"
check "restore: wrap_oal.dll back" cmp -s "$A/Binaries/wrap_oal.dll" "$B/wrap_oal.dll"
check "restore: backup dir removed" test ! -e "$A/Binaries/notproton-backup"

# without python3: byte search fallback, and no cache -> logged and skipped
(export NOTPROTON_PYTHON=none; scenario ab3nopy "$A" "$P" "$A/Binaries/AlienBreed3Descent.exe")
check "creative-openal: detected without python3 (byte search)" cmp -s "$A/Binaries/OpenAL32.dll" "$B/soft32.dll"
STEAM_COMPAT_INSTALL_PATH=$A log="$T/restore2.log" "$SH" -e -c '. "$AUTOFIX_DIR/autofix.sh"; autofix_restore_openal "$1/Binaries"' x "$A"
(export NOTPROTON_OPENAL_CACHE="$T/nocache"; scenario ab3nocache "$A" "$P" "$A/Binaries/AlienBreed3Descent.exe")
check "creative-openal: missing cache is logged and skipped" has_text "$T/ab3nocache.log" "but no OpenAL Soft in the cache"
check "creative-openal: files untouched without cache" cmp -s "$A/Binaries/OpenAL32.dll" "$B/creative_OpenAL32.dll"

# 64-bit game with only wrap_oal.dll: OpenAL32.dll is created, restore removes it again
W="$T/games/w64"
mkdir -p "$W/Bin64"
cp "$B/game64.exe" "$W/Bin64/Game.exe"
cp "$B/wrap_oal.dll" "$W/Bin64/wrap_oal.dll"
scenario w64 "$W" "$P" "$W/Bin64/Game.exe"
check "creative-openal: x86_64 exe gets the Win64 DLL" cmp -s "$W/Bin64/OpenAL32.dll" "$B/soft64.dll"
STEAM_COMPAT_INSTALL_PATH=$W log="$T/restore3.log" "$SH" -e -c '. "$AUTOFIX_DIR/autofix.sh"; autofix_restore_openal'
check "restore: created OpenAL32.dll removed" test ! -e "$W/Bin64/OpenAL32.dll"
check "restore: wrap_oal.dll back (64-bit case)" test -f "$W/Bin64/wrap_oal.dll"

# UE3 without OpenAL Soft: ini untouched
N="$T/games/ue3plain"
mkdir -p "$N/Binaries" "$N/Engine/Config"
cp "$B/game32.exe" "$N/Binaries/Game.exe"
: > "$N/Engine/Config/BaseEngine.ini"
P2="$T/pfx-ue3plain"
new_prefix "$P2"
mkdir -p "$P2/drive_c/users/steamuser/Documents/My Games/UnrealEngine3/G/Config"
cp "$T/ini.orig" "$P2/drive_c/users/steamuser/Documents/My Games/UnrealEngine3/G/Config/GEngine.ini"
scenario ue3plain "$N" "$P2" "$N/Binaries/Game.exe"
check "ue3-audio: no OpenAL Soft -> ini untouched" cmp -s "$P2/drive_c/users/steamuser/Documents/My Games/UnrealEngine3/G/Config/GEngine.ini" "$T/ini.orig"

# UTF-16LE ini (some UE3 builds write them) through the post-exit hook
u16="$P/drive_c/users/steamuser/Documents/My Games/UnrealEngine3/U16Game/Config/U16Engine.ini"
mkdir -p "$(dirname "$u16")"
{ printf '\377\376'; printf '[ALAudio.ALAudioDevice]\r\nDeviceName=Generic Software\r\n' | iconv -f UTF-8 -t UTF-16LE; } > "$u16"
STEAM_COMPAT_INSTALL_PATH=$A WINEPREFIX=$P log="$T/u16.log" "$SH" -e -c '
  . "$AUTOFIX_DIR/autofix.sh"; af_openal_soft=1; af_setup "$1"; autofix_post || true' x "$A/Binaries/AlienBreed3Descent.exe"
check "ue3-audio: UTF-16LE ini edited" test "$(iconv -f UTF-16LE -t UTF-8 "$u16" | tr -d '\r' | tail -1)" = "DeviceName="
check "ue3-audio: UTF-16LE BOM kept" test "$(od -A n -t x1 -N 2 "$u16" | tr -d ' \n')" = fffe

# ---- 4. physx-legacy (np_verb stubbed) ------------------------------------------------------
stub='np_verb() { echo "np_verb $*" >> "$log"; return 0; }'
X="$T/games/physx"
mkdir -p "$X/Binaries/Win32"
cp "$B/game32.exe" "$X/Binaries/Win32/Game.exe"
: > "$X/Binaries/Win32/PhysXLoader.dll"
P="$T/pfx-physx"
new_prefix "$P"
scenario px1 "$X" "$P" "$X/Binaries/Win32/Game.exe" "$stub"
check "physx-legacy: PhysXLoader.dll + empty prefix -> np_verb physx" has_line "$T/px1.log" "np_verb physx"
mkdir -p "$P/drive_c/Program Files (x86)/NVIDIA Corporation/PhysX/Engine/v2.8.3"
: > "$P/drive_c/Program Files (x86)/NVIDIA Corporation/PhysX/Engine/v2.8.3/PhysXCore.dll"
scenario px2 "$X" "$P" "$X/Binaries/Win32/Game.exe" "$stub"
check "physx-legacy: runtime present -> no verb" sh -c '! grep -q "^np_verb" "$1"' x "$T/px2.log"
new_prefix "$P"
mkdir -p "$P/drive_c/Program Files (x86)/AGEIA Technologies/Engine/v2.7.6"
: > "$P/drive_c/Program Files (x86)/AGEIA Technologies/Engine/v2.7.6/PhysXCore.dll"
scenario px3 "$X" "$P" "$X/Binaries/Win32/Game.exe" "$stub"
check "physx-legacy: AGEIA runtime counts as present" sh -c '! grep -q "^np_verb" "$1"' x "$T/px3.log"
: > "$X/Binaries/Win32/PhysXCore.dll"
new_prefix "$P"
scenario px4 "$X" "$P" "$X/Binaries/Win32/Game.exe" "$stub"
check "physx-legacy: game-local PhysXCore.dll -> no verb" sh -c '! grep -q "^np_verb" "$1"' x "$T/px4.log"
X2="$T/games/physx-vdf"
mkdir -p "$X2/Binaries"
cp "$B/game32.exe" "$X2/Binaries/Game.exe"
printf '"InstallScript"\n{\n "Run Process"\n {\n  "UE3Redist"\n  {\n   "process 1" "%%INSTALLDIR%%\\\\Redist\\\\UE3Redist.exe"\n  }\n }\n}\n' > "$X2/installscript.vdf"
new_prefix "$P"
(export NOTPROTON_PYTHON=none; scenario px5 "$X2" "$P" "$X2/Binaries/Game.exe" "$stub")
check "physx-legacy: installscript UE3Redist (no python) -> np_verb physx" has_line "$T/px5.log" "np_verb physx"

# ---- 5. installscript parsing + policy ------------------------------------------------------
I="$T/games/ab3-is"
mkdir -p "$I/Binaries" "$I/Redist"
cp "$B/game32.exe" "$I/Binaries/AlienBreed3Descent.exe"
cp "$B/vcredist_x86.exe" "$I/Redist/vcredist_x86.exe"
cp "$fixtures/installscript_ab3.vdf" "$I/installscript.vdf"
"$PY" -I "$AF/installscript.py" --sh "$I/installscript.vdf" > "$T/is.tsv" 2> "$T/is.err"
tab=$(printf '\t')
check "installscript: UE3Redist -> physx auto + HasRunKey" has_line "$T/is.tsv" "physx${tab}auto${tab}ue3redist${tab}UE3Redist${tab}HKEY_LOCAL_MACHINE\\Software\\Team17 Software Ltd.\\AlienBreed\\UE3Redist"
check "installscript: DXAug09Redist -> d3dx9 optional" has_line "$T/is.tsv" "d3dx9${tab}optional${tab}directx${tab}DirectX${tab}HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\22670"
check "installscript: vcredist_x86 (year from its version resource) -> vcrun2005" has_line "$T/is.tsv" "vcrun2005${tab}auto${tab}vcredist${tab}vcredist${tab}HKEY_LOCAL_MACHINE\\Software\\Team17 Software Ltd.\\AlienBreed\\vcredist"
check "installscript: unknown process -> custom, no verb" has_line "$T/is.tsv" "-${tab}none${tab}custom${tab}Game Launcher Setup${tab}"
"$PY" -I "$AF/installscript.py" --json "$I/installscript.vdf" > "$T/is.json"
check "installscript: JSON lists the Registry section" "$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(r["name"]=="Language" for r in d["registry"]); assert len(d["redists"])==4' "$T/is.json"

# Steam already wrote the UE3Redist HasRunKey (installer failed), payload missing
P="$T/pfx-is"
new_prefix "$P"
printf '\n[Software\\\\Wow6432Node\\\\Team17 Software Ltd.\\\\AlienBreed] 1700000000\n"UE3Redist"=dword:00000001\n' >> "$P/system.reg"
: > "$T/wine.calls"
isstub='np_verb() { echo "np_verb $*" >> "$log"; case "$1" in vcrun2005) mkdir -p "$WINEPREFIX/drive_c/windows/winsxs/x86_microsoft.vc80.mfc_1fc8b3b9a1e18e3b_8.0.50727.6195_none_deadbeef"; : > "$WINEPREFIX/drive_c/windows/winsxs/x86_microsoft.vc80.mfc_1fc8b3b9a1e18e3b_8.0.50727.6195_none_deadbeef/mfc80.dll" ;; esac; return 0; }'
(export NOTPROTON_AUTOFIX_DISABLE=physx-legacy; scenario is "$I" "$P" "$I/Binaries/AlienBreed3Descent.exe" "$isstub")
check "installscript: HasRunKey set but payload missing is reported" has_text "$T/is.log" "autofix: installscript: UE3Redist: HasRunKey is set but physx is missing, treating it as not installed"
check "installscript: physx verb requested" has_line "$T/is.log" "np_verb physx"
check "installscript: vcrun2005 verb requested" has_line "$T/is.log" "np_verb vcrun2005"
check "installscript: optional d3dx9 not installed by default" sh -c '! grep -q "^np_verb d3dx9" "$1"' x "$T/is.log"
check "installscript: optional verb logged" has_text "$T/is.log" "optional d3dx9 not installed (NOTPROTON_AUTOFIX_REDIST=all installs it)"
check "installscript: satisfied vcredist marked in Wow6432Node" has_line "$T/wine.calls" "reg add HKLM\\Software\\Wow6432Node\\Team17 Software Ltd.\\AlienBreed /v vcredist /t REG_DWORD /d 1 /f"
(export NOTPROTON_AUTOFIX_REDIST=all NOTPROTON_AUTOFIX_DISABLE=physx-legacy; scenario isall "$I" "$P" "$I/Binaries/AlienBreed3Descent.exe" "$isstub")
check "installscript: NOTPROTON_AUTOFIX_REDIST=all installs d3dx9" has_line "$T/isall.log" "np_verb d3dx9"

# ---- 6. verbs (file:// downloads, fake loader) ----------------------------------------------
V="$T/verbs"
mkdir -p "$V/src/openal-soft-9.9-bin/bin/Win32" "$V/src/openal-soft-9.9-bin/bin/Win64"
cp "$B/soft32.dll" "$V/src/openal-soft-9.9-bin/bin/Win32/soft_oal.dll"
cp "$B/soft64.dll" "$V/src/openal-soft-9.9-bin/bin/Win64/soft_oal.dll"
(cd "$V/src" && zip -qr ../oal.zip openal-soft-9.9-bin)
printf 'MZinstaller' > "$V/setup.exe"
printf 'MZ native d3dx9_43' > "$B/d3dx9_43.dll"
"$PY" -I "$here/mkcab.py" "$V/inner_x86.cab" "d3dx9_43.dll=$B/d3dx9_43.dll"
"$PY" -I "$here/mkcab.py" "$V/redist.cab" "Jun2010_d3dx9_43_x86.cab=$V/inner_x86.cab"
cat "$B/game32.exe" "$V/redist.cab" > "$V/redist_sfx.exe"
# NVI2 package (NVIDIA installer) inside a 7-Zip SFX: stub + 7z archive
NV="$T/nvi"
mkdir -p "$NV/Pkg/files/Common" "$NV/Pkg/files/Engine/v2.8.3"
printf 'MZ loader32' > "$NV/Pkg/files/Common/Loader.dll"
printf 'MZ loader64' > "$NV/Pkg/files/Common/Loader64.dll"
printf 'MZ core' > "$NV/Pkg/files/Engine/v2.8.3/Core.dll"
printf 'MZ cooking' > "$NV/Pkg/files/Engine/v2.8.3/NxCooking.dll"
cat > "$NV/Pkg/Pkg.nvi.in" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<nvi name="Display.Pkg" version="${{version}}">
    <filter name="amd64" platform="amd64" />
  <strings>
    <string name="version" value="1.2.3" />
    <string name="VendorKey" value="HKEY_LOCAL_MACHINE\SOFTWARE\Vendor"/>
    <localized locale="0x0409">
      <string name="title" value="Pkg" />
    </localized>
  </strings>
  <properties>
    <string name="InstallLocation" value="${{ProgramFilesX86}}\Pkg" />
  </properties>
  <phases>
    <!--standard phase="ignored" platform="x86">
      <copyFile target="${{InstallLocation}}\ignored.dll" source="files\ignored.dll"/>
    </standard-->
    <standard phase="copyFiles" platform="x86">
      <if filter="amd64">
        <copyFile target="${{InstallLocation}}\Common\Loader64.dll" source="files\Common\Loader64.dll"/>
      </if>
      <copyFile target="${{InstallLocation}}\Common\Loader.dll" source="files\Common\Loader.dll"/>
      <copyFile target="${{InstallLocation}}\Engine\v2.8.3\Core.dll" source="files\Engine\v2.8.3\Core.dll"/>
      <copyFile target="${{InstallLocation}}\Engine\v2.8.3\Cooking.dll" source="files\Engine\v2.8.3\NxCooking.dll"/>
    </standard>
    <standard phase="addRegistries" platform="x86">
      <addRegistry keyName="${{VendorKey}}" />
      <addRegistry keyName="${{VendorKey}}" valueName="Core Path" type="REG_SZ" value="${{InstallLocation}}\Engine" />
      <addRegistry keyName="${{VendorKey}}" valueName="Version" type="REG_DWORD" value="9231019" />
      <addRegistry keyName="${{VendorKey}}\Quiet" valueName="" type="REG_SZ" value=""/>
      <addRegistry keyName="${{VendorKey}}\Table" valueName="Libs" type="REG_MULTI_SZ" value="a.dll|b.dll" split="|" />
    </standard>
    <standard phase="addRegistries64" platform="amd64">
      <addRegistry keyName="${{VendorKey}}" valueName="Build" type="REG_DWORD" value="1" />
    </standard>
    <standard phase="AddEnvSettings">
      <addPath position="last" target="${{InstallLocation}}\Common" />
    </standard>
  </phases>
</nvi>
EOF
# UTF-8 BOM, as NVIDIA ships it
{ printf '\357\273\277'; cat "$NV/Pkg/Pkg.nvi.in"; } > "$NV/Pkg/Pkg.nvi" && rm -f "$NV/Pkg/Pkg.nvi.in"
(cd "$NV" && bsdtar --format 7zip -cf "$NV/pkg.7z" Pkg) || exit 2
cat "$B/game32.exe" "$NV/pkg.7z" > "$NV/pkg_sfx.exe"
nv_off=$(stat -f %z "$B/game32.exe")
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { stat -f %z "$1"; }
cat > "$V/verbs.json" <<EOF
{"schema": 1, "verbs": {
  "oal": {"title": "test zip", "prefix": false,
    "files": [{"url": "file://$V/oal.zip", "sha256": "$(sha "$V/oal.zip")", "size": $(size "$V/oal.zip"), "cache": "oal/oal.zip"}],
    "installed": [{"cache": "oal-9.9/Win32/soft_oal.dll"}, {"cache": "oal-9.9/Win64/soft_oal.dll"}],
    "steps": [{"type": "zip_extract", "file": 0, "dest": "oal-9.9", "map": [
      {"member": "*/Win32/soft_oal.dll", "to": "Win32/soft_oal.dll", "sha256": "$(sha "$B/soft32.dll")"},
      {"member": "*/Win64/soft_oal.dll", "to": "Win64/soft_oal.dll"}]}]},
  "badhash": {"title": "wrong pin",
    "files": [{"url": "file://$V/setup.exe", "sha256": "$(printf '0%.0s' $(seq 1 64))", "size": $(size "$V/setup.exe"), "cache": "bad/setup.exe"}],
    "installed": [{"file": "drive_c/bad.txt"}],
    "steps": [{"type": "exe_silent", "file": 0, "args": ["/s"]}]},
  "nopin": {"title": "unverified", "files": [{"url": "file://$V/setup.exe", "sha256": null, "unverified": true, "size": 1, "cache": "nopin/setup.exe"}],
    "installed": [{"file": "drive_c/nopin.txt"}], "steps": [{"type": "exe_silent", "file": 0}]},
  "inst": {"title": "exe installer",
    "files": [{"url": "file://$V/setup.exe", "sha256": "$(sha "$V/setup.exe")", "size": $(size "$V/setup.exe"), "cache": "inst/setup.exe"}],
    "installed": [{"any": [{"file": "drive_c/nothere.txt"}, {"find": "drive_c/Program Files (x86)/Vendor", "name": "payload.dll", "maxdepth": 3}]}],
    "steps": [{"type": "dll_override", "mode": "native,builtin", "dlls": ["a", "b"]}, {"type": "exe_silent", "file": 0, "args": ["/s", "/v/qn"], "env": ["FOO=bar"]}]},
  "instalias": {"title": "alias", "alias": "inst"},
  "nvi": {"title": "NVI2 package",
    "files": [{"url": "file://$NV/pkg_sfx.exe", "sha256": "$(sha "$NV/pkg_sfx.exe")", "size": $(size "$NV/pkg_sfx.exe"), "cache": "nvi/pkg_sfx.exe"}],
    "installed": [{"find": "drive_c/Program Files (x86)/Pkg", "name": "Core.dll", "maxdepth": 4}],
    "steps": [{"type": "nvi", "file": 0, "sfx_offset": $nv_off, "manifest": "Pkg/Pkg.nvi",
      "vars": ["ProgramFilesX86=C:\\\\Program Files (x86)"]}]},
  "nvibad": {"title": "NVI2 package, unresolved variable",
    "files": [{"url": "file://$NV/pkg_sfx.exe", "sha256": "$(sha "$NV/pkg_sfx.exe")", "size": $(size "$NV/pkg_sfx.exe"), "cache": "nvi/pkg_sfx.exe"}],
    "installed": [{"file": "drive_c/nvibad.txt"}],
    "steps": [{"type": "nvi", "file": 0, "sfx_offset": $nv_off, "manifest": "Pkg/Pkg.nvi"}]},
  "dx": {"title": "nested cab",
    "files": [{"url": "file://$V/redist_sfx.exe", "sha256": "$(sha "$V/redist_sfx.exe")", "size": $(size "$V/redist_sfx.exe"), "cache": "dx/redist_sfx.exe"}],
    "installed": [{"file": "drive_c/windows/syswow64/d3dx9_43.dll", "native": true}],
    "steps": [{"type": "extract_dll_to", "file": 0, "outer": "*d3dx9*x86*.cab", "member": "d3dx9*.dll", "dest": "syswow64"}]}
}}
EOF
P="$T/pfx-verbs"
new_prefix "$P"
vrun() { # vrun LOGNAME VERB [env...]: prints the status into the log
  vr_log="$T/$1.log"
  vr_verb=$2
  shift 2
  env NP_VERBS_JSON="$V/verbs.json" NP_CURL_PROTO='=file' WINEPREFIX="$P" log="$vr_log" "$@" \
    "$SH" -e -c '. "$AUTOFIX_DIR/autofix.sh"; st=0; np_verb "$1" || st=$?; echo "status=$st" >> "$log"' x "$vr_verb" || true
}
vrun v-oal oal
check "verbs: pinned zip downloaded and extracted into the cache" cmp -s "$cache/oal-9.9/Win32/soft_oal.dll" "$B/soft32.dll"
check "verbs: Win64 member extracted" cmp -s "$cache/oal-9.9/Win64/soft_oal.dll" "$B/soft64.dll"
check "verbs: no .part left behind" test ! -e "$cache/oal/oal.zip.part"
check "verbs: status 0" has_line "$T/v-oal.log" "status=0"
vrun v-oal2 oal
check "verbs: second call is a no-op" has_text "$T/v-oal2.log" "autofix: verb oal: already installed"
vrun v-bad badhash
check "verbs: sha256 mismatch refused" has_text "$T/v-bad.log" "sha256 mismatch"
check "verbs: mismatching file not kept" test ! -e "$cache/bad/setup.exe"
check "verbs: mismatching .part removed" test ! -e "$cache/bad/setup.exe.part"
vrun v-nopin nopin
check "verbs: unpinned file refused with status 3" has_line "$T/v-nopin.log" "status=3"
check "verbs: unpinned file never downloaded" test ! -e "$cache/nopin"
: > "$T/wine.calls"
vrun v-inst instalias FAKE_WINE_CREATE="drive_c/Program Files (x86)/Vendor/Thing/payload.dll"
check "verbs: alias resolved" has_text "$T/v-inst.log" "autofix: verb instalias: served by inst"
check "verbs: installer run with its arguments" has_line "$T/wine.calls" "setup.exe /s /v/qn"
check "verbs: DLL overrides applied through one regedit call" has_line "$T/wine.calls" "regedit /S overrides.reg"
check "verbs: installed after the run" has_line "$T/v-inst.log" "status=0"
check "verbs: marker written" test -f "$P/notproton-verbs/inst"
: > "$T/wine.calls"
vrun v-inst2 inst
check "verbs: installed verb not re-run" test ! -s "$T/wine.calls"
rm -rf "$P/drive_c/Program Files (x86)/Vendor"
vrun v-inst3 inst
check "verbs: ran before but files gone -> not retried every launch" has_line "$T/v-inst3.log" "status=1"
check "verbs: no installer call on the refused retry" test ! -s "$T/wine.calls"
vrun v-inst4 inst NP_VERB_FORCE=1 FAKE_WINE_CREATE="drive_c/Program Files (x86)/Vendor/payload.dll"
check "verbs: NP_VERB_FORCE=1 retries" has_line "$T/v-inst4.log" "status=0"
rm -f "$P/notproton-verbs/inst"
rm -rf "$P/drive_c/Program Files (x86)/Vendor"
vrun v-instfail inst FAKE_WINE_RC=1
check "verbs: failing installer reported" has_line "$T/v-instfail.log" "status=1"
rm -f "$P/notproton-verbs/inst"
vrun v-insthang inst FAKE_WINE_SLEEP=5 NP_VERB_TIMEOUT=1
check "verbs: hanging installer stopped after NP_VERB_TIMEOUT" has_text "$T/v-insthang.log" "setup.exe timed out after 1s"
check "verbs: hanging installer reported as failed" has_line "$T/v-insthang.log" "status=1"
printf 'MZ fake\0Wine builtin DLL\0' > "$P/drive_c/windows/syswow64/d3dx9_43.dll"
vrun v-dx dx
check "verbs: Wine builtin placeholder does not count as installed" has_text "$T/v-dx.log" "autofix: verb dx: installed d3dx9_43.dll into syswow64"
check "verbs: nested cab in a self-extracting exe extracted" cmp -s "$P/drive_c/windows/syswow64/d3dx9_43.dll" "$B/d3dx9_43.dll"
: > "$T/wine.calls"
vrun v-nvi nvi FAKE_WINE_SAVE="$T/nvi.reg" FAKE_WINE_PATH='%SystemRoot%\system32;%SystemRoot%'
pf="$P/drive_c/Program Files (x86)/Pkg"
check "verbs: nvi installed" has_line "$T/v-nvi.log" "status=0"
check "verbs: nvi logged" has_text "$T/v-nvi.log" "autofix: verb nvi: installed 4 files and 6 registry entries from Pkg/Pkg.nvi without running its setup.exe"
check "verbs: nvi copyFile with a renamed source" cmp -s "$pf/Engine/v2.8.3/Cooking.dll" "$NV/Pkg/files/Engine/v2.8.3/NxCooking.dll"
check "verbs: nvi amd64 block copied" cmp -s "$pf/Common/Loader64.dll" "$NV/Pkg/files/Common/Loader64.dll"
check "verbs: nvi commented-out phase skipped" test ! -e "$pf/ignored.dll"
check "verbs: nvi setup.exe never run" sh -c '! grep -qi "setup.exe\|pkg_sfx" "$1"' x "$T/wine.calls"
check "verbs: nvi one regedit call" has_line "$T/wine.calls" "regedit /S nvi.reg"
check "verbs: nvi .reg is REGEDIT4" test "$(head -1 "$T/nvi.reg")" = REGEDIT4
check "verbs: nvi x86 phase -> Wow6432Node" has_line "$T/nvi.reg" '[HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Vendor]'
check "verbs: nvi amd64 phase -> 64-bit view" has_line "$T/nvi.reg" '[HKEY_LOCAL_MACHINE\SOFTWARE\Vendor]'
check "verbs: nvi REG_SZ with variables" has_line "$T/nvi.reg" '"Core Path"="C:\\Program Files (x86)\\Pkg\\Engine"'
check "verbs: nvi REG_DWORD in hex" has_line "$T/nvi.reg" '"Version"=dword:008cdaab'
check "verbs: nvi default value" has_line "$T/nvi.reg" '@=""'
check "verbs: nvi REG_MULTI_SZ split on |" has_line "$T/nvi.reg" '"Libs"=hex(7):61,2e,64,6c,6c,00,62,2e,64,6c,6c,00,00'
check "verbs: nvi addPath appended to the prefix PATH" has_line "$T/nvi.reg" "\"PATH\"=hex(2):$(printf '%s' '%SystemRoot%\system32;%SystemRoot%;C:\Program Files (x86)\Pkg\Common' | od -A n -t x1 | tr -s ' \n' ',' | sed 's/^,//; s/,$//'),00"
check "verbs: nvi PATH read through reg query" has_text "$T/wine.calls" "reg query HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Environment /v PATH"
rm -rf "$P/drive_c/Program Files (x86)/Pkg" "$P/notproton-verbs/nvi"
vrun v-nvinopath nvi FAKE_WINE_SAVE="$T/nvi2.reg"
check "verbs: nvi unreadable PATH left alone" sh -c '! grep -q PATH "$1"' x "$T/nvi2.reg"
check "verbs: nvi unreadable PATH noted" has_text "$T/v-nvinopath.log" "cannot read the prefix PATH, leaving it alone"
vrun v-nvibad nvibad
check "verbs: nvi unresolved variable refused" has_line "$T/v-nvibad.log" "status=1"
check "verbs: nvi unresolved variable named" has_text "$T/v-nvibad.log" "unresolved: ProgramFilesX86"
check "verbs: failed step leaves a marker" grep -q failed "$P/notproton-verbs/nvibad"
vrun v-nvibad2 nvibad
check "verbs: failed verb not retried on the next launch" has_text "$T/v-nvibad2.log" "ran before"
vrun v-unknown nosuchverb
check "verbs: unknown verb -> status 2" has_line "$T/v-unknown.log" "status=2"

# the real table: valid, pinned or explicitly unverified, refusal works offline
check "verbs.json: valid JSON, aliases resolve, pins are 64-hex or null+unverified" "$PY" -I -c '
import json, re, sys
d = json.load(open(sys.argv[1]))["verbs"]
for name, v in d.items():
    if "alias" in v:
        assert v["alias"] in d and "alias" not in d[v["alias"]], name
        continue
    assert v["files"] and v["steps"] and v["installed"], name
    for f in v["files"]:
        assert f["url"].startswith("https://"), name
        assert isinstance(f["size"], int) and f["size"] > 0, name
        if f["sha256"] is None:
            assert f.get("unverified") is True, name
        else:
            assert re.fullmatch("[0-9a-f]{64}", f["sha256"]) and not f.get("unverified"), name
    for r in v.get("requires", []):
        assert r in d, name
' "$AF/verbs.json"
check "verbs.json: plutil reads it" plutil -extract verbs.physx.files.0.sha256 raw -o - "$AF/verbs.json"
P="$T/pfx-real"
new_prefix "$P"
env WINEPREFIX="$P" log="$T/v-d3dc47.log" "$SH" -e -c '. "$AUTOFIX_DIR/autofix.sh"; st=0; np_verb d3dcompiler_47 || st=$?; echo "status=$st" >> "$log"' || true
check "verbs.json: unverified d3dcompiler_47 refuses to run" has_line "$T/v-d3dc47.log" "status=3"
check "verbs.json: nothing downloaded for d3dcompiler_47" test ! -e "$cache/d3dcompiler_47"

# ---- 7. helpers: argv changes ---------------------------------------------------------------
H="$T/games/argv"
mkdir -p "$H/launcher" "$H/Binaries/Win64"
: > "$H/launcher/Launcher.exe"
: > "$H/Binaries/Win64/Game Shipping.exe"
out=$(log=/dev/null "$SH" -e -c '
  . "$AUTOFIX_DIR/helpers.sh"
  replace_exe "LAUNCHER/launcher.exe" "Binaries/Win64/Game Shipping.exe"
  append_arg "-dx11"
  append_arg "it'"'"'s two words"
  eval "set -- $(autofix_argv "$@")"
  for a in "$@"; do printf "[%s]" "$a"; done' x "$H/launcher/Launcher.exe" "-arg with space")
check "helpers: replace_exe + append_arg with quoting" test "$out" = "[$H/Binaries/Win64/Game Shipping.exe][-arg with space][-dx11][it's two words]"
out=$(log=/dev/null "$SH" -e -c '
  . "$AUTOFIX_DIR/helpers.sh"
  replace_exe "Launcher.exe" "missing.exe"
  eval "set -- $(autofix_argv "$@")"
  printf "%s" "$1"' x "$H/launcher/Launcher.exe")
check "helpers: missing replacement target keeps the original exe" test "$out" = "$H/launcher/Launcher.exe"

# ---- 8. umu translation on fixtures ---------------------------------------------------------
U="$T/umu-out"
"$PY" -I "$repo/tools/umu2np.py" --out "$U" --commit 0123456789abcdef --report "$T/umu.json" "$fixtures/umu" > "$T/umu.txt" 2>&1
check "umu2np: summary counts" has_line "$T/umu.txt" "umu2np: 6 files: full 2, partial 1, skipped 2, error 1"
f="$U/900001.sh"
check "umu2np: header names source, commit, licence" sh -c 'grep -q "^# Source: https://github.com/Open-Wine-Components/umu-protonfixes/blob/0123456789abcdef/gamefixes-steam/900001.py" "$1" && grep -q "BSD-2-Clause" "$1" && grep -q "NOTICE.umu-protonfixes" "$1"' x "$f"
check "umu2np: protontricks known verb -> np_verb" has_line "$f" "np_verb vcrun2019"
check "umu2np: unsupported verb commented" has_line "$f" "# TODO(umu): unsupported verb directplay (not in autofix/verbs.json)"
check "umu2np: winver verb -> set_reg" has_line "$f" "set_reg 'HKCU\\Software\\Wine' Version REG_SZ win7  # protontricks win7"
check "umu2np: set_environment -> set_env" has_line "$f" "set_env WINE_DISABLE_SFN 1"
check "umu2np: Linux env -> n/a comment" has_line "$f" "# n/a: set_env PULSE_LATENCY_MSEC 90 - Linux/Proton-only"
check "umu2np: OverrideOrder.NATIVE -> native" has_line "$f" "dll_override xaudio2_7 native"
check "umu2np: OverrideOrder.NATIVE_BUILTIN" has_line "$f" "dll_override dinput8 native,builtin"
check "umu2np: OverrideOrder.DISABLED -> ''" has_line "$f" "dll_override nvapi ''"
check "umu2np: wineexe_override" has_line "$f" "dll_override crashreporter.exe ''"
check "umu2np: regedit_add via module constant + quoting" has_line "$f" "set_reg 'HKCU\\Software\\Vendor\\Game' Name REG_SZ 'It'\\''s here'"
check "umu2np: regedit_add with key only -> n/a" has_text "$f" "# n/a: regedit_add 'HKLM\\Software\\Wow6432Node\\Vendor'"
check "umu2np: append_argument -> append_arg" has_line "$f" "append_arg -dx11"
check "umu2np: replace_command literal -> replace_exe" has_line "$f" "replace_exe Launcher.exe Binaries/Win64/Game-Win64-Shipping.exe"
check "umu2np: replace_command regex -> TODO" has_text "$f" "# TODO(umu): replace_command '-launcher\\s+' '' - regex/flags not representable"
check "umu2np: esync -> n/a" has_text "$f" "# n/a: util.disable_esync()"
check "umu2np: EAC -> n/a" has_text "$f" "# n/a: util.install_eac_runtime()"
check "umu2np: set_ini_options USER -> edit_file + TODO" has_line "$f" "edit_file Documents/Vendor/Game/config.ini Volume 80"
check "umu2np: set_ini_options GAME -> TODO" has_text "$f" "# TODO(umu): set_ini_options on settings.ini in the game folder"
check "umu2np: if-block kept as TODO comment" has_text "$f" "# TODO(umu): if not translated: if os.path.exists('modorganizer2'):"
check "umu2np: local helper call kept as TODO" has_text "$f" "# TODO(umu): local helper set_resolution() not translated"
check "umu2np: full translation file" has_text "$U/900002.sh" "# Translation: full (mapped 4, todo 0, n/a 0)"
check "umu2np: n/a-only fix writes no file" test ! -e "$U/900003.sh"
check "umu2np: syntax error reported, no file" sh -c 'test ! -e "$1/900004.sh" && grep -q "syntax error" "$2"' x "$U" "$T/umu.json"
check "umu2np: symlinked fix noted" has_text "$U/900005.sh" "# Upstream file is a symlink to 900002.py"
check "umu2np: conditional-only fix skipped" test ! -e "$U/900006.sh"
check "umu2np: every generated file parses as sh" sh -c 'for f in "$1"/*.sh; do sh -n "$f" || exit 1; done' x "$U"
# run a generated fix with the helpers: argv and env effects
out=$(cd "$H" && log=/dev/null WINEPREFIX="$T/pfx-gl" "$SH" -e -c '
  fix_env=""
  . "$AUTOFIX_DIR/helpers.sh"
  np_verb() { :; }
  . "$1"
  shift
  eval "set -- $(autofix_argv "$@")"
  printf "%s|%s|%s" "$OPENSSL_ia32cap" "$fix_env" "$*"' x "$U/900002.sh" "$H/launcher/Launcher.exe")
check "umu2np: generated fix runs (env, fix_env, argv)" test "$out" = ":~0x20000000| OPENSSL_ia32cap|$H/launcher/Launcher.exe -NoStartup"

# ---- 8b. ue-audio + fex-x87 -----------------------------------------------------------------
UE="$T/games/ue5"
mkdir -p "$UE/My Game/Binaries/Win64"
cp "$B/game32.exe" "$UE/MyGame.exe"
cp "$B/game32.exe" "$UE/My Game/Binaries/Win64/My Game-Win64-Shipping.exe"
PU="$T/pfx-ue"
new_prefix "$PU"
: > "$WINE_CALLS"
scenario ueoff "$UE" "$PU" "$UE/MyGame.exe"
check "ue-audio: off by default, no reg call" test ! -s "$WINE_CALLS"
check "ue-audio: off by default, no marker" test ! -e "$PU/notproton-ue-audio"
(export NOTPROTON_UE_AUDIO_BUFFERS=4; scenario ueon "$UE" "$PU" "$UE/MyGame.exe")
check "ue-audio: CommandLineAppend set for the shipping exe" has_line "$WINE_CALLS" 'reg add HKCU\Software\Wine\AppDefaults\My Game-Win64-Shipping.exe /v CommandLineAppend /t REG_SZ /d -AudioNumBuffersToEnqueue=4 /f'
check "ue-audio: marker records it" has_line "$PU/notproton-ue-audio" "4 My Game-Win64-Shipping.exe"
check "ue-audio: logged" has_text "$T/ueon.log" "autofix: ue-audio: My Game-Win64-Shipping.exe gets -AudioNumBuffersToEnqueue=4"
: > "$WINE_CALLS"
(export NOTPROTON_UE_AUDIO_BUFFERS=4; scenario ueagain "$UE" "$PU" "$UE/MyGame.exe")
check "ue-audio: same value again, no reg call" test ! -s "$WINE_CALLS"
(export NOTPROTON_UE_AUDIO_BUFFERS=6; scenario ue6 "$UE" "$PU" "$UE/MyGame.exe")
check "ue-audio: new value replaces the old one" has_line "$PU/notproton-ue-audio" "6 My Game-Win64-Shipping.exe"
: > "$WINE_CALLS"
scenario uedrop "$UE" "$PU" "$UE/MyGame.exe"
check "ue-audio: unset removes the value" has_line "$WINE_CALLS" 'reg delete HKCU\Software\Wine\AppDefaults\My Game-Win64-Shipping.exe /v CommandLineAppend /f'
check "ue-audio: unset removes the marker" test ! -e "$PU/notproton-ue-audio"
(export NOTPROTON_UE_AUDIO_BUFFERS=lots; scenario uebad "$UE" "$PU" "$UE/MyGame.exe")
check "ue-audio: non-number ignored" has_text "$T/uebad.log" "NOTPROTON_UE_AUDIO_BUFFERS=lots is not a number, ignored"
(export NOTPROTON_UE_AUDIO_BUFFERS=4; scenario uenon "$G" "$PU" "$G/bin/Game.exe")
check "ue-audio: non-UE game left alone" has_text "$T/uenon.log" "autofix: ue-audio: no *-Win64-Shipping.exe, not Unreal Engine 4/5"

scenario fexoff "$G" "$P" "$G/bin/Game.exe"
check "fex-x87: off by default" sh -c '! grep -q FEX_X87 "$1"' x "$T/fexoff.log"
(export NOTPROTON_FEX_X87_REDUCED=1 wine_unix=/r/lib/wine/aarch64-unix; scenario fexon "$G" "$P" "$G/bin/Game.exe")
check "fex-x87: forwarded through fix_env" has_text "$T/fexon.log" "fix_env= CX_FWD_COMPAT_GL_CTX FEX_X87REDUCEDPRECISION"
check "fex-x87: logged on the FEX runner" has_line "$T/fexon.log" "autofix: fex-x87: set FEX_X87REDUCEDPRECISION=1"
(export NOTPROTON_FEX_X87_REDUCED=1 wine_unix=/r/lib/wine/x86_64-unix; scenario fexros "$G" "$P" "$G/bin/Game.exe")
check "fex-x87: Rosetta runner noted" has_text "$T/fexros.log" "this runner uses Rosetta, so it has no effect"
(export NOTPROTON_FEX_X87_REDUCED=1 FEX_X87REDUCEDPRECISION=0; scenario fexpre "$G" "$P" "$G/bin/Game.exe")
check "fex-x87: user value wins" has_text "$T/fexpre.log" "FEX_X87REDUCEDPRECISION=0 already set, left alone"

# ---- 9. lint --------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck -S warning: autofix/*.sh, samples, tests, generated" \
    sh -c 'cd "$1" && shellcheck -S warning -x autofix/*.sh autofix/samples/*.sh tests/autofix/run-tests.sh "$2"/*.sh' x "$repo" "$U"
else
  bad "shellcheck not installed"
fi
check "python files compile" "$PY" -I -c '
import ast, sys
for p in sys.argv[1:]:
    ast.parse(open(p).read(), p)
' "$AF/pe_version.py" "$AF/installscript.py" "$repo/tools/umu2np.py" "$here/mkcab.py"

echo
echo "passed $pass, failed $failed"
[ "$failed" = 0 ]
