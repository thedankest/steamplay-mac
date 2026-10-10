#!/bin/bash
# Runner B: builds upstream Wine 11.18 natively for Apple Silicon (arm64 Unix side, ARM64X
# builtins: arm64ec + aarch64, plus i386 for WoW64) with FEX as the x86 emulator, no Rosetta
# (research/RUNNER-B-PLAN.md, B1). Never touches Runner A's paths:
#
#   build/deps-arm64/          host libraries (scripts/build-deps.sh with HOST_ARCH=arm64)
#   build/wine-arm64/src/      wine-11.18 + patches/runner-b/series
#   build/wine-arm64/obj/      out-of-tree build
#   build/wine-arm64/install/  make install-lib, plus FEX, the wine.app loader, wineserver-arm64
#   build/wine-arm64/toolchains/llvm-mingw/   PE compilers (arm64ec, aarch64, i686)
#
# Inputs are pinned by sha256 in ci/runner-b-inputs.json (rule 4); a TODO-PIN refuses the run.
# The loader built here is unsigned: it only starts once scripts/runner-b-sign.sh has signed it
# with the user's provisioning profile (Apple's cross-architecture entitlement).
#
# Usage: scripts/build-wine-arm64.sh [--print-plan] [--reconfigure] [stage ...]
#   stages (default: all, in order): check fetch deps patch configure make fex loader
#   --print-plan   show inputs, pin status, series, configure and link lines; no network, no build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUTS="$ROOT/ci/runner-b-inputs.json"
SERIES="$ROOT/patches/runner-b/series"
DL="$ROOT/downloads"
B="${RUNNER_B_BUILD:-$ROOT/build/wine-arm64}"
DEPS="$ROOT/build/deps-arm64"
OBJ="$B/obj"
INSTALL="$B/install"
TC="$B/toolchains/llvm-mingw"
FEXDLLS="$B/fex-dlls"
JOBS="$(sysctl -n hw.ncpu)"
# Placeholder until signing: runner-b-sign.sh writes the stub's CFBundleIdentifier (the App ID its
# provisioning profile names) into wine.app. Xcode most likely derives this one from the stub.
BUNDLE_ID="${WINELOADER_BUNDLE_ID:-io.github.thedankest.steamplay.WineLoader}"
UNIX="$INSTALL/lib/wine/aarch64-unix"
WIN="$INSTALL/lib/wine/aarch64-windows"
APP="$UNIX/wine.app"

die() { echo "build-wine-arm64: $*" >&2; exit 1; }
log() { printf '\n==== %s\n' "$*"; }

# --- pins -----------------------------------------------------------------------------------
pin() { # key field -> value from ci/runner-b-inputs.json ("" when absent)
    plutil -extract "$1.$2" raw -o - "$INPUTS" 2>/dev/null || true
}
URL_KEYS=(wine llvm-mingw hangover-dlls crossover-sources)
REPO_KEYS=(highball-0003 highball-0018 highball-0019 runner-b-0020 runner-b-0021 fexunixlib-darwin fexunixlib-trace fexunixlib-tso-threads)
# Pins this script does not fetch itself but which must match the scripts that do.
SHARED_KEYS=(moltenvk nettle sdl2 ffmpeg wine-mono-x86 wine-mono-arm64 wine-gecko-x86 wine-gecko-x86_64)

