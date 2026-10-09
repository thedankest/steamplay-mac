#!/bin/bash
# Adds D3DMetal (Apple Game Porting Toolkit 3.0, Gcenx's repack) to an assembled runner.
# Apple's licence allows personal, non-commercial use on Apple hardware, so D3DMetal is never
# committed or put in a CI tarball; it is fetched on the user's Mac, hash-checked, and only
# installed once the user has accepted the licence.
#
# Usage: scripts/install-d3dmetal.sh <runner-dir>
# Licence: shown and asked for on a terminal; D3DMETAL_ACCEPT_LICENSE=1 means the user has
# already read and accepted it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: $0 <runner-dir>}"
DL="${D3DMETAL_CACHE:-$ROOT/downloads}"
URL=https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz
SHA=d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e
TARBALL="$DL/game-porting-toolkit-3.0-3.tar.xz"

[ -x "$OUT/bin/wine" ] || { echo "$OUT is not a runner (no bin/wine)" >&2; exit 1; }

mkdir -p "$DL"
[ -f "$TARBALL" ] || { curl -fsSL -o "$TARBALL.part" "$URL" && mv "$TARBALL.part" "$TARBALL"; }
echo "$SHA  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "GPTK tarball hash mismatch" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xJf "$TARBALL" -C "$WORK"
APP="$WORK/Game Porting Toolkit.app/Contents/Resources"
g="$APP/wine/lib"

if [ "${D3DMETAL_ACCEPT_LICENSE:-0}" != 1 ]; then
    [ -t 0 ] || { echo "D3DMetal licence not accepted: run on a terminal, or set D3DMETAL_ACCEPT_LICENSE=1 after reading $APP/License.rtf" >&2; exit 2; }
    textutil -convert txt -stdout "$APP/License.rtf" 2>/dev/null | ${PAGER:-less}
    printf 'Accept Apple'"'"'s Game Porting Toolkit licence (personal, non-commercial, Apple hardware)? [yes/no] '
    read -r answer
    [ "$answer" = yes ] || { echo "not accepted; D3DMetal not installed" >&2; exit 2; }
fi

rm -rf "$OUT/lib/external/D3DMetal.framework" "$OUT/lib/renderers/d3dmetal"
mkdir -p "$OUT/lib/external"
cp -R "$g/external/D3DMetal.framework" "$OUT/lib/external/"
cp -f "$g/external/libd3dshared.dylib" "$OUT/lib/external/"
R="$OUT/lib/renderers/d3dmetal"
mkdir -p "$R/x86_64-windows" "$R/x86_64-unix"
for d in d3d10 d3d11 d3d12 dxgi nvapi64 atidxx64; do
    cp "$g/wine/x86_64-windows/$d.dll" "$R/x86_64-windows/$d.dll"
    ln -s ../../../external/libd3dshared.dylib "$R/x86_64-unix/$d.so"
done
# DLSS -> MetalFX: the MetalFX NGX shim takes nvngx's place (as the MacPorts d3dmetal port does)
cp "$g/wine/x86_64-windows/nvngx-on-metalfx.dll" "$R/x86_64-windows/nvngx.dll"
ln -s ../../../external/libd3dshared.dylib "$R/x86_64-unix/nvngx.so"
cp "$APP/License.rtf" "$OUT/lib/external/D3DMetal-License.rtf" 2>/dev/null || true

# Edit the one line in place: compat_run.sh recognises a self-built runner by the literal
# text '"kind": "selfbuilt"', so the file keeps assemble-runner.sh's formatting.
[ -f "$OUT/runner.json" ] && ! grep -q '"d3dmetal"' "$OUT/runner.json" &&
    sed -i '' 's/"renderers": { "dxmt": "v0.80" }/"renderers": { "dxmt": "v0.80", "d3dmetal": "3.0" }/' "$OUT/runner.json"
echo "D3DMetal 3.0 installed into $OUT"
