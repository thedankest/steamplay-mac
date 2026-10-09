#!/bin/bash
# Assembles Runner B (ARM64 Wine 11.18 + FEX, no Rosetta) from build/wine-arm64/install and
# build/deps-arm64 into dist/runners/<id>. Runner A's tree is never read or written.
#
#   bin/wineserver-arm64 (bin/wineserver -> it)
#   lib/wine/aarch64-unix/        unix .so files, libarm64ecfex.so, libwow64fex.so
#   lib/wine/aarch64-unix/wine.app/Contents/{Info.plist,MacOS/wine}   the loader bundle (--loader ours)
#   lib/wine/aarch64-unix/wine -> Highball's notarized WineLoader       (--loader highball)
#   lib/wine/{aarch64,i386}-windows/   ARM64X and i386 builtins, xtajit64.dll, xtajit.dll (FEX)
#   lib/*.dylib                   freetype, gnutls, SDL2, MoltenVK, FFmpeg (@rpath ids)
#   share/wine/mono/              wine-mono 11.3.0 MSIs (x86, arm64), as wine-11.18 asks for
#   share/wine/gecko/             wine-gecko 2.47.4 MSIs (x86, x86_64)
#   lib/renderers/dxmt/{aarch64-windows,aarch64-unix,i386-windows}/   DXMT (B2), only when
#                                 scripts/build-dxmt-arm64.sh has filled build/dxmt-arm64/install
#   runner.json                   v2, flat keys
#
# Never D3DMetal (there is no arm64 D3DMetal; the Rosetta runner keeps it). The loader is
# unsigned until scripts/runner-b-sign.sh has run.
#
# Loader (--loader):
#   ours      (default) our wine.app. It only maps low memory once signed with Apple's
#             cross-architecture entitlement (scripts/runner-b-sign.sh), which a free account
#             cannot get.
#   highball  no wine.app; lib/wine/aarch64-unix/wine is a symlink to Highball's notarized loader
#             ($HIGHBALL_LOADER, default /Applications/Highball.app/.../WineLoader.app/.../wine).
#             ntdll falls back to <ntdll dir>/wine when wine.app is absent. Refused unless the
#             bundle passes codesign --verify --strict as Developer ID team B95M7DARU4 and the
#             binary carries com.apple.developer.cross-architecture-support. Highball.app is
#             only read, never changed.
#
# Usage: scripts/assemble-runner-b.sh [--loader ours|highball] [runner-id]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOADER_SOURCE=ours
ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --loader) [ $# -ge 2 ] || { echo "assemble-runner-b: --loader needs ours|highball" >&2; exit 2; }
                  LOADER_SOURCE="$2"; shift 2 ;;
        --loader=*) LOADER_SOURCE="${1#--loader=}"; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
        -*) echo "assemble-runner-b: unknown option $1" >&2; exit 2 ;;
        *) [ -z "$ID" ] || { echo "assemble-runner-b: one runner id only" >&2; exit 2; }
           ID="$1"; shift ;;
    esac
done
ID="${ID:-selfbuilt-wine11.18-arm64-r1}"
OUT="$ROOT/dist/runners/$ID"
B="${RUNNER_B_BUILD:-$ROOT/build/wine-arm64}"
INSTALL="$B/install"
DEPS="$ROOT/build/deps-arm64"
INPUTS="$ROOT/ci/runner-b-inputs.json"
DL="$ROOT/downloads"
LOADER=lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine
SERVER=bin/wineserver-arm64
UNIX_DIR=lib/wine/aarch64-unix
HIGHBALL_TEAM=B95M7DARU4
HIGHBALL_LOADER="${HIGHBALL_LOADER:-/Applications/Highball.app/Contents/Helpers/WineLoader.app/Contents/MacOS/wine}"

die() { echo "assemble-runner-b: $*" >&2; exit 1; }
case "$LOADER_SOURCE" in ours|highball) ;; *) die "--loader must be ours or highball, not '$LOADER_SOURCE'" ;; esac

