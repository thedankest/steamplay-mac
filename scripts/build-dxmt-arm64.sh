#!/bin/bash
# Runner B, stage B2: builds DXMT (D3D10/11 -> Metal) natively for Apple Silicon against our
# Wine 11.18 build tree (research/RUNNER-B-PLAN.md B2, RUNNER-B-T3.md Q1). Never touches
# Runner A's paths or anything outside build/dxmt-arm64 and downloads/.
#
#   build/dxmt-arm64/src/dxmt-<commit>/    3Shain/dxmt 7c8dee1 + submodule include/native/directx
#   build/dxmt-arm64/toolchains/llvm-15/   LLVM 15.0.7 static libs + headers, arm64 (airconv)
#   build/dxmt-arm64/build-arm64x/         meson, build-arm64ec.txt + -marm64x (ARM64X PE DLLs)
#                                          and the native arm64 winemetal.so
#   build/dxmt-arm64/build-i386/           meson, build-win32.txt (WoW64 PE DLLs)
#   build/dxmt-arm64/install/{aarch64-windows,aarch64-unix,i386-windows}/
#                                          what scripts/assemble-runner-b.sh copies into
#                                          lib/renderers/dxmt when it exists
#
# winemetal.so links our obj/dlls/winemac.drv/winemac.so and obj/dlls/ntdll/ntdll.so
# (-Dwine_build_path). winemac.so must carry patch runner-b/0021 (macdrv_functions export), or
# DXMT gets a device but no swapchain; the check stage refuses without it.
#
# Inputs are pinned by sha256 in ci/runner-b-inputs.json (rule 4). GitHub tarballs have no
# published digest, so dxmt and dxmt-directx-headers start as TODO-PIN: the `pin` stage fetches
# them once, matches every file against the pinned commit's git tree (gh api) and prints the
# sha256 to write into the inputs file. Every other stage refuses a TODO-PIN.
#
# Downloads (stages pin, fetch, prebuilt) and the Metal Toolchain (xcodebuild
# -downloadComponent MetalToolchain) need the user's OK first; this script never fetches the
# Metal Toolchain itself.
#
# Usage: scripts/build-dxmt-arm64.sh [--print-plan] [--no-i386] [stage ...]
#   stages (default: check fetch llvm configure make verify):
#     check      host tools, Metal Toolchain, Wine build tree with 0021, llvm-mingw
#     pin        NETWORK: fetch the git tarballs, verify against gh api trees, print sha256s
#     fetch      NETWORK: pinned downloads into downloads/, unpack sources
#     llvm       build LLVM 15.0.7 (libraries only, no targets, like DXMT's CI)
#     configure  meson setup (ARM64X + native winemetal.so; i386 unless --no-i386)
#     make       meson compile + install into build/dxmt-arm64/install
#     verify     architectures, link names, macdrv_functions present in the winemac it links
#     prebuilt   NETWORK, optional shortcut instead of llvm/configure/make: DXMT's own CI package
#                at the same commit (expires 2026-12-16; linked against 3Shain's wine-11.2)
#   --print-plan   show pins, paths and commands; no network, no build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUTS="$ROOT/ci/runner-b-inputs.json"
DL="$ROOT/downloads"
WB="${RUNNER_B_BUILD:-$ROOT/build/wine-arm64}"
OBJ="$WB/obj"
TC="$WB/toolchains/llvm-mingw"
D="${DXMT_BUILD:-$ROOT/build/dxmt-arm64}"
LLVM="$D/toolchains/llvm-15"
INSTALL="$D/install"
JOBS="$(sysctl -n hw.ncpu)"
WITH_I386=1

die() { echo "build-dxmt-arm64: $*" >&2; exit 1; }
log() { printf '\n==== %s\n' "$*"; }

