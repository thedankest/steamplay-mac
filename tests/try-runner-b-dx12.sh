#!/bin/bash
# Try Runner B's DX12 route by hand, outside Steam: vkd3d-proton (d3d12) + DXVK (dxgi, d3d11)
# on KosmicKrisp, in a test prefix. Steam and the installed runners are not touched.
#
#   tests/try-runner-b-dx12.sh                 DX12 window test, 300 frames (d3dprobe --present12)
#   tests/try-runner-b-dx12.sh dx11            DX11 window test through DXVK
#
# Needs: build/kosmickrisp/out (scripts/build-kosmickrisp.sh), build/vkd3d-proton, build/dxvk, tests/d3dprobe.exe.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
R=$root/dist/runners/selfbuilt-wine11.18-arm64-r1
T=$root/build/dx12-test
mkdir -p "$T/vklib" "$T/app"
# winevulkan dlopens libMoltenVK.dylib; point that name at the Khronos loader, which loads KosmicKrisp
ln -sf "$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib" "$T/vklib/libMoltenVK.dylib"
cp "$root"/build/vkd3d-proton/vkd3d-proton-3.0.1/x64/d3d12*.dll "$root"/build/dxvk/dxvk-3.1.1/x64/{dxgi,d3d11}.dll "$T/app/"
cp "$root/tests/d3dprobe.exe" "$T/app/"

export WINEPREFIX=$T/pfx WINESERVER=$R/bin/wineserver-arm64 WINEDEBUG=-all
export DYLD_LIBRARY_PATH=$T/vklib VK_DRIVER_FILES=$root/build/kosmickrisp/out/icd.d/kosmickrisp_icd.json
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi,d3d11=n;winedbg.exe=d" VKD3D_DEBUG=err DXVK_LOG_LEVEL=warn
[ -d "$WINEPREFIX" ] || { echo ">> creating the test prefix (first run only)"; "$R/lib/wine/aarch64-unix/wine" wineboot --init; "$WINESERVER" -w; }

case ${1:-dx12} in
dx12) cd "$T/app"; exec "$R/lib/wine/aarch64-unix/wine" d3dprobe.exe --present12 300 ;;
dx11) cd "$T/app"; exec "$R/lib/wine/aarch64-unix/wine" d3dprobe.exe --present 300 ;;
*) echo "usage: $0 [dx12|dx11]" >&2; exit 2 ;;
esac
