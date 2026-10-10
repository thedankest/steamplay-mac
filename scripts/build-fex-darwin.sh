#!/bin/bash
# Runner B: FEX from source (HANDOFF §5 item 12). Builds dbc-hbin/FEX-darwin (branch darwin,
# FEX-2609.1 + Darwin patches, MIT) into the two emulator DLLs Wine 11.18 loads on arm64:
#
#   xtajit64.dll  ARM64EC module (x64 guests)   = FEX target arm64ecfex, triple arm64ec-w64-mingw32
#   xtajit.dll    WoW64 module (x86 guests)     = FEX target wow64fex,   triple aarch64-w64-mingw32
#
# Mirrors FEX-darwin's own Darwin/build.py (same cmake flags, same PE audit, same licence set)
# but works from pinned tarballs instead of a git checkout (rule 4), builds with 4 jobs at
# background priority (the user games on this Mac) and, by default, builds the WoW64 module
# WITHOUT the guest window: our Wine maps the low 4 GB (Highball patch 0018), so 32-bit guests
# run at their own addresses and the NtQueryInformationProcess class-1010 hook that FEX-darwin's
# build.py configuration needs is not required (research/FEX-DARWIN.md). FEX_GUEST_WINDOW=True
# restores build.py's choice.
#
#   build/fex-darwin/src/FEX-darwin-<commit>/   FEX-darwin + its six submodules, from tarballs
#   build/fex-darwin/build-{arm64ec,wow64}/     cmake (Unix Makefiles, Release, no LTO)
#   build/fex-darwin/out/dlls/{xtajit64,xtajit}.dll, out/licenses/, out/fex-result.json
#
# The DLLs call these optional ntdll exports when present (patches/runner-b/0024, later):
# __wine_jit_write_protect, __wine_allocate_native_jit, __wine_get_user_shared_data. Without
# them they fall back to plain RWX VirtualAlloc, which Highball patch 0019 turns into its
# read-write/read-execute page flipping, exactly like the Hangover DLLs Runner B ships today.
#
# Inputs are pinned by sha256 in ci/runner-b-inputs.json. GitHub tarballs carry no published
# digest, so the seven keys start as TODO-PIN: the `pin` stage downloads them once, matches
# every file against the pinned commit's git tree (gh api) and prints the sha256 to write into
# the inputs file. Every other stage refuses a TODO-PIN. Downloads (pin, fetch) need the user's
# OK first.
#
# Usage: scripts/build-fex-darwin.sh [--print-plan] [stage ...]
#   stages (default: check fetch unpack configure make audit):
#     check      host (arm64, not Rosetta), cmake, make, python3, llvm-mingw, disk space
#     pin        NETWORK: fetch the seven tarballs, verify against gh api trees, print sha256s
#     fetch      NETWORK: pinned downloads into downloads/ (sha256-verified)
#     unpack     fresh build/fex-darwin/src from the verified tarballs (submodules placed)
#     configure  cmake for both modules (FEX_VARIANTS="arm64ec wow64" selects)
#     make       cmake --build, FEX_JOBS (4) jobs, under taskpolicy -b nice -n 19
#     audit      FEX-darwin's own PE audit on both DLLs + licence copies -> out/
#     install    copy the audited DLLs over the Hangover ones in build/wine-arm64/install
#                (backs them up to build/wine-arm64/fex-dlls-hangover once; needs FEX_INSTALL=1)
#   --print-plan   show pins, paths and commands; no network, no build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/build/fex-darwin"
DL="$ROOT/downloads"
INPUTS="$ROOT/ci/runner-b-inputs.json"
WINE_B="${RUNNER_B_BUILD:-$ROOT/build/wine-arm64}"
TC="${FEX_LLVM_MINGW:-$WINE_B/toolchains/llvm-mingw}"
JOBS="${FEX_JOBS:-4}"
GUEST_WINDOW="${FEX_GUEST_WINDOW:-False}"
VARIANTS="${FEX_VARIANTS:-arm64ec wow64}"
# The unpacked tree is not a git checkout; without a ceiling, git (and so FEX's cmake "commit"
# string) would walk up into the steamplay-mac repo (the KosmicKrisp build hit the same thing).
export GIT_CEILING_DIRECTORIES="$D"