# --- pins (same helpers as build-wine-arm64.sh) ----------------------------------------------
pin() { plutil -extract "$1.$2" raw -o - "$INPUTS" 2>/dev/null || true; }
pin_ok() { [[ "$(pin "$1" sha256)" =~ ^[0-9a-f]{64}$ ]]; }
need_pin() {
    pin_ok "$1" || die "$1: sha256 is '$(pin "$1" sha256)' in ci/runner-b-inputs.json (TODO-PIN); run the pin stage first (rule 4)"
    pin "$1" sha256
}
verify_file() { # file sha256
    echo "$2  $1" | shasum -a 256 -c - >/dev/null 2>&1 || die "sha256 mismatch: $1 (want $2, got $(shasum -a 256 "$1" | cut -c1-64))"
}
download() { # url file -> downloads/<file> (no verification here)
    mkdir -p "$DL"
    [ -f "$DL/$2" ] && return 0
    echo "fetching $1"
    curl -fSL --retry 3 -o "$DL/$2.part" "$1" && mv "$DL/$2.part" "$DL/$2"
}
fetch_input() { # key -> downloads/<file>, verified
    local sha; sha="$(need_pin "$1")"
    download "$(pin "$1" url)" "$(pin "$1" file)"
    verify_file "$DL/$(pin "$1" file)" "$sha"
}

COMMIT="$(pin dxmt commit)"
SRC="$D/src/$(pin dxmt subdir)"
GIT_KEYS=(dxmt dxmt-directx-headers)
URL_KEYS=(dxmt dxmt-directx-headers llvm-project-15)

# --- what gets run --------------------------------------------------------------------------
# Apple's clang for the native side (ObjC, Metal frameworks); llvm-mingw after /usr/bin, because
# it ships its own `clang` that knows no macOS SDK.
BUILD_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$TC/bin:/opt/homebrew/bin"
# DXMT's CI flags (llvmorg-15.0.7, libraries only). CMAKE_POLICY_VERSION_MINIMUM: CMake 4 drops
# compatibility with cmake_minimum_required < 3.5, which some LLVM 15 subprojects still declare.
LLVM_CMAKE=(
    -G Ninja
    -DCMAKE_INSTALL_PREFIX="$LLVM"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DLLVM_HOST_TRIPLE=arm64-apple-darwin
    -DLLVM_ENABLE_ASSERTIONS=On
    -DLLVM_ENABLE_ZSTD=Off
    -DLLVM_TARGETS_TO_BUILD=
    -DLLVM_BUILD_TOOLS=Off
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off
    -DBUG_REPORT_URL=https://github.com/3Shain/dxmt
    -DPACKAGE_VENDOR=DXMT
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
)
MESON_COMMON=(
    --buildtype release --strip
    -Dwine_build_path="$OBJ"
    -Dwine_builtin_dll=true
    -Denable_nvapi=false -Denable_nvngx=false -Denable_d3d12=false
)

# Cross files: DXMT's own, with our llvm-mingw spelled out (absolute paths, no PATH games).
write_cross_files() {
    mkdir -p "$D"
    cat > "$D/cross-arm64x.txt" <<EOF
# generated by scripts/build-dxmt-arm64.sh from DXMT build-arm64ec.txt (7c8dee1)
[binaries]
c = '$TC/bin/arm64ec-w64-mingw32-gcc'
cpp = '$TC/bin/arm64ec-w64-mingw32-g++'
ar = '$TC/bin/arm64ec-w64-mingw32-ar'
strip = '$TC/bin/arm64ec-w64-mingw32-strip'
windres = '$TC/bin/arm64ec-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-marm64x']
cpp_args = ['-marm64x']
c_link_args = ['-marm64x']
cpp_link_args = ['-marm64x']

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
    cat > "$D/cross-i386.txt" <<EOF
# generated by scripts/build-dxmt-arm64.sh from DXMT build-win32.txt (7c8dee1)
[binaries]
c = '$TC/bin/i686-w64-mingw32-gcc'
cpp = '$TC/bin/i686-w64-mingw32-g++'
ar = '$TC/bin/i686-w64-mingw32-ar'
strip = '$TC/bin/i686-w64-mingw32-strip'
windres = '$TC/bin/i686-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'x86'
endian = 'little'
EOF
    cat > "$D/native.txt" <<EOF