# Highball's loader: Developer ID, team B95M7DARU4, strict-valid, cross-architecture entitlement.
check_highball_loader() { # binary path
    local bin="$1" bundle
    [ -f "$bin" ] && [ -x "$bin" ] || die "Highball loader not found at $bin (install Highball.app, or set HIGHBALL_LOADER)"
    case "$bin" in */Contents/MacOS/*) bundle="${bin%/Contents/MacOS/*}" ;; *) die "$bin is not inside an app bundle" ;; esac
    [ "$(lipo -archs "$bin")" = arm64 ] || die "$bin is not arm64-only: $(lipo -archs "$bin")"
    codesign --verify --strict "$bundle" || die "$bundle fails codesign --verify --strict"
    # Developer ID Application leaf (…6.1.13) under Apple's Developer ID CA (…6.2.6), team OU.
    codesign --verify --strict -R="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$HIGHBALL_TEAM\"" "$bundle" \
        || die "$bundle is not signed with a Developer ID Application certificate of team $HIGHBALL_TEAM"
    codesign -d --entitlements - --xml "$bin" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null \
        | grep -A1 '<key>com.apple.developer.cross-architecture-support</key>' | grep -q '<true/>' \
        || die "$bin lacks the com.apple.developer.cross-architecture-support entitlement"
    echo "loader: $bin (Developer ID $HIGHBALL_TEAM, cross-architecture entitlement, strict-valid)"
}
case "$ID" in *[!A-Za-z0-9._-]*|'') die "runner id may only use letters, digits, '.', '_' and '-'" ;; esac
pin() { plutil -extract "$1.$2" raw -o - "$INPUTS" 2>/dev/null || true; }
fetch_input() { # key -> downloads/<file>, verified against ci/runner-b-inputs.json
    local sha url file
    sha="$(pin "$1" sha256)"; url="$(pin "$1" url)"; file="$(pin "$1" file)"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$1: sha256 is '$sha' (TODO-PIN); refusing to run"
    mkdir -p "$DL"
    [ -f "$DL/$file" ] || { curl -fSL --retry 3 -o "$DL/$file.part" "$url" && mv "$DL/$file.part" "$DL/$file"; }
    echo "$sha  $DL/$file" | shasum -a 256 -c - >/dev/null || die "sha256 mismatch: $DL/$file"
}

if [ "$LOADER_SOURCE" = highball ]; then
    check_highball_loader "$HIGHBALL_LOADER"
else
    [ -x "$INSTALL/$LOADER" ] || die "no loader at $INSTALL/$LOADER (run scripts/build-wine-arm64.sh)"
fi
[ -x "$INSTALL/$SERVER" ] || die "no $SERVER (run scripts/build-wine-arm64.sh loader)"
[ -f "$INSTALL/lib/wine/aarch64-windows/xtajit64.dll" ] && [ -f "$INSTALL/lib/wine/aarch64-windows/xtajit.dll" ] \
    || die "FEX DLLs missing (run scripts/build-wine-arm64.sh fex)"
[ -f "$INSTALL/$UNIX_DIR/libarm64ecfex.so" ] && [ -f "$INSTALL/$UNIX_DIR/libwow64fex.so" ] \
    || die "FEX unix helpers missing (run scripts/build-wine-arm64.sh fex)"
lipo_check=("$INSTALL/$SERVER" "$INSTALL/$UNIX_DIR/ntdll.so")
[ "$LOADER_SOURCE" = ours ] && lipo_check+=("$INSTALL/$LOADER")
for f in "${lipo_check[@]}"; do
    [ "$(lipo -archs "$f")" = arm64 ] || die "$f is not arm64-only: $(lipo -archs "$f")"
done

case "$OUT" in "$ROOT/dist/runners/"?*) ;; *) die "refusing to write outside dist/runners: $OUT" ;; esac
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$INSTALL/" "$OUT/"
if [ "$LOADER_SOURCE" = highball ]; then
    # No wine.app: ntdll then execs <ntdll dir>/wine, i.e. Highball's entitled loader.
    rm -rf "${OUT:?}/$UNIX_DIR/wine.app"
    ln -s "$HIGHBALL_LOADER" "$OUT/$UNIX_DIR/wine"
    LOADER="$UNIX_DIR/wine"
fi

# --- host libraries -------------------------------------------------------------------------
cp -a "$DEPS"/lib/*.dylib "$OUT/lib/"
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib; do
    [ -e "$OUT/lib/$lib" ] || die "missing $lib"
    lipo "$OUT/lib/$lib" -verify_arch arm64 || die "$lib has no arm64 slice"
done
# Nothing may point into the build machine (deps prefix, Homebrew) or keep a build rpath.
mach=("$OUT"/lib/*.dylib "$OUT/$UNIX_DIR"/*.so "$OUT/$SERVER")
[ "$LOADER_SOURCE" = ours ] && mach+=("$OUT/$LOADER")
if otool -L "${mach[@]}" | grep -E "$DEPS|/opt/homebrew|/usr/local" >&2; then die "absolute build-machine paths left"; fi
if otool -l "${mach[@]}" | grep -E "path ($ROOT|/opt/homebrew|/usr/local)" >&2; then die "build-machine rpaths left"; fi

# --- Mono and Gecko (the versions and MSI hashes wine-11.18's appwiz.cpl asks for) ----------
mkdir -p "$OUT/share/wine/mono" "$OUT/share/wine/gecko"
for k in wine-mono-x86 wine-mono-arm64; do fetch_input "$k"; cp "$DL/$(pin "$k" file)" "$OUT/share/wine/mono/"; done
for k in wine-gecko-x86 wine-gecko-x86_64; do fetch_input "$k"; cp "$DL/$(pin "$k" file)" "$OUT/share/wine/gecko/"; done

# --- licence texts of what we bundle beyond Wine (FEX DLLs and helper: MIT) ----------------
mkdir -p "$OUT/share/doc/fex"
cp "$ROOT/runner-b/fex/LICENSE.FEX" "$OUT/share/doc/fex/LICENSE"
# winemac.so carries patch 0021's dxmt_export.c (GPL-3.0), so it ships under the GPL-3.0.
mkdir -p "$OUT/share/doc/winemac"
cp "$ROOT/LICENSE" "$OUT/share/doc/winemac/LICENSE.GPL-3.0"

# --- DXMT (B2): ARM64X PE + native arm64 winemetal.so, prepended to WINEDLLPATH by the run script
DXMT_INSTALL="${DXMT_BUILD:-$ROOT/build/dxmt-arm64}/install"
renderers="{}"
if [ -f "$DXMT_INSTALL/aarch64-unix/winemetal.so" ]; then
    [ "$(lipo -archs "$DXMT_INSTALL/aarch64-unix/winemetal.so")" = arm64 ] || die "DXMT winemetal.so is not arm64-only"
    codesign --verify "$DXMT_INSTALL/aarch64-unix/winemetal.so" || die "DXMT winemetal.so is not signed (scripts/build-dxmt-arm64.sh make)"
    nm -gU "$OUT/$UNIX_DIR/winemac.so" | grep -q ' _macdrv_functions$' \
        || die "winemac.so lacks macdrv_functions (patch runner-b/0021); DXMT would get no swapchain"
    R="$OUT/lib/renderers/dxmt"
    mkdir -p "$R/aarch64-unix"
    for d in aarch64-windows i386-windows; do
        [ -d "$DXMT_INSTALL/$d" ] || continue
        cp -R "$DXMT_INSTALL/$d" "$R/"
        # winemetal is no Wine DLL: upstream ntdll loads a builtin only when its file exists in
        # system32/syswow64 (outside prefix bootstrap), and wineboot writes that placeholder
        # only for DLLs the runner itself carries. Same as Runner A (assemble-runner.sh).
        cp "$DXMT_INSTALL/$d/winemetal.dll" "$OUT/lib/wine/$d/"
    done
    # The unix half finds winemac.so/ntdll.so through LC_RPATH @loader_path/, so the real file sits
    # next to them and the renderer directory only links to it.
    cp "$DXMT_INSTALL/aarch64-unix/winemetal.so" "$OUT/$UNIX_DIR/"
    ln -s ../../../wine/aarch64-unix/winemetal.so "$R/aarch64-unix/winemetal.so"
    if [ -f "$DXMT_INSTALL/LICENSE.dxmt" ]; then
        mkdir -p "$OUT/share/doc/dxmt"; cp "$DXMT_INSTALL/LICENSE.dxmt" "$OUT/share/doc/dxmt/LICENSE"
    fi
    dxmt_rev="$(head -1 "$DXMT_INSTALL/DXMT_COMMIT" 2>/dev/null | cut -c1-12)"
    renderers="{ \"dxmt\": \"${dxmt_rev:-unknown}\" }"
    echo "DXMT: lib/renderers/dxmt (${dxmt_rev:-unknown})"
fi

# --- never D3DMetal or Apple/Valve binaries -------------------------------------------------
if find "$OUT" \( -iname 'D3DMetal*' -o -iname 'libd3dshared*' -o -iname 'nvngx*' -o -iname '*gptk*' \
        -o -iname 'steamclient.dll' -o -iname 'steamclient64.dll' -o -iname 'tier0_s64.dll' \
        -o -iname 'vstdlib_s64.dll' -o -iname 'GameOverlayRenderer64.dll' \) | grep . >&2; then
    die "forbidden file in the runner tree"
fi
[ ! -e "$OUT/lib/external" ] && [ ! -e "$OUT/lib/renderers/d3dmetal" ] || die "D3DMetal directories present"

# --- manifest (v2, flat keys; "kind": "selfbuilt" on one line like Runner A's, which
#     compat_run.sh and install.sh grep for) --------------------------------------------------
wine_version="$(sed -n 's/^#define PACKAGE_VERSION "\(.*\)"/\1/p' "$B/obj/include/config.h" 2>/dev/null || true)"
patches="$(cat "$ROOT/patches/runner-b/series" "$ROOT"/patches/highball/0003-*.patch "$ROOT"/patches/highball-arm64/*.patch \
    "$ROOT"/patches/runner-b/*.patch | shasum -a 256 | cut -c1-12)"
cat > "$OUT/runner.json" <<EOF
{
  "id": "$ID",
  "kind": "selfbuilt",
  "arch": "arm64",
  "flavour": "fex",
  "wine": "wine-${wine_version:-unknown}",
  "base": "upstream wine-11.18 + patches/runner-b/series",
  "patches": "$patches",
  "fex": "Hangover 11.16 DLLs (FEX 2608) + fexunixlib_darwin (0001 kr trace, 0002 TSO on every thread)",
  "loader": "$LOADER",
  "loader_source": "$LOADER_SOURCE",
  "server": "$SERVER",
  "unix_dir": "$UNIX_DIR",
  "prefix_machine": "aa64",
  "d3dmetal": false,
  "renderers": $renderers,
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
jq . "$OUT/runner.json" >/dev/null || die "runner.json is not valid JSON"
du -sh "$OUT"
echo "runner: $OUT"
if [ "$LOADER_SOURCE" = highball ]; then
    echo "loader: Highball's ($HIGHBALL_LOADER); nothing to sign"
else
    echo "next: scripts/runner-b-sign.sh --runner $OUT   (the loader does not start unsigned)"
fi