die() { echo "build-fex-darwin: $*" >&2; exit 1; }
log() { printf '\n==== %s\n' "$*"; }

# --- pins (same helpers as build-dxmt-arm64.sh) ----------------------------------------------
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

# key:path-inside-the-FEX-tree, the six submodules Darwin/build.py checks (SUBMODULES there)
SUBMODULES=(fex-fmt:External/fmt fex-range-v3:External/range-v3 fex-rpmalloc:External/rpmalloc
            fex-unordered-dense:External/unordered_dense fex-xxhash:External/xxhash
            fex-cpp-optparse:Source/Common/cpp-optparse)
ALL_KEYS=(fex-darwin fex-fmt fex-range-v3 fex-rpmalloc fex-unordered-dense fex-xxhash fex-cpp-optparse)
COMMIT="$(pin fex-darwin commit)"
SRC="$D/src/$(pin fex-darwin subdir)"
OUT="$D/out"

# variant  triple                 target      def-dir  wine-name
variant_row() {
    case "$1" in
        arm64ec) echo "arm64ec arm64ec-w64-mingw32 arm64ecfex ARM64EC xtajit64.dll" ;;
        wow64)   echo "wow64 aarch64-w64-mingw32 wow64fex WOW64 xtajit.dll" ;;
        *) die "unknown variant $1 (arm64ec|wow64)" ;;
    esac
}

cmake_args() { # variant triple -> prints the cmake configure arguments (build.py's, plus the guest-window choice)
    local gw=False
    [ "$1" = wow64 ] && gw="$GUEST_WINDOW"
    printf '%s\n' -S "$SRC" -B "$D/build-$1" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        "-DCMAKE_TOOLCHAIN_FILE=$SRC/Data/CMake/toolchain_mingw.cmake" "-DMINGW_TRIPLE=$2" \
        -DENABLE_LTO=False -DBUILD_TESTING=False "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--section-alignment=16384" \
        -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DTUNE_CPU=none -DENABLE_CCACHE=False \
        "-DENABLE_GUEST_WINDOW=$gw" "-DPython_EXECUTABLE=$(command -v python3)"
}

print_plan() {
    local k st rc=0 v
    echo "FEX-darwin build plan (no network, nothing built)"
    echo "  source     dbc-hbin/FEX-darwin $COMMIT -> $SRC"
    echo "  toolchain  $TC ($("$TC/bin/clang" --version 2>/dev/null | head -1 || echo MISSING))"
    echo "  out        $OUT   jobs $JOBS (nice 19)   WoW64 guest window: $GUEST_WINDOW"
    echo
    echo "Pins (ci/runner-b-inputs.json):"
    for k in "${ALL_KEYS[@]}"; do
        if pin_ok "$k"; then st=ok; [ -f "$DL/$(pin "$k" file)" ] && st="ok, cached"
        else st="TODO-PIN, run the pin stage"; rc=1; fi
        printf '  %-22s %-12.12s %s  [%s]\n' "$k" "$(pin "$k" sha256)" "$(pin "$k" url)" "$st"
    done
    echo
    for v in $VARIANTS; do
        set -- $(variant_row "$v")
        echo "configure $1 ($5):"
        printf '  %q' cmake; cmake_args "$1" "$2" | while IFS= read -r a; do printf ' %q' "$a"; done; echo
        echo "  cmake --build $D/build-$1 --target $3 --parallel $JOBS"
    done
    echo
    [ "$rc" = 0 ] && echo "plan OK" || echo "plan has open items (see above)"
    return "$rc"
}