# generated by scripts/build-dxmt-arm64.sh: Apple's compilers for winemetal.so and airconv
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
EOF
}

print_plan() {
    local k st rc=0
    echo "DXMT arm64 build plan (no network, nothing built)"
    echo "  dxmt      3Shain/dxmt $COMMIT -> $SRC"
    echo "  wine tree $OBJ (wine_build_path)"
    echo "  llvm-15   $LLVM"
    echo "  install   $INSTALL"
    echo
    echo "Pins (ci/runner-b-inputs.json):"
    for k in "${URL_KEYS[@]}"; do
        if pin_ok "$k"; then st=ok; [ -f "$DL/$(pin "$k" file)" ] && st="ok, cached"
        else st="TODO-PIN, run the pin stage"; rc=1; fi
        printf '  %-22s %-12.12s %s  [%s]\n' "$k" "$(pin "$k" sha256)" "$(pin "$k" url)" "$st"
    done
    printf '  %-22s %-12.12s gh artifact %s/%s (optional prebuilt, expires %s)\n' dxmt-ci-prebuilt \
        "$(pin dxmt-ci-prebuilt sha256)" "$(pin dxmt-ci-prebuilt repo)" "$(pin dxmt-ci-prebuilt artifact)" "$(pin dxmt-ci-prebuilt expires)"
    echo
    echo "Host:"
    if xcrun -sdk macosx metal --version >/dev/null 2>&1; then echo "  Metal Toolchain: installed"
    else echo "  Metal Toolchain: MISSING (xcodebuild -downloadComponent MetalToolchain; a download)"; rc=1; fi
    echo "  meson $(meson --version 2>/dev/null || echo MISSING), ninja $(ninja --version 2>/dev/null || echo MISSING), $(cmake --version 2>/dev/null | head -1 || echo 'cmake MISSING')"
    if nm -gU "$OBJ/dlls/winemac.drv/winemac.so" 2>/dev/null | grep -q ' _macdrv_functions$'; then
        echo "  winemac.so exports macdrv_functions (0021)"
    else echo "  winemac.so: no macdrv_functions export (apply 0021, rebuild Wine)"; rc=1; fi
    echo
    echo "llvm (cmake in $D/llvm-build):"
    printf '  %q \\\n' cmake -S "$D/src/llvm-project-15.0.7.src/llvm" -B "$D/llvm-build" "${LLVM_CMAKE[@]}"
    echo
    echo "configure:"
    printf '  meson setup --cross-file %s --native-file %s -Dnative_llvm_path=%s %s %s\n' \
        "$D/cross-arm64x.txt" "$D/native.txt" "$LLVM" "${MESON_COMMON[*]}" "$D/build-arm64x"
    [ "$WITH_I386" = 1 ] && printf '  meson setup --cross-file %s --native-file %s %s %s\n' \
        "$D/cross-i386.txt" "$D/native.txt" "${MESON_COMMON[*]}" "$D/build-i386"
    echo
    [ "$rc" = 0 ] && echo "plan OK" || echo "plan has open items (see above)"
    return "$rc"
}

