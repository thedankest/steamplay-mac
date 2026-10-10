#!/bin/bash
# Compare FEX modules by hand, outside Steam: tsoprobe (x64, i386) and d3dprobe (x64, i386,
# DXMT) on one runner directory, in a fresh prefix under build/fex-test/<label>/. Steam and the
# installed runners are not touched. Run it on the Hangover runner and on a scratch runner
# assembled with FEX_DLLS_DIR=build/fex-darwin/out/dlls, then compare the two summaries.
#
#   tests/try-fex-darwin.sh dist/runners/selfbuilt-wine11.18-arm64-r1 hangover
#   tests/try-fex-darwin.sh dist/runners/scratch-fexdarwin fexdarwin
#
# Needs: tests/{tsoprobe,tsoprobe32,d3dprobe,d3dprobe32,cpuprobe,cpuprobe32}.exe (make -C tests). Exit 1 if a probe
# fails or tsoprobe sees TSO violations.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { echo "usage: $0 <runner dir> [label]" >&2; exit 2; }
R=$(cd "$1" && pwd); label=${2:-$(basename "$R")}
T=$root/build/fex-test/$label
mkdir -p "$T/app"
cp "$root"/tests/{tsoprobe,tsoprobe32,d3dprobe,d3dprobe32,cpuprobe,cpuprobe32}.exe "$T/app/"
export WINEPREFIX=$T/pfx WINELOADER=$R/lib/wine/aarch64-unix/wine WINESERVER=$R/bin/wineserver-arm64
export WINEDLLPATH=$R/lib/wine/aarch64-windows:$R/lib/wine/aarch64-unix WINEDEBUG=-all
[ -x "$WINELOADER" ] && [ -x "$WINESERVER" ] || { echo "no loader/server in $R" >&2; exit 2; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
rc=0
summary=()
note() { summary+=("$1"); echo ">> $1"; }

echo ">> runner: $R"
grep -E '"(fex|id|loader_source)"' "$R/runner.json" | sed 's/^/   /'
rm -rf "$WINEPREFIX"
t0=$(now_ms); "$WINELOADER" wineboot --init >"$T/wineboot.log" 2>&1; "$WINESERVER" -w; t1=$(now_ms)
note "wineboot --init (fresh prefix): $((t1 - t0)) ms"

cd "$T/app"
# which emulator DLLs actually load (first x64 and first i386 process)
WINEDEBUG=+loaddll "$WINELOADER" tsoprobe.exe --no-litmus --compute 1 2>&1 | grep -i -E 'xtajit|fex' | head -3 | sed 's/^/   /' || true
WINEDEBUG=+loaddll "$WINELOADER" tsoprobe32.exe --no-litmus --compute 1 2>&1 | grep -i -E 'xtajit|fex' | head -3 | sed 's/^/   /' || true

for p in tsoprobe.exe tsoprobe32.exe; do
    t0=$(now_ms); out=$("$WINELOADER" "$p" 2>&1) || { [ $? = 1 ] && note "$p: TSO VIOLATIONS" && rc=1 || { note "$p: FAILED ($?)"; rc=1; }; }
    t1=$(now_ms)
    echo "$out" | sed 's/^/   /'
    v=$(echo "$out" | sed -n 's/.*violations=\([0-9]*\).*/\1/p'); c=$(echo "$out" | sed -n 's/^compute:.*ms=\([0-9.]*\).*/\1/p')
    note "$p: violations=${v:-?} compute=${c:-?} ms, wall $((t1 - t0)) ms"
done

# CPU features as the guest sees them, without FEX_HOSTFEATURES: SSE4.2 and AES follow the CP xxxx
# ID-register values wineboot publishes (patches/runner-b/0025 on macOS; zero without it).
unset FEX_HOSTFEATURES
note "CP 4030 (ID_AA64ISAR0_EL1): $("$WINELOADER" reg query 'HKLM\\Hardware\\Description\\System\\CentralProcessor\\0' /v 'CP 4030' 2>/dev/null | sed -n 's/.*REG_QWORD *//p' | tr -d '\r' | head -1)"
for p in cpuprobe.exe cpuprobe32.exe; do
    out=$("$WINELOADER" "$p" 2>&1) || true
    note "$p: $(echo "$out" | grep -o 'sse4.2=[01].*avx=[01]' | head -1) $(echo "$out" | grep -o 'PF .*' | head -1)"
done

for p in d3dprobe.exe d3dprobe32.exe; do
    out=$("$WINELOADER" "$p" 11 2>&1) || true
    note "$p wined3d: $(echo "$out" | grep -i -E 'feature level|hr=' | head -1 | tr -s ' ')"
done
if [ -d "$R/lib/renderers/dxmt" ]; then
    export WINEDLLPATH_PREPEND=$R/lib/renderers/dxmt
    for p in d3dprobe.exe d3dprobe32.exe; do
        out=$("$WINELOADER" "$p" 11 2>&1) || true
        note "$p DXMT: $(echo "$out" | grep -i -E 'feature level|hr=' | head -1 | tr -s ' ')"
    done
    t0=$(now_ms); out=$("$WINELOADER" d3dprobe.exe --present 300 2>&1) || { note "d3dprobe --present 300 FAILED"; rc=1; }
    t1=$(now_ms)
    note "d3dprobe.exe DXMT --present 300: $(echo "$out" | grep -i -E 'frames|present' | tail -1 | tr -s ' ') wall $((t1 - t0)) ms"
    unset WINEDLLPATH_PREPEND
else
    note "no lib/renderers/dxmt in this runner: DXMT probes skipped"
fi
"$WINESERVER" -k || true
echo
echo "==== summary ($label) ===="
printf '%s\n' "${summary[@]}" | tee "$T/summary.txt"
exit $rc