# --- stages ---------------------------------------------------------------------------------
stage_check() {
    log "check"
    [ "$(uname -m)" = arm64 ] || die "Apple Silicon only"
    [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 0 ] || die "running under Rosetta; FEX-darwin needs a native arm64 host"
    local t avail
    for t in cmake make python3 curl shasum plutil tar; do command -v "$t" >/dev/null || die "missing $t"; done
    for t in clang arm64ec-w64-mingw32-clang++ aarch64-w64-mingw32-clang++ llvm-readobj llvm-ar ld.lld; do
        [ -x "$TC/bin/$t" ] || die "no $t in $TC (scripts/build-wine-arm64.sh fetch unpacks llvm-mingw)"
    done
    avail=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
    [ "$avail" -ge 5 ] || die "only ${avail} GB free; the two FEX builds need about 3-4 GB"
    echo "host ok: $(cmake --version | head -1), $(python3 --version), $("$TC/bin/clang" --version | head -1), ${avail} GB free"
}

# Pinning a git tarball (rule 4): fetch once, check every file against the commit's git tree,
# and check that FEX-darwin's submodule gitlinks are the commits we pin for the six helpers.
stage_pin() {
    log "pin (network: GitHub tarballs + gh api)"
    command -v gh >/dev/null || die "gh is required"
    local k repo url file sha tmp expected
    expected=""
    for k in "${SUBMODULES[@]}"; do expected="$expected ${k#*:}=$(pin "${k%%:*}" commit)"; done
    for k in "${ALL_KEYS[@]}"; do
        url="$(pin "$k" url)"; file="$(pin "$k" file)"
        [ -n "$url" ] && [ -n "$file" ] || die "$k: no url/file in $INPUTS"
        repo="${url#https://codeload.github.com/}"; repo="${repo%/tar.gz/*}"
        download "$url" "$file"
        sha="$(shasum -a 256 "$DL/$file" | cut -c1-64)"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/fex-pin.XXXXXX")"
        mkdir "$tmp/x"
        tar -xzf "$DL/$file" -C "$tmp/x"
        gh api "repos/$repo/git/trees/$(pin "$k" commit)?recursive=1" > "$tmp/tree.json"
        python3 -I - "$tmp/tree.json" "$tmp/x/$(pin "$k" subdir)" "$k" "$expected" <<'PY' || { rm -rf "$tmp"; die "$k: tarball does not match the git tree of its commit"; }
import hashlib, json, os, sys
tree = json.load(open(sys.argv[1])); root = sys.argv[2]; key = sys.argv[3]
expected = dict(e.split("=", 1) for e in sys.argv[4].split())
if tree.get("truncated"): sys.exit("tree listing truncated")
bad = 0; seen = set()
for e in tree["tree"]:
    p = os.path.join(root, e["path"])
    if e["type"] == "commit":            # submodule: GitHub tarballs leave an empty directory
        if key == "fex-darwin" and e["path"] in expected and expected[e["path"]] != e["sha"]:
            print("SUBMODULE PIN MISMATCH", e["path"], "tree has", e["sha"], "inputs pin", expected[e["path"]]); bad += 1
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
if key == "fex-darwin":
    links = {e["path"]: e["sha"] for e in tree["tree"] if e["type"] == "commit"}
    missing = [p for p in expected if p not in links]
    if missing: print("NOT A SUBMODULE IN THE TREE:", missing); bad += 1
print(f"{len(seen)} files match the git tree" if not bad else f"{bad} problems")
sys.exit(1 if bad else 0)
PY
        rm -rf "$tmp"
        echo "$k: set \"sha256\": \"$sha\", \"size\": $(stat -f %z "$DL/$file") in ci/runner-b-inputs.json"
    done
}

stage_fetch() {
    log "fetch (pinned)"
    local k
    for k in "${ALL_KEYS[@]}"; do fetch_input "$k"; done
}