# --- stages ---------------------------------------------------------------------------------
stage_check() {
    log "check"
    [ "$(uname -m)" = arm64 ] || die "Apple Silicon only"
    local t v
    for t in meson ninja cmake xxd xcrun; do command -v "$t" >/dev/null || die "missing $t"; done
    v="$(meson --version)"
    [ "$(printf '1.3.0\n%s\n' "$v" | sort -V | head -1)" = 1.3.0 ] || die "meson $v is older than 1.3"
    xcrun -sdk macosx metal --version >/dev/null 2>&1 \
        || die "the Metal Toolchain is not installed. It is a separate download from Apple: ask the user, then run: xcodebuild -downloadComponent MetalToolchain"
    xcrun -sdk macosx metallib --version >/dev/null 2>&1 || die "metallib missing (Metal Toolchain incomplete)"
    for t in arm64ec-w64-mingw32-gcc i686-w64-mingw32-gcc; do
        [ -x "$TC/bin/$t" ] || die "no $t in $TC (scripts/build-wine-arm64.sh fetch)"
    done
    for t in dlls/winemac.drv/winemac.so dlls/ntdll/ntdll.so tools/winebuild/winebuild \
             libs/winecrt0/aarch64-windows/libwinecrt0.a dlls/ntdll/aarch64-windows/libntdll.a \
             dlls/dbghelp/aarch64-windows/libdbghelp.a; do
        [ -e "$OBJ/$t" ] || die "Wine build tree incomplete: $OBJ/$t (scripts/build-wine-arm64.sh make)"
    done
    nm -gU "$OBJ/dlls/winemac.drv/winemac.so" | grep -q ' _macdrv_functions$' \
        || die "$OBJ winemac.so lacks macdrv_functions: apply patches/runner-b/0021 (build-wine-arm64.sh patch make)"
    echo "host ok: meson $v, $(cmake --version | head -1), $(xcrun -sdk macosx metal --version 2>&1 | head -1)"
}

# Pinning a git tarball (rule 4): fetch once, check every file against the commit's git tree.
stage_pin() {
    log "pin (network: GitHub tarballs + gh api)"
    command -v gh >/dev/null || die "gh is required"
    local k repo url file sha tmp
    for k in "${GIT_KEYS[@]}"; do
        url="$(pin "$k" url)"; file="$(pin "$k" file)"
        repo="${url#https://codeload.github.com/}"; repo="${repo%/tar.gz/*}"
        download "$url" "$file"
        sha="$(shasum -a 256 "$DL/$file" | cut -c1-64)"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/dxmt-pin.XXXXXX")"
        mkdir "$tmp/x"
        tar -xzf "$DL/$file" -C "$tmp/x"
        gh api "repos/$repo/git/trees/$(pin "$k" commit)?recursive=1" > "$tmp/tree.json"
        python3 -I - "$tmp/tree.json" "$tmp/x/$(pin "$k" subdir)" <<'PY' || { rm -rf "$tmp"; die "$k: tarball does not match the git tree of its commit"; }
import hashlib, json, os, sys
tree = json.load(open(sys.argv[1])); root = sys.argv[2]
if tree.get("truncated"): sys.exit("tree listing truncated")
bad = 0; seen = set()
for e in tree["tree"]:
    p = os.path.join(root, e["path"])
    if e["type"] == "commit":            # submodule: GitHub tarballs leave an empty directory
        continue
    if e["type"] == "tree":
        continue
    seen.add(e["path"])
    data = os.readlink(p).encode() if e["mode"] == "120000" else open(p, "rb").read()
    h = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
    if h != e["sha"]:
        print("MISMATCH", e["path"]); bad += 1
for d, _, files in os.walk(root):
    for f in files:
        rel = os.path.relpath(os.path.join(d, f), root)
        if rel not in seen: print("EXTRA", rel); bad += 1
print(f"{len(seen)} files match the git tree" if not bad else f"{bad} problems")
sys.exit(1 if bad else 0)
PY
        rm -rf "$tmp"
        echo "$k: set \"sha256\": \"$sha\" in ci/runner-b-inputs.json ($(stat -f %z "$DL/$file") bytes)"
    done
}

stage_fetch() {
    log "fetch (pinned)"
    local k
    for k in "${URL_KEYS[@]}"; do fetch_input "$k"; done
    if [ ! -f "$SRC/meson.build" ]; then
        mkdir -p "$D/src"
        tar -xzf "$DL/$(pin dxmt file)" -C "$D/src"
    fi
    if [ ! -f "$SRC/include/native/directx/d3d11.h" ]; then
        tar -xzf "$DL/$(pin dxmt-directx-headers file)" -C "$SRC/include/native/directx" --strip-components 1
    fi
    [ -f "$SRC/include/native/directx/d3d11.h" ] || die "directx headers missing after unpack"
    if [ ! -d "$D/src/llvm-project-15.0.7.src/llvm" ]; then
        tar -xJf "$DL/$(pin llvm-project-15 file)" -C "$D/src" \
            llvm-project-15.0.7.src/llvm llvm-project-15.0.7.src/cmake llvm-project-15.0.7.src/third-party
    fi
}