pin_ok() { # key -> 0 when its sha256 is a real hash
    local sha; sha="$(pin "$1" sha256)"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
}
need_pin() { # key -> sha256, or refuse (rule 4)
    pin_ok "$1" || die "$1: sha256 is '$(pin "$1" sha256)' in ci/runner-b-inputs.json (TODO-PIN); refusing to run"
    pin "$1" sha256
}
verify_file() { # file sha256
    echo "$2  $1" | shasum -a 256 -c - >/dev/null 2>&1 || die "sha256 mismatch: $1 (want $2, got $(shasum -a 256 "$1" | cut -c1-64))"
}
fetch_input() { # key -> downloads/<file>, verified
    local sha url file
    sha="$(need_pin "$1")"; url="$(pin "$1" url)"; file="$(pin "$1" file)"
    [ -n "$url" ] && [ -n "$file" ] || die "$1: url/file missing in inputs"
    mkdir -p "$DL"
    [ -f "$DL/$file" ] || { echo "fetching $url"; curl -fSL --retry 3 -o "$DL/$file.part" "$url" && mv "$DL/$file.part" "$DL/$file"; }
    verify_file "$DL/$file" "$sha"
}
verify_repo() { # key -> path of the committed file, verified
    local sha path
    sha="$(need_pin "$1")"; path="$(pin "$1" path)"
    [ -f "$ROOT/$path" ] || die "$1: $path missing"
    verify_file "$ROOT/$path" "$sha"
    printf '%s\n' "$ROOT/$path"
}
# The host-dependency pins are written out in Runner A's scripts too; they must agree.
check_shared_pins() {
    local k sha bad=0
    for k in moltenvk nettle sdl2 ffmpeg; do
        sha="$(pin "$k" sha256)"; grep -q "$sha" "$ROOT/scripts/build-deps.sh" || { echo "pin $k differs from scripts/build-deps.sh" >&2; bad=1; }
    done
    sha="$(pin crossover-sources sha256)"; grep -q "$sha" "$ROOT/scripts/prepare-wine-src.sh" || { echo "pin crossover-sources differs from scripts/prepare-wine-src.sh" >&2; bad=1; }
    for k in wine-gecko-x86 wine-gecko-x86_64; do
        sha="$(pin "$k" sha256)"; grep -q "$sha" "$ROOT/scripts/assemble-runner.sh" || { echo "pin $k differs from scripts/assemble-runner.sh" >&2; bad=1; }
    done
    return $bad
}
check_all_pins() { # refuse on any TODO-PIN, before doing anything
    local k bad=0
    for k in "${URL_KEYS[@]}" "${REPO_KEYS[@]}" "${SHARED_KEYS[@]}"; do
        pin_ok "$k" || { echo "TODO-PIN: $k" >&2; bad=1; }
    done
    [ "$bad" = 0 ] || die "unpinned inputs (rule 4); fill ci/runner-b-inputs.json first"
    check_shared_pins || die "ci/runner-b-inputs.json disagrees with Runner A's pins"
}

SUBDIR="$(pin wine subdir)"; SUBDIR="${SUBDIR:-wine-11.18}"
SRC="$B/src/$SUBDIR"

# --- what gets run --------------------------------------------------------------------------
# llvm-mingw sits after /usr/bin: it ships its own `clang`, which knows no macOS SDK, and the
# host compiler must be Apple's (also named by absolute path below).
BUILD_PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/bin:/bin:/usr/sbin:/sbin:$TC/bin:/opt/homebrew/bin"
# @loader_path/../.. is the runner's lib/ (bundled dylibs). $DEPS/lib is only there so the
# build's own tools (sfnt2fon links FreeType) run; the install step deletes that rpath again.
# shellcheck disable=SC2054 # the commas are configure syntax (--enable-archs=a,b,c)
CONFIGURE_ARGS=(
    --prefix="$INSTALL"
    --enable-archs=arm64ec,aarch64,i386
    --with-mingw
    --disable-tests
    --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus
    --without-fontconfig --with-freetype --with-gnutls --without-gphoto --without-gstreamer
    --without-krb5 --without-netapi --without-oss --without-pulse --without-sane --with-sdl
    --without-udev --without-usb --without-v4l2 --with-vulkan --without-x --without-wayland
    --with-ffmpeg --without-inotify --without-pcap
    CC="ccache /usr/bin/clang" CXX="ccache /usr/bin/clang++" OBJC="ccache /usr/bin/clang"
    arm64ec_CC="ccache arm64ec-w64-mingw32-clang"
    aarch64_CC="ccache aarch64-w64-mingw32-clang"
    i386_CC="ccache i686-w64-mingw32-clang"
    CFLAGS="-O2 -g0" CROSSCFLAGS="-O2 -g0"
    CPPFLAGS="-I$DEPS/include"
    LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../.. -Wl,-rpath,$DEPS/lib -Wl,-headerpad_max_install_names"
    ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib
    PKG_CONFIG=/opt/homebrew/bin/pkg-config
    FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype"
    SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2"
    GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls"
    FFMPEG_CFLAGS="-I$DEPS/include" FFMPEG_LIBS="-L$DEPS/lib -lavformat -lavcodec -lavutil"
)
# SDK 11.0 in LC_BUILD_VERSION keeps x18 preserved (CodeWeavers' interim rule, wine-devel
# 2026-08-07); PAGEZERO 0x170000000 is the low range patch 0018 hands to Wine as reserved memory.
LOADER_LINK=(
    /usr/bin/clang -arch arm64 -mmacos-version-min=11.0 -o "$APP/Contents/MacOS/wine" "$OBJ/loader/main.o"
    "-Wl,-platform_version,macos,11.0,11.0,-pagezero_size,0x170000000,-image_base,0x170000000,-x86_64_layout_emulation,-sectcreate,__TEXT,__info_plist,$B/wine.app-Info.plist"
)
FEX_CXX=(/usr/bin/clang++ -std=c++17 -O2 -shared -fPIC -arch arm64 -mmacos-version-min=11.0)

