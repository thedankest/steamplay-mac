#!/bin/bash
# Adds D3DMetal (Apple's Game Porting Toolkit) to an assembled runner. Apple's licence allows
# personal, non-commercial use on Apple hardware, so D3DMetal is never committed or put in a CI
# tarball: it comes from a pinned source on the user's Mac and is installed only after the user
# accepted Apple's licence.
#
# Usage: scripts/install-d3dmetal.sh [--gptk-dmg PATH] <runner-dir>
#
# Sources (each pinned by SHA-256):
#   default        GPTK 3.0 as Gcenx's repack (game-porting-toolkit-3.0-3.tar.xz, downloaded).
#                  It carries no Apple licence text at all.
#   --gptk-dmg     GPTK 4.0 beta 2 from Apple (developer.apple.com): the outer
#                  Game_Porting_Toolkit_4.0_beta_2.dmg or the "Evaluation environment for Windows
#                  games 4.0 beta 2.dmg" inside it (also D3DMETAL_GPTK_DMG). D3DMetal 4.0b2 is
#                  x86_64 only. The evaluation image carries Apple's licence agreement as its
#                  disk-image licence (and License.rtf): it is shown, and the image is attached
#                  (read-only, nobrowse, at a temp mount point) only after it was accepted.
#
# Licence acceptance, one of:
#   - on a terminal: the licence is shown (3.0: a note that the archive has none, with Apple's
#     download page) and the user types yes;
#   - D3DMETAL_LICENSE_SHA256=<sha256 of the licence file shown> (a GUI that displayed it);
#   - D3DMETAL_LICENSE_FILE=<file> whose SHA-256 is a known Apple GPTK licence (APPLE_LICENSES);
#   - D3DMETAL_ACCEPT_LICENSE=1: the user has already read and accepted Apple's licence.
# Without one of these and without a terminal it prints a machine-readable line on stderr,
#   license-required <sha256 of the licence file, or -> <path of that file, or Apple's URL>
# and exits 2. Exit 0 installed, 1 error, 2 not accepted.
#
# Writes <runner>/lib/external/D3DMetal.source (source, version, hashes) and
# <runner>/lib/external/D3DMetal.files.sha256 (sha256 of every file it installs), and sets
# runner.json renderers.d3dmetal to the installed version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPTK_DMG="${D3DMETAL_GPTK_DMG:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --gptk-dmg) GPTK_DMG="${2:?--gptk-dmg needs a path}"; shift 2 ;;
        --gptk-dmg=*) GPTK_DMG="${1#*=}"; shift ;;
        --) shift; break ;;
        -*) echo "usage: $0 [--gptk-dmg PATH] <runner-dir>" >&2; exit 1 ;;
        *) break ;;
    esac
done
OUT="${1:?usage: $0 [--gptk-dmg PATH] <runner-dir>}"
DL="${D3DMETAL_CACHE:-$ROOT/downloads}"
URL=https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz
SHA=d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e
TARBALL="$DL/game-porting-toolkit-3.0-3.tar.xz"
APPLE_GPTK_URL='https://developer.apple.com/download/all/?q=game%20porting%20toolkit'