stage_llvm() {
    log "LLVM 15.0.7, arm64 static libraries (airconv)"
    if [ -f "$LLVM/lib/libLLVMCore.a" ] && [ -x "$LLVM/bin/llvm-config" ] && [ "$("$LLVM/bin/llvm-config" --version)" = 15.0.7 ]; then
        echo "already built: $LLVM"; return
    fi
    [ -d "$D/src/llvm-project-15.0.7.src/llvm" ] || die "no LLVM source (run the fetch stage)"
    cmake -S "$D/src/llvm-project-15.0.7.src/llvm" -B "$D/llvm-build" "${LLVM_CMAKE[@]}"
    cmake --build "$D/llvm-build" -j "$JOBS"
    cmake --install "$D/llvm-build"
    lipo -archs "$LLVM/lib/libLLVMCore.a" | grep -qx arm64 || die "LLVM is not arm64"
    rm -rf "$D/llvm-build"   # ~2 GB; the install is all DXMT needs
}

stage_configure() {
    log "meson setup"
    [ -f "$SRC/meson.build" ] || die "no DXMT source (run the fetch stage)"
    [ -f "$LLVM/lib/libLLVMCore.a" ] || die "no LLVM 15 at $LLVM (run the llvm stage)"
    write_cross_files
    rm -rf "$D/build-arm64x" "$D/build-i386"
    (cd "$SRC" && meson setup --cross-file "$D/cross-arm64x.txt" --native-file "$D/native.txt" \
        -Dnative_llvm_path="$LLVM" "${MESON_COMMON[@]}" --prefix "$INSTALL" "$D/build-arm64x")
    if [ "$WITH_I386" = 1 ]; then
        (cd "$SRC" && meson setup --cross-file "$D/cross-i386.txt" --native-file "$D/native.txt" \
            "${MESON_COMMON[@]}" --prefix "$INSTALL" "$D/build-i386")
    fi
}

stage_make() {
    log "meson compile + install"
    [ -f "$D/build-arm64x/build.ninja" ] || die "not configured"
    rm -rf "$INSTALL"
    meson compile -C "$D/build-arm64x" -j "$JOBS"
    meson install -C "$D/build-arm64x"
    if [ "$WITH_I386" = 1 ]; then
        meson compile -C "$D/build-i386" -j "$JOBS"
        meson install -C "$D/build-i386"
    fi
    # strip -x invalidates the linker's ad-hoc signature; arm64 refuses unsigned code.
    codesign -f -s - "$INSTALL/aarch64-unix/winemetal.so"
    printf '%s\n' "$COMMIT" > "$INSTALL/DXMT_COMMIT"
    cp "$SRC/LICENSE" "$INSTALL/LICENSE.dxmt"
}

stage_verify() {
    log "verify $INSTALL"
    local so="$INSTALL/aarch64-unix/winemetal.so" f
    [ -f "$so" ] || die "no $so"
    [ "$(lipo -archs "$so")" = arm64 ] || die "winemetal.so is $(lipo -archs "$so"), want arm64"
    codesign --verify "$so" || die "winemetal.so signature invalid"
    for f in @rpath/winemac.so @rpath/ntdll.so; do
        otool -L "$so" | grep -q "$f" || die "winemetal.so does not link $f"
    done
    otool -L "$so" | grep -E "$ROOT|/opt/homebrew|/usr/local" && die "build-machine paths in winemetal.so"
    for f in d3d11 dxgi d3d10core winemetal; do
        [ -f "$INSTALL/aarch64-windows/$f.dll" ] || die "missing aarch64-windows/$f.dll"
        # ARM64X images report machine ARM64 plus an ARM64EC (CHPE) view.
        "$TC/bin/llvm-readobj" --file-headers "$INSTALL/aarch64-windows/$f.dll" | grep -q 'IMAGE_FILE_MACHINE_ARM64' \
            || die "aarch64-windows/$f.dll is not an ARM64(X) image"
        grep -q 'Wine builtin DLL' "$INSTALL/aarch64-windows/$f.dll" || echo "warning: $f.dll lacks the Wine builtin marker" >&2
    done
    if [ "$WITH_I386" = 1 ]; then
        for f in d3d11 dxgi d3d10core winemetal; do
            [ -f "$INSTALL/i386-windows/$f.dll" ] || die "missing i386-windows/$f.dll"
        done
    fi
    nm -gU "$OBJ/dlls/winemac.drv/winemac.so" | grep -q ' _macdrv_functions$' || die "winemac.so lacks macdrv_functions"
    echo "ok: ARM64X PE + arm64 winemetal.so (DXMT $COMMIT); assemble-runner-b.sh copies it to lib/renderers/dxmt"
}