print_plan() {
    local k sha st rc=0 path entry
    echo "Runner B build plan (no network, nothing built)"
    echo "  root      $ROOT"
    echo "  source    $SRC"
    echo "  objdir    $OBJ"
    echo "  install   $INSTALL"
    echo "  deps      $DEPS (HOST_ARCH=arm64 scripts/build-deps.sh)"
    echo "  toolchain $TC"
    echo "  loader    ${APP#"$INSTALL"/}/Contents/MacOS/wine (bundle id $BUNDLE_ID until signed)"
    echo "  server    bin/wineserver-arm64 (bin/wineserver -> wineserver-arm64)"
    echo
    echo "Pins (ci/runner-b-inputs.json):"
    for k in "${URL_KEYS[@]}" "${SHARED_KEYS[@]}"; do
        sha="$(pin "$k" sha256)"
        if pin_ok "$k"; then
            st=ok; [ -f "$DL/$(pin "$k" file)" ] && st="ok, cached"
        else st="TODO-PIN, refuses to run"; rc=1; fi
        printf '  %-18s %-12.12s %s  [%s]\n' "$k" "$sha" "$(pin "$k" url)" "$st"
    done
    for k in "${REPO_KEYS[@]}"; do
        sha="$(pin "$k" sha256)"; path="$(pin "$k" path)"
        if ! pin_ok "$k"; then st="TODO-PIN, refuses to run"; rc=1
        elif [ ! -f "$ROOT/$path" ]; then st="MISSING"; rc=1
        elif echo "$sha  $ROOT/$path" | shasum -a 256 -c - >/dev/null 2>&1; then st="file matches"
        else st="MISMATCH, file is $(shasum -a 256 "$ROOT/$path" | cut -c1-12)"; rc=1; fi
        printf '  %-18s %-12.12s %s  [%s]\n' "$k" "$sha" "$path" "$st"
    done
    if check_shared_pins; then echo "  host-dependency pins agree with Runner A's scripts"; else rc=1; fi
    echo
    echo "Patch series (patches/runner-b/series, patch -p1, already-applied patches skipped):"
    while read -r entry; do
        case "$entry" in ''|'#'*) continue ;; esac
        if grep -q "\"$entry\"" "$INPUTS" || grep -q "\"patches/$entry\"" "$INPUTS"; then st=pinned; else st="NOT PINNED"; rc=1; fi
        [ -f "$ROOT/patches/$entry" ] || { st="MISSING"; rc=1; }
        printf '  %s  [%s]\n' "$entry" "$st"
    done < "$SERIES"
    echo
    echo "configure (in $OBJ, MACOSX_DEPLOYMENT_TARGET=11.0, PATH=$BUILD_PATH):"
    printf '  %q \\\n' "$SRC/configure" "${CONFIGURE_ARGS[@]}"
    echo
    echo "FEX helpers: ${FEX_CXX[*]} -o aarch64-unix/{libarm64ecfex,libwow64fex}.so fexunixlib_darwin.cpp (+ 0001 kr trace, 0002 TSO on every thread)"
    echo "FEX DLLs:    hangover libarm64ecfex.dll -> aarch64-windows/xtajit64.dll, libwow64fex.dll -> xtajit.dll"
    echo
    echo "loader relink:"
    printf '  %q \\\n' "${LOADER_LINK[@]}"
    echo
    [ "$rc" = 0 ] && echo "plan OK" || echo "plan has problems (see above)"
    return "$rc"
}