stage_unpack() {
    log "unpack -> $SRC"
    local k path
    for k in "${ALL_KEYS[@]}"; do verify_file "$DL/$(pin "$k" file)" "$(need_pin "$k")"; done
    rm -rf "$D/src.part"; mkdir -p "$D/src.part"
    tar -xzf "$DL/$(pin fex-darwin file)" -C "$D/src.part"
    [ -f "$D/src.part/$(pin fex-darwin subdir)/CMakeLists.txt" ] || die "unexpected tarball layout for fex-darwin"
    for k in "${SUBMODULES[@]}"; do
        path="$D/src.part/$(pin fex-darwin subdir)/${k#*:}"
        mkdir -p "$path"
        [ -z "$(ls -A "$path")" ] || die "submodule directory not empty in the tarball: ${k#*:}"
        tar -xzf "$DL/$(pin "${k%%:*}" file)" -C "$path" --strip-components 1
    done
    for k in Darwin/build.py Darwin/provenance.json Source/Windows/wine_builtin.bin Data/CMake/toolchain_mingw.cmake \
             External/fmt/CMakeLists.txt External/range-v3/CMakeLists.txt External/rpmalloc/CMakeLists.txt \
             External/unordered_dense/CMakeLists.txt External/xxhash/cmake_unofficial/CMakeLists.txt \
             Source/Common/cpp-optparse/CMakeLists.txt; do
        [ -f "$D/src.part/$(pin fex-darwin subdir)/$k" ] || die "missing after unpack: $k"
    done
    rm -rf "$D/src"; mv "$D/src.part" "$D/src"
    grep -q "COMMIT = \"9fbdc00bd6401aff3b32d79e78ff98b8a13e4dcf\"" "$SRC/Darwin/build.py" \
        || echo "warning: Darwin/build.py no longer names FEX-2609.1 as its baseline; re-read it"
    echo "unpacked: $(find "$SRC" -type f | wc -l | tr -d ' ') files"
}

stage_configure() {
    log "configure"
    [ -f "$SRC/CMakeLists.txt" ] || die "no source at $SRC (run unpack)"
    local v args
    export PATH="$TC/bin:$PATH"
    for v in $VARIANTS; do
        set -- $(variant_row "$v")
        "$TC/bin/$2-clang++" --version | head -1
        rm -rf "$D/build-$1"
        args=(); while IFS= read -r a; do args+=("$a"); done < <(cmake_args "$1" "$2")
        cmake "${args[@]}"
    done
}

stage_make() {
    log "make ($JOBS jobs, background priority)"
    local v nice=(taskpolicy -b nice -n 19)
    [ "${FEX_NO_THROTTLE:-0}" = 1 ] && nice=()
    export PATH="$TC/bin:$PATH"
    mkdir -p "$D/logs"
    for v in $VARIANTS; do
        set -- $(variant_row "$v")
        [ -f "$D/build-$1/Makefile" ] || die "$1 not configured"
        "${nice[@]}" cmake --build "$D/build-$1" --target "$3" --parallel "$JOBS" 2>&1 | tee "$D/logs/make-$1.log" | grep -E --line-buffered '^\[|error|warning: .*\[-W(error|fatal)' || true
        [ "${PIPESTATUS[0]}" = 0 ] || die "$1 build failed (see $D/logs/make-$1.log)"
        [ -f "$D/build-$1/Bin/lib$3.dll" ] || die "$1: no Bin/lib$3.dll after the build"
        ls -l "$D/build-$1/Bin/lib$3.dll"
    done
}