# Optional: DXMT's own CI package for the same commit. Faster for a first look, not for shipping:
# its arm64ec half was linked against 3Shain's wine-11.2 tree, and GitHub deletes it on expiry.
stage_prebuilt() {
    log "prebuilt (network: DXMT CI artifact $(pin dxmt-ci-prebuilt artifact))"
    command -v gh >/dev/null || die "gh is required (artifact downloads need a GitHub login)"
    local sha zip tmp tgz f
    sha="$(need_pin dxmt-ci-prebuilt)"
    zip="$DL/dxmt-ci-$(pin dxmt-ci-prebuilt artifact).zip"
    if [ ! -f "$zip" ]; then
        mkdir -p "$DL"
        gh api "repos/$(pin dxmt-ci-prebuilt repo)/actions/artifacts/$(pin dxmt-ci-prebuilt artifact)/zip" > "$zip.part"
        mv "$zip.part" "$zip"
    fi
    verify_file "$zip" "$sha"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/dxmt-ci.XXXXXX")"
    unzip -q "$zip" -d "$tmp/zip"
    tgz="$(find "$tmp/zip" -name 'dxmt-*.tar.gz' | head -1)"
    [ -n "$tgz" ] || { rm -rf "$tmp"; die "no dxmt-*.tar.gz inside the artifact"; }
    mkdir "$tmp/x"; tar -xzf "$tgz" -C "$tmp/x"
    rm -rf "$INSTALL"; mkdir -p "$INSTALL"
    for f in aarch64-windows aarch64-unix i386-windows; do
        [ -d "$tmp/x/$COMMIT/$f" ] && cp -R "$tmp/x/$COMMIT/$f" "$INSTALL/"
    done
    rm -rf "$tmp"
    [ -f "$INSTALL/aarch64-unix/winemetal.so" ] || die "artifact has no aarch64-unix/winemetal.so"
    codesign -f -s - "$INSTALL/aarch64-unix/winemetal.so"
    printf '%s (DXMT CI artifact %s)\n' "$COMMIT" "$(pin dxmt-ci-prebuilt artifact)" > "$INSTALL/DXMT_COMMIT"
    [ -d "$INSTALL/i386-windows" ] || WITH_I386=0
    stage_verify
}

# --- main -----------------------------------------------------------------------------------
PLAN=0; STAGES=()
for a in "$@"; do
    case "$a" in
        --print-plan) PLAN=1 ;;
        --no-i386) WITH_I386=0 ;;
        check|pin|fetch|llvm|configure|make|verify|prebuilt) STAGES+=("$a") ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) die "unknown argument: $a" ;;
    esac
done
[ -f "$INPUTS" ] || die "missing $INPUTS"
[ -n "$COMMIT" ] || die "no dxmt pin in $INPUTS"
if [ "$PLAN" = 1 ]; then print_plan; exit $?; fi
export PATH="$BUILD_PATH"
[ "${#STAGES[@]}" -gt 0 ] || STAGES=(check fetch llvm configure make verify)
for s in "${STAGES[@]}"; do "stage_$s"; done
log "done: $INSTALL"