# --- stages ---------------------------------------------------------------------------------
stage_check() {
    log "check"
    [ "$(uname -m)" = arm64 ] || die "Apple Silicon only (the Unix side is native arm64)"
    xcode-select -p >/dev/null 2>&1 || die "install the Xcode Command Line Tools"
    command -v brew >/dev/null || die "Homebrew is required"
    local f missing=""
    for f in bison flex ccache cmake ninja pkgconf autoconf; do
        brew list --versions "$f" >/dev/null 2>&1 || missing="$missing $f"
    done
    [ -z "$missing" ] || die "brew install$missing"
    # Apple's pieces the plan relies on (Xcode/CLT 26.4+, macOS 26.5+ SDK).
    grep -q 'thread_set_x86_64_compat' "$(xcrun --show-sdk-path)/usr/include/mach/mach_traps.h" \
        || die "this SDK does not declare thread_set_x86_64_compat (need the macOS 26.5+ SDK)"
    mkdir -p "$B"
    printf 'int main(void){return 0;}\n' > "$B/layout-probe.c"
    /usr/bin/clang -arch arm64 -o "$B/layout-probe" "$B/layout-probe.c" -Wl,-x86_64_layout_emulation 2>/dev/null \
        || die "this linker has no -x86_64_layout_emulation (need Xcode/CLT 26.4 or later)"
    rm -f "$B/layout-probe" "$B/layout-probe.c"
    echo "host ok: $(sw_vers -productVersion), SDK $(xcrun --show-sdk-version), $(ld -v 2>&1 | head -1)"
}

stage_fetch() {
    log "fetch (pinned)"
    local k
    for k in wine llvm-mingw hangover-dlls; do fetch_input "$k"; done
    if [ ! -d "$B/src/$SUBDIR" ]; then
        mkdir -p "$B/src"
        tar -xJf "$DL/$(pin wine file)" -C "$B/src"
        [ -f "$SRC/configure" ] || die "unexpected wine tarball layout (no $SUBDIR/configure)"
    fi
    if [ ! -x "$TC/bin/arm64ec-w64-mingw32-clang" ]; then
        rm -rf "$TC"; mkdir -p "$TC"
        tar -xJf "$DL/$(pin llvm-mingw file)" -C "$TC" --strip-components 1
    fi
    "$TC/bin/arm64ec-w64-mingw32-clang" --version | head -1
    if [ ! -d "$FEXDLLS" ]; then
        mkdir -p "$FEXDLLS.part"
        tar -xf "$DL/$(pin hangover-dlls file)" -C "$FEXDLLS.part"
        mv "$FEXDLLS.part" "$FEXDLLS"
    fi
    # gmp, gnutls and freetype come from the CrossOver drop, as for Runner A (same pin).
    if [ ! -d "$ROOT/sources/sources/gnutls" ] || [ ! -d "$ROOT/sources/sources/freetype" ]; then
        fetch_input crossover-sources
        mkdir -p "$ROOT/sources"
        tar -xzf "$DL/$(pin crossover-sources file)" -C "$ROOT/sources" sources/gnutls sources/freetype
    fi
}

stage_deps() {
    log "host libraries (build/deps-arm64)"
    local lib ok=1
    for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib libavcodec.dylib; do
        [ -e "$DEPS/lib/$lib" ] && lipo "$DEPS/lib/$lib" -verify_arch arm64 2>/dev/null || ok=0
    done
    if [ "$ok" = 1 ]; then echo "already built: $DEPS"; return; fi
    HOST_ARCH=arm64 "$ROOT/scripts/build-deps.sh"
}

