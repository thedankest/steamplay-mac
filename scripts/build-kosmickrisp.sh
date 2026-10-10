#!/bin/bash
# Build KosmicKrisp (Mesa's Vulkan driver on Metal 4) with steamac's patch series, for Runner B DX12
# (vkd3d-proton -> winevulkan -> Khronos loader -> KosmicKrisp -> Metal).
#
#   scripts/build-kosmickrisp.sh [unpack|clc|driver|stage|all]   (default: all)
#
# Recipe follows fxgl/steamac host/kosmickrisp/build.sh (Apache-2.0) at ed06800b: Mesa main ce576c29
# + host/kosmickrisp/patches/0001-0040. Two meson builds: (1) mesa_clc + vtn_bindgen2 against Homebrew
# LLVM and SPIRV-LLVM-Translator; (2) the driver with -Dllvm=disabled -Dmesa-clc=system.
# Inputs are pinned in ci/runner-b-inputs.json (kosmickrisp section); run throttled:
#   taskpolicy -b nice -n 19 scripts/build-kosmickrisp.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dl=$root/downloads
work=$root/build/kosmickrisp
out=$work/out
MESA_COMMIT=ce576c29ed90822ea15564e1e60cb48e455881bb
MESA_SHA256=fe1e5808befb45e619358c6f911f3f1484c5bd693f44e8aa6d989fa3fb01c51e
PATCHDIR=$dl/kosmickrisp-patches-ed06800b
PATCHES_SHA256=3c9b6d1fe7bd14a01afc1ca69f3f8d638d2f47c26edfd170ea9cbe9acd2d06bb   # of the .sha256 list
MAKO_VERSION=1.3.10 PYYAML_VERSION=6.0.3 PACKAGING_VERSION=25.0
JOBS=${JOBS:-4}
src=$work/src clc=$work/clc

llvm=$(brew --prefix llvm)

unpack() {
	echo "$MESA_SHA256  $dl/mesa-$MESA_COMMIT.tar.gz" | shasum -a 256 -c -
	echo "$PATCHES_SHA256  $dl/kosmickrisp-patches-ed06800b.sha256" | shasum -a 256 -c -
	(cd "$PATCHDIR" && shasum -a 256 -c --quiet "$dl/kosmickrisp-patches-ed06800b.sha256")
	rm -rf "$src"; mkdir -p "$src"
	tar -xzf "$dl/mesa-$MESA_COMMIT.tar.gz" -C "$src" --strip-components=1
	for p in "$PATCHDIR"/*.patch; do
		echo ">> apply $(basename "$p")"
		(cd "$src" && GIT_CEILING_DIRECTORIES="$work" git apply --whitespace=nowarn "$p")  # never inside the steamplay-mac repo: it would skip paths
	done
	if [ ! -x "$work/venv/bin/python3" ]; then
		"$(brew --prefix python@3.14)/bin/python3.14" -m venv "$work/venv"
	fi
	"$work/venv/bin/pip" -q install "mako==$MAKO_VERSION" "pyyaml==$PYYAML_VERSION" "packaging==$PACKAGING_VERSION"
}

build_clc() {
	rm -rf "$work/build-clc" "$clc"
	PATH="$work/venv/bin:$PATH:$llvm/bin" meson setup "$work/build-clc" "$src" \
		--prefix="$clc" --buildtype=release -Db_ndebug=true \
		-Dplatforms= -Dvulkan-drivers= -Dgallium-drivers= -Dopengl=false -Dglx=disabled \
		-Degl=disabled -Dgbm=disabled -Dzstd=disabled \
		-Dllvm=enabled -Dshared-llvm=enabled \
		-Dmesa-clc=enabled -Dinstall-mesa-clc=true \
		-Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true
	PATH="$work/venv/bin:$PATH:$llvm/bin" ninja -j"$JOBS" -C "$work/build-clc" install
}

build_driver() {
	if [ ! -d "$work/build" ]; then
		PATH="$clc/bin:$work/venv/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 meson setup "$work/build" "$src" \
			--buildtype=release -Db_ndebug=true \
			-Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false \
			-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dzstd=disabled -Dexpat=disabled \
			-Dllvm=disabled -Dspirv-tools=disabled -Dmesa-clc=system -Dprecomp-compiler=enabled \
			-Dbuild-tests=false -Dstrip=false
	fi
	PATH="$clc/bin:$work/venv/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 ninja -j"$JOBS" -C "$work/build"
}

stage() {
	built=$work/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib
	mkdir -p "$out/lib" "$out/icd.d"
	cp "$built" "$out/lib/libvulkan_kosmickrisp.dylib.tmp"
	install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$out/lib/libvulkan_kosmickrisp.dylib.tmp"
	if otool -L "$out/lib/libvulkan_kosmickrisp.dylib.tmp" | sed 1,2d | grep -qv -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/'; then
		echo "libvulkan_kosmickrisp links non-system libraries" >&2; otool -L "$out/lib/libvulkan_kosmickrisp.dylib.tmp" >&2; exit 1
	fi
	nm -gU "$out/lib/libvulkan_kosmickrisp.dylib.tmp" | grep -q ' _vk_icdGetInstanceProcAddr$'
	codesign --force -s - "$out/lib/libvulkan_kosmickrisp.dylib.tmp"
	mv -f "$out/lib/libvulkan_kosmickrisp.dylib.tmp" "$out/lib/libvulkan_kosmickrisp.dylib"
	# library_path is relative to the json (Khronos loader resolves it against the manifest's directory)
	printf '{"file_format_version": "1.0.1", "ICD": {"library_path": "../lib/libvulkan_kosmickrisp.dylib", "api_version": "1.4.0"}}\n' \
		> "$out/icd.d/kosmickrisp_icd.json"
	{
		echo "KosmicKrisp for steamplay-mac Runner B"
		echo "mesa:     $MESA_COMMIT ($MESA_SHA256)"
		echo "patches:  fxgl/steamac ed06800b host/kosmickrisp/patches 0001-0040 (list sha $PATCHES_SHA256)"
		echo "xcode:    $(xcodebuild -version | tr '\n' ' ')"
		echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$out/KOSMICKRISP.txt"
	ls -l "$out/lib"
}

case ${1:-all} in
unpack) unpack ;;
clc) build_clc ;;
driver) build_driver ;;
stage) stage ;;
all) unpack; build_clc; build_driver; stage ;;
*) echo "usage: $0 [unpack|clc|driver|stage|all]" >&2; exit 2 ;;
esac