# FEX-darwin's own audit (Darwin/build.py audit(): PE32+ DLL, 16 KB section alignment, machine,
# Wine builtin marker, exports = .def, imports only ntdll[/wow64], CHPE metadata for ARM64EC).
stage_audit() {
    log "audit -> $OUT"
    local v
    rm -rf "$OUT"; mkdir -p "$OUT/dlls" "$OUT/licenses"
    for v in $VARIANTS; do
        set -- $(variant_row "$v")
        cp "$D/build-$1/Bin/lib$3.dll" "$OUT/dlls/$5"
    done
    python3 -I - "$SRC" "$OUT" "$TC/bin/llvm-readobj" "$COMMIT" "$GUEST_WINDOW" $VARIANTS <<'PY'
import hashlib, json, pathlib, platform, subprocess, sys
src, out, readobj, commit, guest_window = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
variants = sys.argv[6:]
sys.path.insert(0, str(src / "Darwin"))
import build  # FEX-darwin's Darwin/build.py: only audit() and LICENSES are used (its main() is guarded)
rows = {"arm64ec": ("arm64ec-w64-mingw32", "arm64ecfex", "ARM64EC", "xtajit64.dll"),
        "wow64": ("aarch64-w64-mingw32", "wow64fex", "WOW64", "xtajit.dll")}
marker = (src / "Source/Windows/wine_builtin.bin").read_bytes()
result = {"schema": 1, "status": "pass", "builder": "steamplay-mac scripts/build-fex-darwin.sh",
          "source": "https://github.com/dbc-hbin/FEX-darwin", "source_commit": commit,
          "baseline": {"repository": build.REPOSITORY, "tag": build.TAG, "commit": build.COMMIT},
          "wow64_guest_window": guest_window,
          "host": {"system": platform.system(), "machine": platform.machine(), "platform": platform.platform()},
          "builtin_marker_sha256": hashlib.sha256(marker).hexdigest(), "licenses": [], "artifacts": {}}
for name, lic in build.LICENSES.items():
    data = (src / name).read_bytes()
    (out / "licenses" / name.replace("/", "__")).write_bytes(data)
    result["licenses"].append({"path": name, "license": lic, "sha256": hashlib.sha256(data).hexdigest()})
prov = src / "Darwin/provenance.json"
result["provenance_sha256"] = hashlib.sha256(prov.read_bytes()).hexdigest()
for v in variants:
    triple, target, directory, wine_name = rows[v]
    dll = out / "dlls" / wine_name
    report = subprocess.run([readobj, "--file-headers", "--coff-load-config", "--coff-exports", "--coff-imports", str(dll)],
                            capture_output=True, text=True, check=True).stdout
    definition = (src / "Source/Windows" / directory / f"lib{target}.def").read_text()
    try:
        result["artifacts"][wine_name] = build.audit(dll.read_bytes(), report, definition, marker, v == "arm64ec") | {"path": str(dll)}
    except Exception as e:
        result["status"] = "blocked"; result["blocker"] = f"{wine_name}: {e}"
        break
(out / "fex-result.json").write_text(json.dumps(result, indent=2) + "\n")
for name, a in result["artifacts"].items():
    print(f"{name}: machine {a['machine']}, {len(a['exports'])} exports {a['exports']}, imports {a['imports']}, {a['size']} bytes, sha256 {a['sha256'][:16]}...")
if result["status"] != "pass":
    sys.exit("audit FAILED: " + result["blocker"])
print("audit pass:", out / "fex-result.json")
PY
}

stage_install() {
    log "install into $WINE_B/install"
    [ "${FEX_INSTALL:-0}" = 1 ] || die "refusing to replace the Hangover DLLs in build/wine-arm64/install without FEX_INSTALL=1 (other runner assemblies read that tree)"
    local win="$WINE_B/install/lib/wine/aarch64-windows" v
    [ -d "$win" ] || die "no Wine install at $win"
    [ -f "$OUT/fex-result.json" ] && grep -q '"status": "pass"' "$OUT/fex-result.json" || die "run the audit stage first"
    if [ ! -d "$WINE_B/fex-dlls-hangover" ]; then
        mkdir -p "$WINE_B/fex-dlls-hangover"
        cp "$win/xtajit64.dll" "$win/xtajit.dll" "$WINE_B/fex-dlls-hangover/"
        echo "backed up the Hangover DLLs to $WINE_B/fex-dlls-hangover"
    fi
    for v in $VARIANTS; do
        set -- $(variant_row "$v")
        install -m 0644 "$OUT/dlls/$5" "$win/$5"
    done
    cp "$OUT/fex-result.json" "$win/fex-dlls.json"
    ls -l "$win"/xtajit*.dll
}

# --- main -----------------------------------------------------------------------------------
PLAN=0; STAGES=()
for a in "$@"; do
    case "$a" in
        --print-plan) PLAN=1 ;;
        check|pin|fetch|unpack|configure|make|audit|install) STAGES+=("$a") ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) die "unknown argument: $a" ;;
    esac
done
[ -f "$INPUTS" ] || die "missing $INPUTS"
[ -n "$COMMIT" ] || die "no fex-darwin pin in $INPUTS"
if [ "$PLAN" = 1 ]; then print_plan; exit $?; fi
[ "${#STAGES[@]}" -gt 0 ] || STAGES=(check fetch unpack configure make audit)
for s in "${STAGES[@]}"; do "stage_$s"; done
log "done: $OUT"