stage_patch() {
    log "patch series (patches/runner-b/series)"
    [ -d "$SRC" ] || die "no source at $SRC (run the fetch stage)"
    local k entry p
    for k in "${REPO_KEYS[@]}"; do verify_repo "$k" >/dev/null; done
    while read -r entry; do
        case "$entry" in ''|'#'*) continue ;; esac
        p="$ROOT/patches/$entry"
        [ -f "$p" ] || die "missing patch $entry"
        grep -q "\"patches/$entry\"" "$INPUTS" || die "$entry is not pinned in ci/runner-b-inputs.json"
        if patch -d "$SRC" -p1 -R -f -s --dry-run < "$p" >/dev/null 2>&1; then
            echo "already applied $entry"; continue
        fi
        patch -d "$SRC" -p1 -N -s --dry-run < "$p" >/dev/null || die "$entry does not apply to $SRC"
        patch -d "$SRC" -p1 -N -s --no-backup-if-mismatch < "$p"
        echo "applied $entry"
    done < "$SERIES"
    # B3: Valve's lsteamclient (Proton commit, content-digest pinned) with NotProton's macOS
    # files; patch 0023 registers dlls/lsteamclient (arm64ec + i386 PE, aarch64 unix side).
    "$ROOT/scripts/fetch-steam-sources.sh" --into "$SRC"
}

stage_configure() {
    log "configure"
    [ -x "$TC/bin/arm64ec-w64-mingw32-clang" ] || die "no llvm-mingw at $TC (run the fetch stage)"
    [ -e "$DEPS/lib/libMoltenVK.dylib" ] || die "no host libraries at $DEPS (run the deps stage)"
    mkdir -p "$OBJ"
    if [ ! -f "$OBJ/Makefile" ] || [ "$RECONFIGURE" = 1 ]; then
        (cd "$OBJ" && "$SRC/configure" "${CONFIGURE_ARGS[@]}")
    fi
    # configure turns optional features off silently; fail early if one we rely on is missing.
    local need
    for need in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBSDL2 SONAME_LIBVULKAN; do
        grep -q "#define $need " "$OBJ/include/config.h" || die "missing $need in config.h"
    done
    grep -q '#define HAVE_FFMPEG 1' "$OBJ/include/config.h" || die "FFmpeg not enabled"
    grep -E '#define SONAME_LIB(FREETYPE|GNUTLS|SDL2|VULKAN) ' "$OBJ/include/config.h"
}

# Shipped Mach-O files must not keep the build machine's deps rpath; re-sign ad hoc after editing.
strip_build_rpath() { # file
    local f="$1"
    otool -l "$f" 2>/dev/null | grep -q "path $DEPS/lib " || return 0
    install_name_tool -delete_rpath "$DEPS/lib" "$f"
    codesign -f -s - "$f" 2>/dev/null
}

stage_make() {
    log "make (this is the long one)"
    [ -f "$OBJ/Makefile" ] || die "not configured"
    make -C "$OBJ" -j"$JOBS"
    rm -rf "$INSTALL"
    make -C "$OBJ" install-lib
    local f
    while IFS= read -r f; do strip_build_rpath "$f"; done < <(find "$INSTALL" -type f \( -name '*.so' -o -path '*/bin/*' -o -name wine \))
    # Only load-command paths (LC_RPATH path, dylib name) count: otool -l also prints each file's
    # own path as a header, which is always under $ROOT/build.
    if find "$INSTALL" -type f \( -name '*.so' -o -path '*/bin/*' \) -exec otool -l {} + 2>/dev/null \
        | grep -E '^ +(path|name) ' | grep "$ROOT/build" >&2; then
        die "build-machine paths left in installed load commands"
    fi
}

stage_fex() {
    log "FEX (Hangover 11.16 DLLs + Darwin unix helper)"
    [ -d "$UNIX" ] && [ -d "$WIN" ] || die "no install at $INSTALL (run the make stage)"
    local src trace tso work n dll
    src="$(verify_repo fexunixlib-darwin)"; trace="$(verify_repo fexunixlib-trace)"; tso="$(verify_repo fexunixlib-tso-threads)"
    work="$B/fex-work"; rm -rf "$work"; mkdir -p "$work"
    cp "$src" "$work/fexunixlib_darwin.cpp"
    patch -d "$work" -p1 -s --no-backup-if-mismatch < "$trace"
    # thread_set_x86_64_compat is per thread and FEX asks once: without 0002 only the thread that
    # ran FEX's ProcessInit gets TSO and every other x86 thread runs unordered (RUNNER-B-TSO.md).
    patch -d "$work" -p1 -s --no-backup-if-mismatch < "$tso"
    # FEX's DLLs load their unix helper by name from the ntdll.so directory and fall back to raw
    # Linux syscalls without it, which macOS answers with SIGKILL.
    # Install name @rpath/<name>.so like Wine's own unix libraries; the default would be the
    # build-machine output path (CI's forbidden-content check rejects that).
    for n in libarm64ecfex libwow64fex; do
        "${FEX_CXX[@]}" -Wl,-install_name,"@rpath/$n.so" -o "$UNIX/$n.so" "$work/fexunixlib_darwin.cpp"
        codesign -f -s - "$UNIX/$n.so"
    done
    # Under Wine's default emulator names, so no per-prefix registry key is needed.
    for n in libarm64ecfex:xtajit64 libwow64fex:xtajit; do
        dll="$(find "$FEXDLLS" -type f -name "${n%%:*}.dll")"
        [ "$(printf '%s\n' "$dll" | grep -c .)" = 1 ] || die "expected one ${n%%:*}.dll in the Hangover tarball, found: $dll"
        install -m 0644 "$dll" "$WIN/${n##*:}.dll"
    done
    ls -l "$WIN"/xtajit*.dll "$UNIX"/lib*fex.so
}