# Known GPTK disk images: "<sha256> <outer|eval> <d3dmetal version>".
DMG_KNOWN="03893ac4fab94ad9ff6aa32e887e2854bbf40fd90796f78a1d9bdbc02526ee5b outer 4.0b2
6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1 eval 4.0b2"
# Known Apple licence texts: the Game Porting Toolkit agreement (EA18380) as shipped in the
# GPTK 4.0 beta 2 evaluation image (its disk-image licence and License.rtf are identical).
APPLE_LICENSES="5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
die() { echo "$*" >&2; exit 1; }
[ "$(id -u)" != 0 ] || die "do not run install-d3dmetal.sh as root"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"     # np_test_root_ok (test mode only)
if [ "${NP_TEST_MODE:-0}" = 1 ]; then
    # Test only: extra entries for fake images and licences; the runner must be in the test root,
    # and the test root strictly inside the user's temp dir or /private/tmp.
    root="$(cd -P "${NP_TEST_ROOT:?test mode needs NP_TEST_ROOT}" && pwd -P)"
    np_test_root_ok "$root" || die "test mode: NP_TEST_ROOT must be a subdirectory of a temp dir, not $root"
    case "$(cd -P "$OUT" && pwd -P)/" in "$root"/*) ;; *) die "test mode: $OUT is outside NP_TEST_ROOT" ;; esac
    [ -n "${NP_TEST_GPTK_DMG_KNOWN:-}" ] && DMG_KNOWN="$DMG_KNOWN
$NP_TEST_GPTK_DMG_KNOWN"
    APPLE_LICENSES="$APPLE_LICENSES ${NP_TEST_APPLE_LICENSES:-}"
fi

sha_of() { shasum -a 256 "$1" | cut -c1-64; }
known_license() { case " $APPLE_LICENSES " in *" $1 "*) return 0 ;; esac; return 1; }
# Runs a command with a time limit (no coreutils timeout on stock macOS).
limit() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

[ -x "$OUT/bin/wine" ] || die "$OUT is not a runner (no bin/wine)"
mkdir -p "$DL"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/np-d3dmetal.XXXXXX")"
WORK="$(cd -P "$WORK" && pwd -P)"   # mount(8) prints physical paths
MOUNTS=()
# Every mount point is recorded before its attach starts, so an attach killed after it mounted is
# still found; only what is really mounted there is ejected. Innermost first: the evaluation
# image may live on the outer one.
cleanup() {
    local i m
    trap '' INT TERM HUP PIPE
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        m="${MOUNTS[$i]}"
        mount | grep -qF " on $m (" || continue
        diskutil eject "$m" >/dev/null 2>&1 || limit 60 hdiutil detach -force "$m" >/dev/null 2>&1 \
            || echo "could not detach $m" >/dev/null
    done
    rm -rf "$WORK"
} 2>/dev/null
trap cleanup EXIT
trap 'trap "" INT TERM HUP; exit 130' INT TERM HUP
trap '' PIPE

# 0 when the image carries a licence agreement, 1 when it does not; anything else is fatal
# (never "fail open" into treating an image as having no agreement).
has_sla() {
    local info
    info="$(limit 120 hdiutil imageinfo "$1" 2>/dev/null)" || die "cannot read the image info of $1"
    case "$info" in
        *'Software License Agreement: true'*) return 0 ;;
        *'Software License Agreement: false'*) return 1 ;;
        *) die "the image info of $1 does not say whether it has a licence agreement" ;;
    esac
}

# attach_ro <image> <mountpoint> [sla-accepted]: read-only, nobrowse, no auto-open. An image with
# a licence agreement is attached only after accept() returned ("qy": leave the pager, agree).
# accept() is the real gate: hdiutil does not prompt for every agreement (e.g. a synthetic one
# added with udifrez attaches without asking), so the answer piped here must never be what
# decides.
attach_ro() {
    local img="$1" mp="$2"
    mkdir -p "$mp"
    MOUNTS+=("$mp")
    if [ "${3:-0}" = 1 ]; then
        printf 'qy\n' | limit 300 hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mp" "$img" >/dev/null 2>&1 \
            || return 1
    elif ! limit 300 diskutil image attach --readOnly --nobrowse --mountPoint "$mp" "$img" < /dev/null >/dev/null 2>&1; then
        limit 300 hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mp" "$img" < /dev/null >/dev/null 2>&1 || return 1
    fi
}

# The English licence agreement embedded in an image, without attaching (and so without
# accepting) it. udifderez needs a writable file, hence the copy.
sla_extract() { # image out.rtf
    cp "$1" "$WORK/sla-copy.dmg" || return 1
    limit 120 hdiutil udifderez -xml "$WORK/sla-copy.dmg" > "$WORK/resources.xml" 2>/dev/null || return 1
    plutil -extract 'RTF .0.Data' raw -o - "$WORK/resources.xml" 2>/dev/null | base64 -D > "$2" || return 1
    rm -f "$WORK/sla-copy.dmg"
    [ -s "$2" ]
}

# accept <licence file or ""> <tarball|dmg> -> 0 accepted, exits 2 when not.
# A licence that comes with the source (the GPTK disk image) is accepted only by the user: "yes"
# typed after it was shown, D3DMETAL_LICENSE_SHA256 equal to its hash (a GUI showed it), or
# D3DMETAL_LICENSE_FILE with that same, allowlisted text. D3DMETAL_ACCEPT_LICENSE=1 counts only
# for the 3.0 tarball, which carries no licence text to show.
accept() {
    local lic="$1" kind="$2" lsha="" answer fsha
    [ -n "$lic" ] && lsha="$(sha_of "$lic")"
    if [ "${D3DMETAL_ACCEPT_LICENSE:-0}" = 1 ]; then
        if [ "$kind" = dmg ]; then
            echo "D3DMETAL_ACCEPT_LICENSE does not accept the licence of a GPTK disk image; it has to be shown first" >&2
        else
            return 0
        fi
    fi
    if [ -n "$lsha" ] && [ "${D3DMETAL_LICENSE_SHA256:-}" = "$lsha" ]; then return 0; fi
    if [ -n "${D3DMETAL_LICENSE_FILE:-}" ] && [ -f "$D3DMETAL_LICENSE_FILE" ]; then
        fsha="$(sha_of "$D3DMETAL_LICENSE_FILE")"
        if known_license "$fsha" && { [ -z "$lsha" ] || [ "$fsha" = "$lsha" ]; }; then
            LICENSE_COPY_SRC="$D3DMETAL_LICENSE_FILE"
            return 0
        fi
        echo "D3DMETAL_LICENSE_FILE is not the known Apple Game Porting Toolkit licence for this source" >&2
    fi
    if ! [ -t 0 ]; then
        if [ -n "$lic" ]; then
            echo "license-required $lsha $lic" >&2
            echo "D3DMetal licence not accepted: run on a terminal, or set D3DMETAL_LICENSE_SHA256=$lsha after the user read and accepted $lic" >&2
        else
            echo "license-required - $APPLE_GPTK_URL" >&2
            echo "D3DMetal licence not accepted: this archive has no Apple licence text; run on a terminal, or set D3DMETAL_LICENSE_FILE to Apple's GPTK License.rtf" >&2
        fi
        exit 2
    fi
    if [ -n "$lic" ]; then
        textutil -convert txt -output "$WORK/license.txt" "$lic" >/dev/null 2>&1 || cp -f "$lic" "$WORK/license.txt"
        ${PAGER:-less} "$WORK/license.txt" || true
    else
        printf '%s\n' "Apple's licence for D3DMetal is not in this archive (Gcenx's GPTK 3.0 repack)." \
            "Read Apple's Game Porting Toolkit licence first; it comes with the toolkit from:" \
            "  $APPLE_GPTK_URL" \
            "In short: personal, non-commercial use, on Apple hardware only."
    fi
    printf 'Accept Apple'"'"'s Game Porting Toolkit licence (personal, non-commercial, Apple hardware)? [yes/no] '
    read -r answer || answer=""
    [ "$answer" = yes ] || { echo "not accepted; D3DMetal not installed" >&2; exit 2; }
}

LICENSE_COPY_SRC=""
if [ -n "$GPTK_DMG" ]; then
    [ -f "$GPTK_DMG" ] || die "no such disk image: $GPTK_DMG"
    dsha="$(sha_of "$GPTK_DMG")"
    line="$(printf '%s\n' "$DMG_KNOWN" | awk -v s="$dsha" '$1 == s' | head -1)"
    [ -n "$line" ] || die "$GPTK_DMG is not a known Game Porting Toolkit image (sha256 $dsha)"
    read -r _ kind VERSION <<< "$line"
    ARCHIVE_SHA="$dsha"
    SOURCE=dmg
    eval_img="$GPTK_DMG"
    if [ "$kind" = outer ]; then
        has_sla "$GPTK_DMG" && die "the outer image unexpectedly has a licence agreement; attach it by hand"
        attach_ro "$GPTK_DMG" "$WORK/outer" || die "could not attach $GPTK_DMG"
        eval_img=""
        for f in "$WORK/outer"/Evaluation*.dmg; do
            [ -f "$f" ] || continue
            [ -z "$eval_img" ] || die "more than one evaluation image in $GPTK_DMG"
            eval_img="$f"
        done
        [ -n "$eval_img" ] || die "no evaluation image in $GPTK_DMG"
        esha="$(sha_of "$eval_img")"
        printf '%s\n' "$DMG_KNOWN" | awk -v s="$esha" '$1 == s && $2 == "eval"' | grep -q . \
            || die "the evaluation image in $GPTK_DMG is not a known one (sha256 $esha)"
    elif [ "$kind" != eval ]; then
        die "unknown image kind $kind"
    fi
    if has_sla "$eval_img"; then
        sla_extract "$eval_img" "$WORK/License.rtf" || die "could not read the licence agreement of $eval_img"
        lsha="$(sha_of "$WORK/License.rtf")"
        known_license "$lsha" || die "the licence agreement in $eval_img is not a known Apple GPTK licence (sha256 $lsha)"
        cp -f "$WORK/License.rtf" "$DL/gptk-$VERSION-License.rtf"
        accept "$DL/gptk-$VERSION-License.rtf" dmg
        attach_ro "$eval_img" "$WORK/eval" 1 || die "could not attach $eval_img"
        # Test only: killed right after a mount; the EXIT trap must still eject it.
        if [ "${NP_TEST_MODE:-0}" = 1 ] && [ "${NP_TEST_D3D_KILL_AFTER_ATTACH:-0}" = 1 ]; then kill -TERM $$; t=$((SECONDS + 3)); while [ "$SECONDS" -lt "$t" ]; do :; done; fi
    else
        attach_ro "$eval_img" "$WORK/eval" || die "could not attach $eval_img"
        [ -f "$WORK/eval/License.rtf" ] && [ ! -L "$WORK/eval/License.rtf" ] || die "no License.rtf in $eval_img"
        lsha="$(sha_of "$WORK/eval/License.rtf")"
        known_license "$lsha" || die "License.rtf in $eval_img is not a known Apple GPTK licence (sha256 $lsha)"
        cp -f "$WORK/eval/License.rtf" "$DL/gptk-$VERSION-License.rtf"
        accept "$DL/gptk-$VERSION-License.rtf" dmg
    fi
    LICENSE_COPY_SRC="$DL/gptk-$VERSION-License.rtf"
    EXT="$WORK/eval/redist/lib/external"
    WIN="$WORK/eval/redist/lib/wine/x86_64-windows"
else
    VERSION=3.0
    SOURCE=tarball
    ARCHIVE_SHA="$SHA"
    if [ -f "$TARBALL" ] && [ "$(sha_of "$TARBALL")" != "$SHA" ]; then
        echo "cached $TARBALL has the wrong hash; deleting it" >&2
        rm -f "$TARBALL"
    fi
    if [ ! -f "$TARBALL" ]; then
        rm -f "$TARBALL.part"
        curl -fsSL --proto '=https' --proto-redir '=https' -o "$TARBALL.part" "$URL" || { rm -f "$TARBALL.part"; die "download failed: $URL"; }
        [ "$(sha_of "$TARBALL.part")" = "$SHA" ] || { rm -f "$TARBALL.part"; die "GPTK tarball hash mismatch"; }
        mv -f "$TARBALL.part" "$TARBALL"
    fi
    tar -xJf "$TARBALL" -C "$WORK"
    APP="$WORK/Game Porting Toolkit.app/Contents/Resources"
    EXT="$APP/wine/lib/external"
    WIN="$APP/wine/lib/wine/x86_64-windows"
    accept "" tarball
fi

# --- install ---------------------------------------------------------------------------------
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
[ -d "$EXT/D3DMetal.framework" ] && [ ! -L "$EXT/D3DMetal.framework" ] || die "no D3DMetal.framework in the source"
regular "$EXT/libd3dshared.dylib" || die "no libd3dshared.dylib in the source"
DLLS="d3d10 d3d11 d3d12 dxgi nvapi64"
regular "$WIN/atidxx64.dll" && DLLS="$DLLS atidxx64"
for d in $DLLS nvngx-on-metalfx; do regular "$WIN/$d.dll" || die "no $d.dll in the source"; done
# Symlinks inside the framework are copied as symlinks; each must stay inside it.
fw="$(cd -P "$EXT/D3DMetal.framework" && pwd)"
while IFS= read -r -d '' l; do
    t="$(/bin/realpath "$l" 2>/dev/null)" || die "dangling symlink in D3DMetal.framework: $l"
    case "$t/" in "$fw"/*) ;; *) die "symlink leaves D3DMetal.framework: $l -> $(readlink "$l")" ;; esac
done < <(find "$EXT/D3DMetal.framework" -type l -print0)

rm -rf "$OUT/lib/external/D3DMetal.framework" "$OUT/lib/renderers/d3dmetal"
rm -f "$OUT/lib/external/libd3dshared.dylib" "$OUT/lib/external/D3DMetal-License.rtf" \
      "$OUT/lib/external/D3DMetal.source" "$OUT/lib/external/D3DMetal.files.sha256"
mkdir -p "$OUT/lib/external"
cp -RP "$EXT/D3DMetal.framework" "$OUT/lib/external/"
cp -P "$EXT/libd3dshared.dylib" "$OUT/lib/external/"
R="$OUT/lib/renderers/d3dmetal"
mkdir -p "$R/x86_64-windows" "$R/x86_64-unix"
for d in $DLLS; do
    cp "$WIN/$d.dll" "$R/x86_64-windows/$d.dll"
    ln -s ../../../external/libd3dshared.dylib "$R/x86_64-unix/$d.so"
done
# DLSS -> MetalFX: the MetalFX NGX shim takes nvngx's place (as the MacPorts d3dmetal port does)
cp "$WIN/nvngx-on-metalfx.dll" "$R/x86_64-windows/nvngx.dll"
ln -s ../../../external/libd3dshared.dylib "$R/x86_64-unix/nvngx.so"
LICENSE_SHA=none
if [ -n "$LICENSE_COPY_SRC" ]; then
    cp -f "$LICENSE_COPY_SRC" "$OUT/lib/external/D3DMetal-License.rtf"
    LICENSE_SHA="$(sha_of "$OUT/lib/external/D3DMetal-License.rtf")"
fi
printf 'source=%s\nversion=%s\narchive_sha256=%s\nlicense_sha256=%s\n' "$SOURCE" "$VERSION" "$ARCHIVE_SHA" "$LICENSE_SHA" \
    > "$OUT/lib/external/D3DMetal.source"

# renderers.d3dmetal = this version (replaced if present). compat_run.sh recognises a self-built
# runner by the literal text '"kind": "selfbuilt"', so the file keeps its line formatting.
J="$OUT/runner.json"
if [ -f "$J" ]; then
    cp -p "$J" "$WORK/runner.json.bak"
    if grep -q '"d3dmetal"' "$J"; then
        sed -i '' -E 's/"d3dmetal"[[:space:]]*:[[:space:]]*"[^"]*"/"d3dmetal": "'"$VERSION"'"/' "$J"
    elif grep -Eq '"renderers"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' "$J"; then
        sed -i '' -E 's/"renderers"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}/"renderers": { "d3dmetal": "'"$VERSION"'" }/' "$J"
    else
        sed -i '' -E 's/"renderers"[[:space:]]*:[[:space:]]*\{/"renderers": { "d3dmetal": "'"$VERSION"'",/' "$J"
    fi
    if ! jq -e --arg v "$VERSION" '.renderers.d3dmetal == $v' "$J" >/dev/null 2>&1; then
        cp -p "$WORK/runner.json.bak" "$J"
        die "could not set renderers.d3dmetal in $J"
    fi
fi

# SHA-256 of every file installed above, relative to the runner, so install.sh doctor can check
# them later: (cd <runner> && shasum -a 256 -c lib/external/D3DMetal.files.sha256)
SUMS="$OUT/lib/external/D3DMetal.files.sha256"
(
    cd "$OUT"
    {
        find ./lib/external/D3DMetal.framework ./lib/renderers/d3dmetal -type f -print0
        printf '%s\0' ./lib/external/libd3dshared.dylib ./lib/external/D3DMetal.source
        if [ -f ./lib/external/D3DMetal-License.rtf ]; then printf '%s\0' ./lib/external/D3DMetal-License.rtf; fi
    } | LC_ALL=C sort -z | xargs -0 shasum -a 256
) > "$SUMS.new"
mv -f "$SUMS.new" "$SUMS"
echo "D3DMetal file hashes ($(wc -l < "$SUMS" | tr -d ' ') files): $SUMS"
cat "$SUMS"
echo "D3DMetal $VERSION installed into $OUT from the $SOURCE (archive sha256 $ARCHIVE_SHA, licence sha256 $LICENSE_SHA)"
