#!/bin/bash
# Add Runner B's Vulkan renderers to an assembled Runner B tree: KosmicKrisp (+ the Khronos loader),
# vkd3d-proton (Direct3D 12) and DXVK (dxgi, Direct3D 8-11), in the layout notproton patch 0005's
# run script looks for:
#
#   lib/renderers/kosmickrisp/lib/libvulkan_kosmickrisp.dylib
#   lib/renderers/kosmickrisp/icd.d/kosmickrisp_icd.json     (VK_DRIVER_FILES)
#   lib/renderers/kosmickrisp/vklib/libMoltenVK.dylib        (the Khronos loader under the name
#                                                             winevulkan opens; DYLD_LIBRARY_PATH)
#   lib/renderers/vkd3d-proton/{aarch64,i386}-windows/d3d12.dll, d3d12core.dll   (marked builtin)
#   lib/renderers/dxvk/{aarch64,i386}-windows/dxgi.dll, d3d11.dll, ...            (marked builtin)
#
# The PE files are the upstream x64/x86 release builds (they run under FEX); aarch64-windows is the
# directory WINEDLLPATH uses on Runner B. Also records them in runner.json "renderers".
#
#   scripts/package-runner-b-dx12.sh [RUNNER_DIR]   (default: dist/runners/selfbuilt-wine11.18-arm64-r1)
#
# Inputs: build/kosmickrisp/out (scripts/build-kosmickrisp.sh), downloads/vkd3d-proton-3.0.1.tar.zst and
# downloads/dxvk-3.1.1.tar.gz (pinned in ci/runner-b-inputs.json), Homebrew vulkan-loader, winebuild.
# Copies and edits headers only; nothing is compiled.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$root/dist/runners/selfbuilt-wine11.18-arm64-r1}
pins=$root/ci/runner-b-inputs.json
dl=$root/downloads
kk=$root/build/kosmickrisp/out
WINEBUILD=${WINEBUILD:-$root/build/wine-tools/tools/winebuild/winebuild}
die() { echo "package-runner-b-dx12: $*" >&2; exit 1; }

[ -f "$OUT/runner.json" ] || die "no runner.json in $OUT"
grep -q '"arch": "arm64"' "$OUT/runner.json" || die "$OUT is not an arm64 runner"
[ -f "$kk/lib/libvulkan_kosmickrisp.dylib" ] || die "build KosmicKrisp first (scripts/build-kosmickrisp.sh)"
[ -x "$WINEBUILD" ] || die "no winebuild at $WINEBUILD"
loader=$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib
[ -f "$loader" ] || die "no Homebrew vulkan-loader"

verify() {   # pin key, file
	local want got
	want=$(plutil -extract "$1.sha256" raw "$pins")
	got=$(shasum -a 256 "$2" | cut -d' ' -f1)
	[ "$want" = "$got" ] || die "$2: sha256 $got, pinned $want"
}
verify vkd3d-proton "$dl/vkd3d-proton-3.0.1.tar.zst"
verify dxvk "$dl/dxvk-3.1.1.tar.gz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
zstd -q -dc "$dl/vkd3d-proton-3.0.1.tar.zst" | tar -xf - -C "$tmp"
tar -xzf "$dl/dxvk-3.1.1.tar.gz" -C "$tmp"

R=$OUT/lib/renderers
rm -rf "$R/kosmickrisp" "$R/vkd3d-proton" "$R/dxvk"

# --- KosmicKrisp + loader
mkdir -p "$R/kosmickrisp/lib" "$R/kosmickrisp/icd.d" "$R/kosmickrisp/vklib"
cp "$kk/lib/libvulkan_kosmickrisp.dylib" "$R/kosmickrisp/lib/"
cp "$kk/icd.d/kosmickrisp_icd.json" "$R/kosmickrisp/icd.d/"
cp "$kk/KOSMICKRISP.txt" "$R/kosmickrisp/"
cp "$loader" "$R/kosmickrisp/vklib/libMoltenVK.dylib"
chmod u+w "$R/kosmickrisp/vklib/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$R/kosmickrisp/vklib/libMoltenVK.dylib" 2> /dev/null
codesign --force -s - "$R/kosmickrisp/vklib/libMoltenVK.dylib" 2> /dev/null
echo "vulkan-loader $(brew list --versions vulkan-loader | cut -d' ' -f2) (Homebrew, Apache-2.0), installed as libMoltenVK.dylib" \
	> "$R/kosmickrisp/vklib/VERSION.txt"

# --- PE renderers, marked builtin (the run script prepends them to WINEDLLPATH)
put() {   # renderer, arch dir, source dir
	mkdir -p "$R/$1/$2"
	cp "$3"/*.dll "$R/$1/$2/"
	for f in "$R/$1/$2"/*.dll; do "$WINEBUILD" --builtin "$f"; done
}
put vkd3d-proton aarch64-windows "$tmp/vkd3d-proton-3.0.1/x64"
put vkd3d-proton i386-windows "$tmp/vkd3d-proton-3.0.1/x86"
put dxvk aarch64-windows "$tmp/dxvk-3.1.1/x64"
put dxvk i386-windows "$tmp/dxvk-3.1.1/x32"

# --- runner.json: edit the one "renderers" line in place (never reformat the file: compat_run
# matches "kind": "selfbuilt" textually)
python3 - "$OUT/runner.json" << 'EOF'
import json, re, sys
p = sys.argv[1]
t = open(p).read()
m = re.search(r'^(\s*"renderers": )(\{.*\}),?$', t, re.M)
if not m:
    sys.exit("runner.json: no single-line renderers entry")
r = json.loads(m.group(2))
r.update({"kosmickrisp": "mesa-ce576c29+steamac-ed06800b", "vkd3d-proton": "3.0.1", "dxvk": "3.1.1"})
line = m.group(1) + json.dumps(r) + ("," if m.group(0).rstrip().endswith(",") else "")
open(p, "w").write(t[:m.start()] + line + t[m.end():])
EOF
grep -q '"kind": "selfbuilt"' "$OUT/runner.json" || die "runner.json lost its kind line"

echo "Vulkan renderers in $R:"
du -sh "$R/kosmickrisp" "$R/vkd3d-proton" "$R/dxvk"
grep '"renderers"' "$OUT/runner.json"