stage_loader() {
    log "loader bundle and wineserver-arm64"
    [ -f "$OBJ/loader/main.o" ] || die "no $OBJ/loader/main.o (run the make stage)"
    [ -d "$UNIX" ] || die "no install at $INSTALL"
    local version
    version="$(sed -n 's/^#define PACKAGE_VERSION "\(.*\)"/\1/p' "$OBJ/include/config.h")"
    [ -n "$version" ] || die "no PACKAGE_VERSION in config.h"
    sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@VERSION@/$version/" \
        "$ROOT/runner-b/WineLoader/Info.plist.in" > "$B/wine.app-Info.plist"
    plutil -lint "$B/wine.app-Info.plist" >/dev/null
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$B/wine.app-Info.plist" "$APP/Contents/Info.plist"
    MACOSX_DEPLOYMENT_TARGET=11.0 "${LOADER_LINK[@]}"
    # Wine's own loader (4 KB segments, no entitlement) is killed at exec on arm64; patch 0020
    # makes ntdll exec the bundle instead, so the plain one must not linger.
    rm -f "$UNIX/wine"
    if [ -L "$INSTALL/bin/wine" ]; then rm -f "$INSTALL/bin/wine"; fi   # would dangle; use runner.json "loader"
    # Ad-hoc seal for now; scripts/runner-b-sign.sh re-signs with the provisioning profile.
    codesign -f -s - "$APP"
    # CrossOver 27 / NotProton layout: bin/wineserver-arm64 (compat_run.sh looks for it).
    [ -f "$INSTALL/bin/wineserver" ] && [ ! -L "$INSTALL/bin/wineserver" ] && mv "$INSTALL/bin/wineserver" "$INSTALL/bin/wineserver-arm64"
    [ -x "$INSTALL/bin/wineserver-arm64" ] || die "no wineserver"
    ln -sf wineserver-arm64 "$INSTALL/bin/wineserver"
    otool -l "$APP/Contents/MacOS/wine" | grep -A4 '__PAGEZERO' | grep vmsize
    for f in "$APP/Contents/MacOS/wine" "$INSTALL/bin/wineserver-arm64"; do
        printf '%s: %s\n' "${f##*/}" "$(lipo -archs "$f")"
    done
    echo "loader: $APP (wine $version)"
}

# --- main -----------------------------------------------------------------------------------
RECONFIGURE=0; PLAN=0; STAGES=()
for a in "$@"; do
    case "$a" in
        --print-plan) PLAN=1 ;;
        --reconfigure) RECONFIGURE=1 ;;
        check|fetch|deps|patch|configure|make|fex|loader) STAGES+=("$a") ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) die "unknown argument: $a" ;;
    esac
done
[ -f "$INPUTS" ] || die "missing $INPUTS"
if [ "$PLAN" = 1 ]; then print_plan; exit $?; fi

check_all_pins
export MACOSX_DEPLOYMENT_TARGET=11.0
export PATH="$BUILD_PATH"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_PATH=""
export CCACHE_DIR="$ROOT/build/ccache-arm64"
[ "${#STAGES[@]}" -gt 0 ] || STAGES=(check fetch deps patch configure make fex loader)
for s in "${STAGES[@]}"; do "stage_$s"; done
log "done: $INSTALL (assemble with scripts/assemble-runner-b.sh)"
