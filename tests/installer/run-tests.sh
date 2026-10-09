#!/bin/bash
# Installer tests against a fake world in a temp dir: a fake Steam.app (tiny Mach-O stubs,
# Info.plist, ad-hoc signed), a fake inner client, a fake dist runner and Valve manifest.
# Runs scripts/install.sh in test mode (NP_TEST_MODE=1), which refuses any path outside the
# temp dir and replaces Steam control, the support build, the bridge fetch, D3DMetal and
# lsregister with the stubs in tests/installer/stubs. Nothing outside the temp dir is touched:
# not /Applications/Steam.app, not ~/Library/Application Support/{Steam,notproton}, not
# ~/SteamPlayBackup, not launchd.
#
# Usage: tests/installer/run-tests.sh [-k] [test-name ...]   (-k keeps the temp dir)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INSTALL="$REPO/scripts/install.sh"
STUBS="$HERE/stubs"
KEEP=0
if [ "${1:-}" = -k ]; then KEEP=1; shift; fi
ONLY="$*"

T="$(mktemp -d "${TMPDIR:-/tmp}/np-installer-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
cleanup() { if [ "$KEEP" = 1 ]; then echo "kept: $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT

PASS=0 FAIL=0 FAILED_NAMES=""
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $CUR"; printf '  FAIL  %s\n' "$1"; [ -f "$T/out/err" ] && sed 's/^/        | /' "$T/out/err" | tail -15; return 0; }
check() { # description command...
    local d="$1"
    shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
eq() { [ "$1" = "$2" ] || { echo "        expected '$2', got '$1'" >&2; return 1; }; }

# --- binaries ------------------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/out"
printf 'int main(void){return 0;}\n' > "$T/bin/stub.c"
clang -arch arm64 -O1 -o "$T/bin/stub" "$T/bin/stub.c"
printf 'int np_variant_a(void){return 1;}\n' > "$T/bin/a.c"
printf 'int np_variant_b(void){return 2;}\n' > "$T/bin/b.c"
clang -arch arm64 -dynamiclib -o "$T/bin/notproton-a.dylib" "$T/bin/a.c"
clang -arch arm64 -dynamiclib -o "$T/bin/notproton-b.dylib" "$T/bin/b.c"

# Independent of the installer's implementation: sha256 over sorted "<sha>  <path>" lines for
# files and "L <target>  <path>" for symlinks.
tree_hash() {
    ( cd "$1" && {
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
        find . -type l | LC_ALL=C sort | while IFS= read -r p; do printf 'L %s  %s\n' "$(readlink "$p")" "$p"; done
    } | LC_ALL=C sort | shasum -a 256 | cut -c1-64 )
}
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

make_fake_app() { # dir
    local a="$1"
    mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
    cp "$T/bin/stub" "$a/Contents/MacOS/steam_osx"
    cp "$T/bin/stub" "$a/Contents/MacOS/ipc server"
    echo "resource" > "$a/Contents/Resources/some file.txt"
    ln -s "some file.txt" "$a/Contents/Resources/link to file"
    cat > "$a/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>steam_osx</string>
<key>CFBundleIdentifier</key><string>test.fake.steam</string>
<key>CFBundleName</key><string>Steam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1788400362</string>
</dict></plist>
EOF
    codesign -f -s - "$a/Contents/MacOS/ipc server" 2>/dev/null
    codesign -f -s - "$a" 2>/dev/null
}

make_fake_runner() { # dir
    local r="$1"
    mkdir -p "$r/bin" "$r/lib/wine/x86_64-windows" "$r/lib/wine/i386-windows" "$r/lib/wine/x86_64-unix" "$r/share/steamplay"
    printf '#!/bin/sh\necho wine-11.0\n' > "$r/bin/wine"
    chmod 755 "$r/bin/wine"
    printf '{\n  "id": "%s",\n  "kind": "selfbuilt",\n  "renderers": { "dxmt": "v0.80" }\n}\n' "${r##*/}" > "$r/runner.json"
    echo lsc64 > "$r/lib/wine/x86_64-windows/lsteamclient.dll"
    echo lsc32 > "$r/lib/wine/i386-windows/lsteamclient.dll"
    echo lscso > "$r/lib/wine/x86_64-unix/lsteamclient.so"
    echo steamexe > "$r/share/steamplay/steam.exe"
    echo lib > "$r/lib/libfoo.1.dylib"
    ln -s libfoo.1.dylib "$r/lib/libfoo.dylib"
    echo space > "$r/lib/a file with space.txt"
}

# A fresh world per test.
new_world() {
    W="$T/w-$CUR"
    rm -rf "$W" "$T/ctl"
    mkdir -p "$W" "$T/ctl"
    export NP_TEST_MODE=1 NP_TEST_ROOT="$T" NP_TEST_REPO="$REPO"
    export NP_HOME="$W/home"
    export NP_STEAM_APP="$W/Applications Dir/Steam.app"
    export NP_STEAM_SUPPORT="$NP_HOME/Library/Application Support/Steam"
    export NP_SUPPORT="$NP_HOME/Library/Application Support/notproton"
    export NP_BACKUP_DIR="$NP_HOME/SteamPlayBackup"
    export NP_CACHE="$W/cache"
    export NP_DIST_DIR="$W/dist/runners"
    export NP_LAUNCH_AGENTS="$NP_HOME/Library/LaunchAgents"
    export NP_RUNNER_ID=selfbuilt-test-r1
    export NP_TEST_STEAMCTL="$STUBS/steamctl" NP_TEST_BUILD_SUPPORT="$STUBS/build-support"
    export NP_TEST_FETCH_BRIDGE="$STUBS/fetch-bridge" NP_TEST_D3DMETAL_SCRIPT="$STUBS/d3dmetal"
    export NP_TEST_VALVE_MANIFEST="$W/valve.manifest"
    export NP_POLL_INTERVAL=0.1 NP_QUIT_TIMEOUT=2 NP_VERIFY_TIMEOUT=2 NP_MIN_FREE_GB=1
    unset NP_TEST_FAIL_AT NP_TEST_FAIL_SIGNAL NP_CONFIRM_TOKEN NP_PROGRESS_FD NP_ADOPT_BACKUP NP_TEST_RUNNER_LOCK \
          NP_TEST_GPTK_DMG_KNOWN NP_TEST_APPLE_LICENSES NP_GPTK_DMG || true

    make_fake_app "$NP_STEAM_APP"
    ORIG_HASH="$(tree_hash "$NP_STEAM_APP")"
    ORIG_CD="$(cdhash "$NP_STEAM_APP")"
    export NP_TEST_TEAMID_OVERRIDE="MXGJJ98X76@$ORIG_CD"

    local inner="$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents"
    mkdir -p "$inner/MacOS"
    echo "steamclient v1" > "$inner/MacOS/steamclient.dylib"
    echo "steamui v1" > "$inner/MacOS/steamui.dylib"
    cp "$NP_STEAM_APP/Contents/Info.plist" "$inner/Info.plist"
    printf 'SomeUserSetting=1\n' > "$NP_STEAM_SUPPORT/steam.cfg"
    ORIG_CFG="$(cat "$NP_STEAM_SUPPORT/steam.cfg")"

    make_fake_runner "$NP_DIST_DIR/selfbuilt-test-r1"
    {
        echo "base     file:///nonexistent"
        for rel in legacycompat/steamclient.dll steamclient.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll; do
            printf 'file %s linux %s %s\n' "$rel" "$rel" "$(printf 'fake valve %s\n' "$rel" | shasum -a 256 | cut -c1-64)"
        done
    } > "$NP_TEST_VALVE_MANIFEST"
    echo pass > "$T/ctl/anchor-mode"
    echo good > "$T/ctl/log-mode"
    echo accept > "$T/ctl/d3d-mode"
    echo a > "$T/ctl/dylib-variant"
}

# inst [VAR=value ...] -- args : runs install.sh, stdout/stderr in $T/out, status in RC
inst() {
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    RC=0
    env ${envs[@]+"${envs[@]}"} bash "$INSTALL" "$@" > "$T/out/out" 2> "$T/out/err" < /dev/null || RC=$?
    cp "$T/out/out" "$T/out/last-$CUR.out"
    cp "$T/out/err" "$T/out/last-$CUR.err"
}
st() { jq -r "$1" "$NP_SUPPORT/install-state.json"; }
app_is_original() {
    eq "$(tree_hash "$NP_STEAM_APP")" "$ORIG_HASH" && codesign --verify --deep --strict "$NP_STEAM_APP" 2>/dev/null \
        && eq "$(cdhash "$NP_STEAM_APP")" "$ORIG_CD"
}
app_patched() {
    eq "$(plutil -extract LSEnvironment.DYLD_INSERT_LIBRARIES raw -o - "$NP_STEAM_APP/Contents/Info.plist" 2>/dev/null)" "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" \
        && codesign --verify --deep --strict "$NP_STEAM_APP" 2>/dev/null
}
want() { [ -z "$ONLY" ] || case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
begin() { CUR="$1"; echo "== $1"; new_world; }
YES=(NP_TEST_ANSWER_PLAN=yes NP_TEST_ANSWER_START_STEAM=yes NP_TEST_ANSWER_UNINSTALL=yes)

# ================================================================================================
if want install_cycle; then
    begin install_cycle
    touch "$T/ctl/steam-running"
    inst "${YES[@]}" NP_PROGRESS_FD=1 -- all --from dist
    check "all --from dist exits 0" eq "$RC" 0
    check "Steam was asked to quit" grep -qx quit "$T/ctl/steamctl.log"
    check "Steam.app patched and its ad-hoc signature verifies" app_patched
    check "journal done" eq "$(st .journal.state)" "done"
    check "verify passed from notproton.log" eq "$(st .verify.result)" pass
    bk="$(st .steam.active_backup)"
    check "backup recorded and identical to the original (tree hash)" eq "$(tree_hash "$bk")" "$ORIG_HASH"
    check "backup's recorded tree hash = original" eq "$(st '.steam.original.tree_sha256')" "$ORIG_HASH"
    check "backup signature verifies" codesign --verify --deep --strict "$bk"
    check "outer steam.cfg blocks updates, keeps user line" grep -qx 'SomeUserSetting=1' "$NP_STEAM_SUPPORT/steam.cfg"
    check "outer steam.cfg has the block line" grep -qx 'BootStrapperInhibitUpdateOnLaunch=enable' "$NP_STEAM_SUPPORT/steam.cfg"
    check "outer .orig kept" eq "$(cat "$NP_STEAM_SUPPORT/steam.cfg.orig")" "$ORIG_CFG"
    check "inner steam.cfg blocks updates" grep -qx 'BootStrapperInhibitUpdateOnLaunch=enable' "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"
    check "runners/current -> selfbuilt-test-r1" eq "$(readlink "$NP_SUPPORT/runners/current")" selfbuilt-test-r1
    check "runner manifest verifies" bash -c 'cd "$1" && shasum -a 256 -c --quiet "$2"' _ "$NP_SUPPORT/runners/selfbuilt-test-r1" "$NP_SUPPORT/runners/selfbuilt-test-r1.files.sha256"
    check "runner symlink kept" eq "$(readlink "$NP_SUPPORT/runners/selfbuilt-test-r1/lib/libfoo.dylib")" libfoo.1.dylib
    check "D3DMetal installed with hashes" test -f "$NP_SUPPORT/runners/selfbuilt-test-r1/lib/external/D3DMetal.files.sha256"
    check "bridge has Valve and runner files" test -f "$NP_SUPPORT/bridge/tier0_s64.dll" -a -f "$NP_SUPPORT/bridge/x86_64-unix/lsteamclient.so"
    check "state file is mode 600" eq "$(stat -f %Lp "$NP_SUPPORT/install-state.json")" 600
    check "gate recorded 17/17" eq "$(st '.client.gate | "\(.resolved)/\(.required) \(.result)"')" "17/17 pass"
    check "gate found the live client build 1788400362" eq "$(st .client.binary_build)" 1788400362
    check "only the live profile is installed (so the dylib loads it)" eq "$(ls "$NP_SUPPORT/signatures/macos.arm64" | tr '\n' ' ')" "1788400362.json "
    check "fixes installed" test -f "$NP_SUPPORT/fixes/686060.sh"
    check "autofix installed with its manifest" bash -c 'cd "$1/autofix" && test -f autofix.sh -a -f helpers.sh -a -f verbs.json -a -f NOTICE.umu-protonfixes && ls *.py >/dev/null && shasum -a 256 -c --quiet autofix.files.sha256' _ "$NP_SUPPORT"
    check "autofix version recorded" bash -c 'grep -q "^autofix [0-9a-f]\{12\} (repo " "$1/autofix/VERSION" && [ "$(jq -r .support.autofix.version "$1/install-state.json")" = "$(cat "$1/autofix/VERSION")" ]' _ "$NP_SUPPORT"
    check "global.env defaults written" bash -c 'grep -qx ROSETTA_ADVERTISE_AVX=1 "$1" && grep -qx WINEMSYNC=1 "$1"' _ "$NP_SUPPORT/global.env"
    check "events: every stdout line is JSON or human text, result ok" bash -c 'grep "^{" "$1" | jq -e -s "map(select(.event==\"result\"))[-1].status == \"ok\"" >/dev/null' _ "$T/out/out"
    check "events: gate step reported ok" bash -c 'grep "^{" "$1" | jq -e -s "any(.event==\"step\" and .id==\"gate\" and .status==\"ok\")" >/dev/null' _ "$T/out/out"

    inst -- doctor --json
    check "doctor --json exits 0 (all OK)" eq "$RC" 0
    check "doctor --json is one document with schema 1" bash -c 'jq -e ".event==\"doctor\" and .schema==1 and (.checks|length) > 15" "$1" >/dev/null' _ "$T/out/out"
    [ "$RC" = 0 ] || jq -r '.checks[] | select(.verdict != "ok") | "        \(.id): \(.verdict) \(.detail)"' "$T/out/out"
    inst -- doctor --quick
    check "doctor --quick exits 0" eq "$RC" 0

    patched_hash="$(tree_hash "$NP_STEAM_APP")"
    inst "${YES[@]}" -- all --from dist
    check "second all is idempotent (exit 0)" eq "$RC" 0
    check "second all leaves Steam.app as it was" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
    check "second all reused the runner" grep -q 'unchanged' "$T/out/out"
    check "global.env defaults are not duplicated" bash -c '[ "$(grep -c "^WINEMSYNC=" "$1")" = 1 ] && [ "$(grep -c "^ROSETTA_ADVERTISE_AVX=" "$1")" = 1 ]' _ "$NP_SUPPORT/global.env"
    echo "# tampered" >> "$NP_SUPPORT/autofix/helpers.sh"
    inst -- doctor --json
    check "doctor reports a changed autofix file as FAIL" eq "$(jq -r '.checks[] | select(.id=="autofix") | .verdict' "$T/out/out")" fail
    inst "${YES[@]}" -- all --from dist
    check "all puts autofix back" bash -c 'cd "$1/autofix" && shasum -a 256 -c --quiet autofix.files.sha256 && ! grep -q tampered helpers.sh' _ "$NP_SUPPORT"

    inst -- reapply
    check "reapply with nothing changed: exit 0" eq "$RC" 0
    check "reapply reports unchanged" grep -q 'nothing changed' "$T/out/out"

    echo "steamclient v2" > "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
    rm -f "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"
    inst -- reapply
    check "reapply after a client change: exit 0" eq "$RC" 0
    check "reapply re-blocked the inner steam.cfg" grep -qx 'BootStrapperInhibitUpdateOnLaunch=enable' "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"
    check "reapply recorded the new client hash" eq "$(st .client.steamclient_sha256)" "$(shasum -a 256 "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib" | cut -c1-64)"
    check "reapply left Steam.app alone" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"

    echo "steamclient v3" > "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
    echo fail > "$T/ctl/anchor-mode"
    inst NP_PROGRESS_FD=1 -- reapply
    check "reapply with a failing gate: exit 1" eq "$RC" 1
    check "gate failure recorded" eq "$(st .client.gate.result)" fail
    check "gate failure notified" grep -q '"event":"notify"' "$T/out/out"
    check "gate failure changed nothing in Steam.app" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
    echo pass > "$T/ctl/anchor-mode"

    inst NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "uninstall exits 0" eq "$RC" 0
    check "PHASE 3 GATE: Steam.app tree hash, cdhash and signature equal the original" app_is_original
    check "Steam.app TeamID is Valve's again (via test override on the original cdhash)" bash -c '[ "$(codesign -dvvv "$1" 2>&1 | sed -n "s/^CDHash=//p")" = "$2" ]' _ "$NP_STEAM_APP" "$ORIG_CD"
    check "outer steam.cfg restored" eq "$(cat "$NP_STEAM_SUPPORT/steam.cfg")" "$ORIG_CFG"
    check "inner steam.cfg removed (was absent)" test ! -e "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"
    check "support files removed" test ! -e "$NP_SUPPORT/notproton.dylib" -a ! -e "$NP_SUPPORT/signatures" -a ! -e "$NP_SUPPORT/bridge" -a ! -e "$NP_SUPPORT/autofix"
    check "runners kept without --remove-runners" test -d "$NP_SUPPORT/runners/selfbuilt-test-r1"
    check "state archived" bash -c 'ls "$1"/state-archive/install-state.*.json >/dev/null' _ "$NP_SUPPORT"
    check "original backup kept" test -d "$bk"
    check "patched bundle kept in the backup dir" bash -c 'ls -d "$1"/Steam.app.patched-* >/dev/null' _ "$NP_BACKUP_DIR"
fi

# ================================================================================================
if want interrupted; then
    begin interrupted
    inst "${YES[@]}" NP_TEST_FAIL_AT=patch.after_plist -- all --from dist
    check "failure mid-patch: exit 1" eq "$RC" 1
    check "failure mid-patch: Steam.app restored to the original" app_is_original
    check "failure mid-patch: journal failed (not in_progress)" eq "$(st .journal.state)" failed
    check "failure mid-patch: no signatures installed (they come only after a patch)" test ! -e "$NP_SUPPORT/signatures"
    check "failure mid-patch: no leftover temp bundles" bash -c '! ls -a "$(dirname "$1")" | grep -q "^\.Steam"' _ "$NP_STEAM_APP"
    inst "${YES[@]}" NP_TEST_FAIL_AT=patch.after_sign NP_TEST_FAIL_SIGNAL=1 -- all --from dist
    check "Ctrl-C mid-patch: exit 130" eq "$RC" 130
    check "Ctrl-C mid-patch: Steam.app restored to the original" app_is_original
    inst "${YES[@]}" -- all --from dist
    check "a clean run after the failures succeeds" eq "$RC" 0
    check "and patches" app_patched
fi

# ================================================================================================
if want journal; then
    begin journal
    inst "${YES[@]}" -- all --from dist
    jq '.journal.state = "in_progress" | .journal.step = "patch" | .journal.op = "all"' "$NP_SUPPORT/install-state.json" > "$T/s.json"
    cp "$T/s.json" "$NP_SUPPORT/install-state.json"
    before="$(tree_hash "$NP_STEAM_APP")"
    inst "${YES[@]}" -- all --from dist
    check "journal in_progress blocks a new run (exit 1)" eq "$RC" 1
    check "with a clear message" grep -q "stopped at step 'patch'" "$T/out/err"
    check "and nothing changed" eq "$(tree_hash "$NP_STEAM_APP")" "$before"
    inst -- doctor --quick
    check "doctor reports the interrupted journal as FAIL (exit 1)" eq "$RC" 1
    inst -- reapply
    check "reapply is blocked too" eq "$RC" 1
    inst NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "uninstall still works and restores the original" bash -c '[ "$1" = 0 ]' _ "$RC"
    check "original restored" app_is_original
fi

# ================================================================================================
if want journal_clear; then
    begin journal_clear
    inst "${YES[@]}" -- all --from dist
    jq '.journal.state = "in_progress"' "$NP_SUPPORT/install-state.json" > "$T/s.json"
    cp "$T/s.json" "$NP_SUPPORT/install-state.json"
    inst -- journal-clear
    check "journal-clear without confirmation exits 3" eq "$RC" 3
    inst NP_TEST_ANSWER_JOURNAL_CLEAR=yes -- journal-clear
    check "journal-clear confirmed" eq "$(st .journal.state)" idle
fi

# ================================================================================================
if want foreign; then
    begin foreign
    echo changed > "$NP_STEAM_APP/Contents/Resources/some file.txt"
    codesign -f -s - "$NP_STEAM_APP" 2>/dev/null
    h="$(tree_hash "$NP_STEAM_APP")"
    inst "${YES[@]}" -- all --from dist
    check "a non-Valve Steam.app is refused (exit 1)" eq "$RC" 1
    check "refusal names it" grep -q "neither Valve's signed bundle" "$T/out/err"
    check "foreign Steam.app untouched" eq "$(tree_hash "$NP_STEAM_APP")" "$h"
    check "no backup made" test ! -d "$NP_BACKUP_DIR"

    rm -rf "$NP_STEAM_APP"
    make_fake_app "$NP_STEAM_APP"
    plutil -insert LSEnvironment -dictionary "$NP_STEAM_APP/Contents/Info.plist"
    plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string /tmp/other.dylib "$NP_STEAM_APP/Contents/Info.plist"
    codesign -f -s - "$NP_STEAM_APP" 2>/dev/null
    inst "${YES[@]}" -- all --from dist
    check "Steam.app with someone else's insert is refused" eq "$RC" 1
fi

# ================================================================================================
if want gate_fail; then
    begin gate_fail
    for m in fail garbage rcfail nolive wronglive twolive singlefail wrongpath; do
        echo "$m" > "$T/ctl/anchor-mode"
        inst "${YES[@]}" -- all --from dist
        check "gate mode '$m' stops the install (exit 1)" eq "$RC" 1
        check "gate mode '$m': Steam.app untouched, no backup" bash -c '[ "$1" = "$2" ] && [ ! -d "$3" ]' _ "$(tree_hash "$NP_STEAM_APP")" "$ORIG_HASH" "$NP_BACKUP_DIR"
    done
fi

# ================================================================================================
if want gui_tokens; then
    begin gui_tokens
    inst -- --json all --from dist
    check "--json without confirmation exits 3" eq "$RC" 3
    check "--json stdout is JSON lines only" bash -c 'jq -e -s "length > 3" "$1" >/dev/null' _ "$T/out/out"
    check "Steam.app untouched before confirmation" app_is_original
    tok="$(jq -r 'select(.event=="confirm" and .id=="plan") | .token' "$T/out/out")"
    check "confirm event carries a token" bash -c '[ ${#1} = 64 ]' _ "$tok"
    inst -- --json all --from dist --plan
    check "all --plan gives the same token" eq "$(jq -r 'select(.event=="plan") | .token' "$T/out/out")" "$tok"
    check "all --plan changes nothing" app_is_original
    inst -- --json --confirmed-plan 0000000000000000000000000000000000000000000000000000000000000000 all --from dist
    check "a wrong token does not confirm (exit 3)" eq "$RC" 3
    inst -- --json --confirmed-plan "$tok" all --from dist
    check "the right token confirms (exit 0)" eq "$RC" 0
    check "and Steam.app is patched" app_patched
    check "start_steam was not confirmed, so verify was skipped" eq "$(st .verify.result)" not_run
    check "result event ok" eq "$(jq -r 'select(.event=="result") | .status' "$T/out/out")" ok
    inst -- --json uninstall
    utok="$(jq -r 'select(.event=="confirm" and .id=="uninstall") | .token' "$T/out/out")"
    inst NP_CONFIRM_TOKEN="$utok" -- --json uninstall
    check "uninstall via NP_CONFIRM_TOKEN" eq "$RC" 0
    check "original restored" app_is_original
fi

# ================================================================================================
if want release; then
    begin release
    rel="$W/rel"
    mkdir -p "$rel"
    make_fake_runner "$rel/selfbuilt-test-r1"
    tar -C "$rel" -cf - selfbuilt-test-r1 | zstd -q -19 -o "$rel/runner.tar.zst"
    sha="$(shasum -a 256 "$rel/runner.tar.zst" | cut -c1-64)"
    printf '# test lock\nversion=selfbuilt-test-r1-abcdef12\nurl=file://%s\nsha256=%s\n' "$rel/runner.tar.zst" "$sha" > "$W/lock"
    echo decline > "$T/ctl/d3d-mode"
    inst "${YES[@]}" NP_TEST_RUNNER_LOCK="$W/lock" -- all --from release
    check "all --from release exits 0" eq "$RC" 0
    check "runner installed under the lock version" eq "$(readlink "$NP_SUPPORT/runners/current")" selfbuilt-test-r1-abcdef12
    check "tarball sha recorded" eq "$(st '.runners["selfbuilt-test-r1-abcdef12"].tarball_sha256')" "$sha"
    check "declined D3DMetal recorded, install continued" eq "$(st '.runners["selfbuilt-test-r1-abcdef12"].d3dmetal.status')" declined
    check "manifest written" test -f "$NP_SUPPORT/runners/selfbuilt-test-r1-abcdef12.files.sha256"

    printf 'version=x\nurl=file://%s\nsha256=\n' "$rel/runner.tar.zst" > "$W/lock-empty"
    inst "${YES[@]}" NP_TEST_RUNNER_LOCK="$W/lock-empty" -- all --from release
    check "a lock without sha256 is refused" eq "$RC" 1
    printf 'version=y\nurl=file://%s\nsha256=%s\n' "$rel/runner.tar.zst" "$(printf '0%.0s' $(seq 64))" > "$W/lock-bad"
    inst "${YES[@]}" NP_TEST_RUNNER_LOCK="$W/lock-bad" -- all --from release
    check "a hash mismatch is refused" eq "$RC" 1
    check "and leaves no .part file" bash -c '! ls "$1"/*.part 2>/dev/null | grep -q .' _ "$NP_CACHE"

    # D3DMetal licence via the GUI token: the stub requires D3DMETAL_LICENSE_SHA256.
    echo license > "$T/ctl/d3d-mode"
    inst NP_TEST_RUNNER_LOCK="$W/lock" -- --json all --from release
    ltok="$(jq -r 'select(.event=="confirm" and .id=="d3dmetal_license") | .token' "$T/out/out")"
    check "licence confirm event with the licence hash" eq "$ltok" "$(shasum -a 256 "$T/fake-License.rtf" | cut -c1-64)"
    inst NP_TEST_RUNNER_LOCK="$W/lock" NP_D3DMETAL_LICENSE_TOKEN="$ltok" NP_TEST_ANSWER_PLAN=yes -- all --from release
    check "with the licence token D3DMetal installs" eq "$(st '.runners["selfbuilt-test-r1-abcdef12"].d3dmetal.status')" installed
    # A later run without the token must keep the D3DMetal accepted above, not drop it.
    d3dsum="$(cat "$NP_SUPPORT/runners/selfbuilt-test-r1-abcdef12/lib/external/D3DMetal.files.sha256")"
    inst NP_TEST_RUNNER_LOCK="$W/lock" NP_TEST_ANSWER_PLAN=yes -- all --from release
    check "without the token the accepted D3DMetal is kept" eq "$(st '.runners["selfbuilt-test-r1-abcdef12"].d3dmetal.status')" kept
    check "and its files are unchanged" eq "$(cat "$NP_SUPPORT/runners/selfbuilt-test-r1-abcdef12/lib/external/D3DMetal.files.sha256" 2>/dev/null)" "$d3dsum"
    check "and doctor accepts them" bash -c 'cd "$1" && shasum -a 256 -c --quiet lib/external/D3DMetal.files.sha256' _ "$NP_SUPPORT/runners/selfbuilt-test-r1-abcdef12"

    # Archive validation, unit level.
    mk() { # name tar-args... -> $rel/<name>.tar.zst
        local n="$1"; shift
        ( cd "$rel/src" && tar -cf - "$@" ) | zstd -q -o "$rel/$n.tar.zst"
    }
    mkdir -p "$rel/src/top/sub"
    echo x > "$rel/src/top/sub/f"
    mk good top
    ln -s ../../../../etc/passwd "$rel/src/top/sub/escape"
    mk escape top
    rm "$rel/src/top/sub/escape"
    ln -s /etc/passwd "$rel/src/top/abs"
    mk abslink top
    rm "$rel/src/top/abs"
    mk dotdot -s ',^top,../top,' top
    mk absname -P -s ',^top,/tmp/top,' top
    mkdir -p "$rel/src/other"
    mk twotop top other
    for case in good:0 escape:1 abslink:1 dotdot:1 absname:1 twotop:1; do
        n="${case%%:*}" want_rc="${case##*:}"
        got=0
        ( export NP_TEST_MODE=1; ROOT="$REPO"; NP_RUN_LOG=""; NP_JSON=0; NP_EVENT_FD=""
          . "$REPO/scripts/lib/common.sh"; . "$REPO/scripts/lib/runner.sh"
          runner_validate_archive "$rel/$n.tar.zst" ) > /dev/null 2>&1 || got=1
        check "archive '$n' validation result $want_rc" eq "$got" "$want_rc"
    done
fi

# ================================================================================================
if want adopt; then
    begin adopt
    # Phase 1 on the real Mac: a full Valve backup, then a manual patch, no state file.
    mkdir -p "$NP_BACKUP_DIR"
    ditto "$NP_STEAM_APP" "$NP_BACKUP_DIR/Steam.app.2026-10-09-1955"
    ditto "$NP_STEAM_APP" "$NP_BACKUP_DIR/Steam.app.2026-10-08-235959"
    ditto "$NP_STEAM_APP" "$NP_BACKUP_DIR/Steam.app.badrestore-2026-10-11-000000"
    ditto "$NP_STEAM_APP" "$NP_BACKUP_DIR/Steam.app.2026-10-12-1200.partial"
    ditto "$NP_STEAM_APP" "$NP_BACKUP_DIR/Steam.app.2026-10-13-1200-copy"
    cp "$T/bin/notproton-a.dylib" "$NP_STEAM_APP/Contents/MacOS/notproton.dylib"
    plutil -insert LSEnvironment -dictionary "$NP_STEAM_APP/Contents/Info.plist"
    plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" "$NP_STEAM_APP/Contents/Info.plist"
    codesign -f -s - "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" 2>/dev/null
    codesign -f -s - "$NP_STEAM_APP/Contents/MacOS/steam_osx" 2>/dev/null
    codesign -f -s - "$NP_STEAM_APP" 2>/dev/null
    printf 'BootStrapperInhibitUpdateOnLaunch=enable\n' >> "$NP_STEAM_SUPPORT/steam.cfg"
    inst "${YES[@]}" -- all --from dist
    check "adoptable install exits 0" eq "$RC" 0
    check "the Phase 1 backup is adopted as the original" eq "$(st .steam.active_backup)" "$NP_BACKUP_DIR/Steam.app.2026-10-09-1955"
    check "a pre-patch snapshot was taken" bash -c 'ls -d "$1"/Steam.app.prepatch-* >/dev/null' _ "$NP_BACKUP_DIR"
    check "Steam.app patched" app_patched
    check ".orig does not keep the old block line" eq "$(cat "$NP_STEAM_SUPPORT/steam.cfg.orig")" "$ORIG_CFG"
    inst NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "uninstall after adoption: exit 0" eq "$RC" 0
    check "uninstall after adoption restores the original" app_is_original
    check "steam.cfg back to the user's own content" eq "$(cat "$NP_STEAM_SUPPORT/steam.cfg")" "$ORIG_CFG"
fi

# ================================================================================================
if want valve_update; then
    begin valve_update
    inst "${YES[@]}" -- all --from dist
    # Steam replaces Steam.app with Valve's bundle (here: the original again).
    rm -rf "$NP_STEAM_APP"
    ditto "$(st .steam.active_backup)" "$NP_STEAM_APP"
    touch "$T/ctl/steam-running"
    inst NP_TEST_DIALOG_ANSWER=none -- reapply --auto
    check "reapply --auto without an answer: exit 0" eq "$RC" 0
    check "and no change" app_is_original
    inst NP_TEST_DIALOG_ANSWER=yes -- reapply --auto
    check "reapply --auto with 'Re-apply': exit 0" eq "$RC" 0
    check "Steam.app patched again" app_patched
    check "a second verified backup was taken" eq "$(st '[.steam.backups[] | select(.kind=="original")] | length')" 2
    check "Steam restarted and verified" eq "$(st .verify.result)" pass
    echo b > "$T/ctl/dylib-variant"
    inst "${YES[@]}" -- all --from dist
    check "a changed dylib is re-patched (exit 0)" eq "$RC" 0
    check "Steam.app carries the new dylib" cmp -s "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" "$T/bin/notproton-b.dylib"
    inst NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "uninstall after all that restores the original" app_is_original
fi

# ================================================================================================
if want verify_partial; then
    begin verify_partial
    echo partial > "$T/ctl/log-mode"
    inst "${YES[@]}" -- all --from dist
    check "a partial hook result is a FAIL (exit 1)" eq "$RC" 1
    check "recorded as fail" eq "$(st .verify.result)" fail
    check "the install itself stays (journal done)" eq "$(st .journal.state)" "done"
    echo none > "$T/ctl/log-mode"
    rm -f "$T/ctl/steam-running"
    inst "${YES[@]}" -- all --from dist
    check "no log lines within the timeout: pending, exit 0" eq "$RC" 0
    check "recorded as pending" eq "$(st .verify.result)" pending
fi

# ================================================================================================
if want guards; then
    begin guards
    inst -- steam
    check "'steam' refuses without a verified backup (rule 1)" eq "$RC" 1
    check "with the rule named" grep -q 'rule 1' "$T/out/err"
    inst NP_SUPPORT="$HOME/Library/Application Support/notproton-test-should-refuse" -- doctor
    check "test mode refuses a path outside NP_TEST_ROOT" eq "$RC" 1
    check "and says so" grep -q 'outside NP_TEST_ROOT' "$T/out/err"
    check "nothing was created there" test ! -e "$HOME/Library/Application Support/notproton-test-should-refuse"
    touch "$T/ctl/steam-running" "$T/ctl/steam-refuses-quit"
    inst "${YES[@]}" -- all --from dist
    check "Steam that does not quit aborts the run (never force-killed)" eq "$RC" 1
    check "Steam.app untouched" app_is_original
    rm -f "$T/ctl/steam-refuses-quit"
    printf 'WINEDEBUG=-all\nWINE}; touch x; : ${X=1\nFOO=1\n' > "$T/genv"
    inst "${YES[@]}" -- all --from dist
    cp "$T/genv" "$NP_SUPPORT/global.env"
    inst -- doctor --json
    check "doctor flags an invalid global.env name as fail" eq "$(jq -r '.checks[] | select(.id=="global_env") | .verdict' "$T/out/out")" fail
    printf 'WINEDEBUG=-all\nFOO=1\n' > "$NP_SUPPORT/global.env"
    inst -- doctor --json
    check "doctor flags a name outside the allow-list as warn" eq "$(jq -r '.checks[] | select(.id=="global_env") | .verdict' "$T/out/out")" warn
fi

# ================================================================================================
if want gate_live; then
    begin gate_live
    inst "${YES[@]}" -- all --from dist
    patched_hash="$(tree_hash "$NP_STEAM_APP")"
    echo "steamclient v2" > "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
    echo nolive > "$T/ctl/anchor-mode"
    inst NP_TEST_DIALOG_ANSWER=yes NP_PROGRESS_FD=1 -- reapply --auto
    check "no live profile: reapply --auto stops (exit 1) even with 'Re-apply' answered" eq "$RC" 1
    check "and notifies" grep -q '"event":"notify".*Steam Play is switched off' "$T/out/out"
    check "and disables the signatures (no hooks can half-load)" test ! -e "$NP_SUPPORT/signatures"
    check "disabled state recorded" eq "$(st .client.signatures.disabled)" true
    check "Steam.app untouched" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
    inst -- doctor --json
    check "doctor reports the disabled signatures as gate FAIL" eq "$(jq -r '.checks[] | select(.id=="gate") | .verdict' "$T/out/out")" fail
    inst -- reapply
    check "reapply while disabled and still no live profile: exit 1 (not 'unchanged')" eq "$RC" 1
    echo pass > "$T/ctl/anchor-mode"
    inst -- reapply
    check "reapply after a matching profile appears: exit 0" eq "$RC" 0
    check "signatures back, live profile only" eq "$(ls "$NP_SUPPORT/signatures/macos.arm64" | tr '\n' ' ')" "1788400362.json "
    check "enabled again" eq "$(st .client.signatures.disabled)" false
    echo "steamclient v3" > "$NP_STEAM_SUPPORT/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
    echo 1790904859 > "$T/ctl/live-build"
    inst -- reapply
    check "a client that matches another profile: that profile alone is installed" eq "$(ls "$NP_SUPPORT/signatures/macos.arm64" | tr '\n' ' ')" "1790904859.json "
fi

# ================================================================================================
if want rollback_signal; then
    begin rollback_signal
    inst "${YES[@]}" NP_TEST_FAIL_AT=patch.after_sign NP_TEST_FAIL_SIGNAL=1 NP_TEST_ROLLBACK_SIGNAL=1 -- all --from dist
    check "Ctrl-C, then INT/TERM/HUP during the rollback: exit 130" eq "$RC" 130
    check "the rollback still completed: original restored" app_is_original
    check "journal closed as failed, not left in_progress" eq "$(st .journal.state)" failed
    check "the second signals were sent" grep -q 'sending SIGINT, SIGTERM and SIGHUP to the rollback' "$T/out/out"
    check "and again after the rollback's own swap (critical sections stay off in the exit handler)" grep -q "signals again after the rollback's swap" "$T/out/out"
    check "the run still reported the restore" grep -q 'Steam.app restored to its state before this run' "$T/out/out"
    check "no leftover temp bundles" bash -c '! ls -a "$(dirname "$1")" | grep -q "^\.Steam"' _ "$NP_STEAM_APP"
fi

# ================================================================================================
if want legacy_cmds; then
    begin legacy_cmds
    inst "${YES[@]}" -- all --from dist
    inst -- support
    check "'support' is refused once install.sh all has run" eq "$RC" 1
    check "with the reason" grep -q 'bypass the signature gate' "$T/out/err"
    echo nolive > "$T/ctl/anchor-mode"
    rm -f "$T/ctl/steam-running"
    inst -- --json steam
    check "'steam' runs the gate first and stops on no live profile (exit 1)" eq "$RC" 1
    check "before any confirmation was asked" bash -c '! grep -q "\"event\":\"confirm\"" "$1"' _ "$T/out/out"
    check "says the gate failed" grep -q 'signature gate failed' "$T/out/err"
    check "and disables the signatures of the patched Steam.app" bash -c '[ ! -e "$1/signatures" ] && [ "$(jq -r .client.signatures.disabled "$1/install-state.json")" = true ]' _ "$NP_SUPPORT"
    mv "$NP_SUPPORT/install-state.json" "$T/state.bak"
    inst -- support
    check "'support' without a state file refuses a patched Steam.app" bash -c '[ "$1" = 1 ] && grep -q "already patched" "$2"' _ "$RC" "$T/out/err"
    check "and creates no state file" test ! -e "$NP_SUPPORT/install-state.json"
    mv "$T/state.bak" "$NP_SUPPORT/install-state.json"
fi

# ================================================================================================
if want restore_paths; then
    begin restore_paths
    inst "${YES[@]}" -- all --from dist
    patched_hash="$(tree_hash "$NP_STEAM_APP")"
    inst NP_TEST_ANSWER_UNINSTALL=yes NP_TEST_FAIL_AT=restore.after_swap -- uninstall
    check "a restore that fails verification after the swap: exit 1" eq "$RC" 1
    check "the patched Steam.app was put back" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
    check "and the message says so" grep -q 'the previous Steam.app was put back' "$T/out/err"
    check "the failed copy is kept in the backup dir" bash -c 'ls -d "$1"/Steam.app.badrestore-* >/dev/null' _ "$NP_BACKUP_DIR"
    check "no hidden bundles left next to Steam.app" bash -c '! ls -a "$(dirname "$1")" | grep -q "^\.Steam"' _ "$NP_STEAM_APP"
    mkdir "$(dirname "$NP_STEAM_APP")/.Steam.app.aside-999"
    inst -- doctor --json
    check "doctor reports a leftover .Steam.app.aside-*" eq "$(jq -r '.checks[] | select(.id=="leftovers") | .verdict' "$T/out/out")" fail
    rmdir "$(dirname "$NP_STEAM_APP")/.Steam.app.aside-999"
    rm -rf "$NP_STEAM_APP"
    inst NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "Steam.app missing: uninstall restores the verified backup (exit 0)" eq "$RC" 0
    check "original restored" app_is_original
fi

# ================================================================================================
if want detach; then
    begin detach
    cp "$T/bin/notproton-a.dylib" "$NP_STEAM_APP/Contents/MacOS/notproton.dylib"
    plutil -insert LSEnvironment -dictionary "$NP_STEAM_APP/Contents/Info.plist"
    plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" "$NP_STEAM_APP/Contents/Info.plist"
    codesign -f -s - "$NP_STEAM_APP" 2>/dev/null
    inst NP_TEST_ANSWER_RESTORE_VALVE=no NP_TEST_ANSWER_DETACH=yes NP_TEST_ANSWER_UNINSTALL=yes -- uninstall
    check "no Valve copy anywhere: detach (exit 0)" eq "$RC" 0
    check "a snapshot was taken before detaching" bash -c 'ls -d "$1"/Steam.app.prepatch-* >/dev/null' _ "$NP_BACKUP_DIR"
    check "insert and dylib gone" bash -c '! plutil -extract LSEnvironment.DYLD_INSERT_LIBRARIES raw -o - "$1/Contents/Info.plist" >/dev/null 2>&1 && [ ! -e "$1/Contents/MacOS/notproton.dylib" ]' _ "$NP_STEAM_APP"
    check "detached Steam.app's signature verifies" codesign --verify --deep --strict "$NP_STEAM_APP"
fi

# ================================================================================================
if want quit_update; then
    begin quit_update
    touch "$T/ctl/steam-running" "$T/ctl/update-on-quit"
    inst "${YES[@]}" -- all --from dist
    check "Steam updating its client while quitting aborts the run (exit 1)" eq "$RC" 1
    check "with the reason" grep -q 'changed while Steam was quitting' "$T/out/err"
    check "Steam.app untouched, no backup taken" bash -c '[ "$1" = "$2" ] && [ ! -d "$3" ]' _ "$(tree_hash "$NP_STEAM_APP")" "$ORIG_HASH" "$NP_BACKUP_DIR"
fi

# ================================================================================================
if want nits; then
    begin nits
    inst -- --json all --from dist --plan
    check "all --plan exits 0" eq "$RC" 0
    check "all --plan writes nothing (no support dir at all)" test ! -e "$NP_SUPPORT"
    mkdir -p "$W/dist/evil"
    cp "$NP_DIST_DIR/selfbuilt-test-r1/runner.json" "$W/dist/evil/"
    inst "${YES[@]}" NP_RUNNER_ID=../evil -- all --from dist
    check "a runner id with '..' is refused" eq "$RC" 1
    check "with the reason" grep -q "runner id '../evil'" "$T/out/err"
    inst NP_SUPPORT="$W/home/x/../Library/Application Support/notproton" -- doctor
    check "test mode refuses a path with '..'" eq "$RC" 1
    inst NP_TEST_ROOT=/private/tmp -- doctor
    check "test mode refuses NP_TEST_ROOT = a temp dir itself" eq "$RC" 1
    check "with the reason" grep -q 'subdirectory of a temp dir' "$T/out/err"
    mkdir -p "$NP_SUPPORT"
    ln -s 999999 "$NP_SUPPORT/.install.lock"
    inst -- block-updates
    check "a stale lock (dead pid) is taken over" eq "$RC" 0
    ln -s $$ "$NP_SUPPORT/.install.lock"
    inst -- block-updates
    check "a lock whose pid is alive but not an install.sh (reused pid) is taken over" eq "$RC" 0
    (exec -a install.sh-holder sleep 60) &
    holder=$!
    sleep 0.2
    rm -f "$NP_SUPPORT/.install.lock"
    ln -s "$holder" "$NP_SUPPORT/.install.lock"
    inst -- block-updates
    check "a live install.sh lock is respected" eq "$RC" 1
    check "naming the owner" grep -q "another install.sh is running (pid $holder)" "$T/out/err"
    inst -- support
    check "'support' takes the lock too" bash -c '[ "$1" = 1 ] && grep -q "another install.sh is running" "$2"' _ "$RC" "$T/out/err"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    rm -f "$NP_SUPPORT/.install.lock"
    inst -- --json all --from dist --plan
    check "the plan names the D3DMetal source (3.0 tarball)" grep -q 'GPTK 3.0 tarball' "$T/out/err"
    inst D3DMETAL_GPTK_DMG="$W/some.dmg" -- all --from dist --plan
    check "D3DMETAL_GPTK_DMG is honoured visibly (refused when missing, not silently used)" grep -q -- "--gptk-dmg: no such file: $W/some.dmg" "$T/out/err"
    : > "$W/some.dmg"
    inst D3DMETAL_GPTK_DMG="$W/some.dmg" -- all --from dist --plan
    check "and shows in the plan" grep -q "D3DMetal from $W/some.dmg" "$T/out/out"
    inst "${YES[@]}" -- all --from dist
    mkdir -p "$NP_STEAM_SUPPORT/steamapps/compatdata/123/pfx"
    touch "$NP_STEAM_SUPPORT/steamapps/compatdata/123/notproton-run.log"
    patched_hash="$(tree_hash "$NP_STEAM_APP")"
    inst NP_TEST_ANSWER_UNINSTALL=yes -- --json uninstall --remove-prefixes
    check "uninstall --remove-prefixes under --json: exit 3 before anything changes" eq "$RC" 3
    check "with a remove_prefixes confirm event" eq "$(jq -r 'select(.event=="confirm") | .id' "$T/out/out")" remove_prefixes
    check "Steam.app still patched" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
    inst NP_TEST_ANSWER_UNINSTALL=yes NP_TEST_ANSWER_REMOVE_PREFIXES=yes -- uninstall --remove-prefixes
    check "confirmed: prefixes removed and original restored" bash -c '[ "$1" = 0 ] && [ ! -e "$2" ]' _ "$RC" "$NP_STEAM_SUPPORT/steamapps/compatdata/123"
    check "original restored" app_is_original
fi

# ================================================================================================
if want release_tree; then
    begin release_tree
    rel="$W/rel"
    lock_for() { # dir-name -> lock file for an archive of $rel/<dir-name>
        tar -C "$rel" -cf - "$1" | zstd -q -o "$rel/$1.tar.zst"
        printf 'version=v-%s\nurl=file://%s\nsha256=%s\n' "$1" "$rel/$1.tar.zst" "$(shasum -a 256 "$rel/$1.tar.zst" | cut -c1-64)" > "$rel/$1.lock"
    }
    make_fake_runner "$rel/chain"
    ln -s . "$rel/chain/l2"
    ln -s l2/.. "$rel/chain/b"
    ln -s b/.. "$rel/chain/c"
    lock_for chain
    inst "${YES[@]}" NP_TEST_RUNNER_LOCK="$rel/chain.lock" -- all --from release
    check "chained symlinks (l2 -> ., b -> l2/.., c -> b/..) are refused" eq "$RC" 1
    check "because they resolve outside" grep -q 'resolves outside the runner tree' "$T/out/err"
    check "no runner installed" test ! -e "$NP_SUPPORT/runners/v-chain"
    make_fake_runner "$rel/withd3d"
    mkdir -p "$rel/withd3d/lib/external/D3DMetal.framework"
    echo x > "$rel/withd3d/lib/external/D3DMetal.framework/D3DMetal"
    lock_for withd3d
    inst "${YES[@]}" NP_TEST_RUNNER_LOCK="$rel/withd3d.lock" -- all --from release
    check "a release runner that contains D3DMetal is refused" eq "$RC" 1
    check "with the reason" grep -q 'contains D3DMetal' "$T/out/err"
    check "Steam.app untouched" app_is_original
fi

# ================================================================================================
if want gptk_dmg; then
    begin gptk_dmg
    g="$W/gptk"
    src="$g/evalsrc"
    fw="$src/redist/lib/external/D3DMetal.framework"
    mkdir -p "$fw/Versions/A/Resources" "$src/redist/lib/wine/x86_64-windows" "$src/redist/lib/wine/x86_64-unix"
    echo d3dmetal-4 > "$fw/Versions/A/D3DMetal"
    echo res > "$fw/Versions/A/Resources/default.metallib"
    ln -s A "$fw/Versions/Current"
    ln -s Versions/Current/D3DMetal "$fw/D3DMetal"
    ln -s Versions/Current/Resources "$fw/Resources"
    echo shared4 > "$src/redist/lib/external/libd3dshared.dylib"
    for d in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do echo "$d-4" > "$src/redist/lib/wine/x86_64-windows/$d.dll"; done
    ln -s ../../external/libd3dshared.dylib "$src/redist/lib/wine/x86_64-unix/d3d11.so"
    printf '{\\rtf1 fake Apple GPTK licence}\n' > "$src/License.rtf"
    hdiutil create -quiet -srcfolder "$src" -volname "Evaluation environment" -format UDZO "$g/eval.dmg"
    mkdir -p "$g/outersrc"
    cp "$g/eval.dmg" "$g/outersrc/Evaluation environment for Windows games 4.0 beta 2.dmg"
    hdiutil create -quiet -srcfolder "$g/outersrc" -volname "Game Porting Toolkit" -format UDZO "$g/outer.dmg"
    NP_TEST_GPTK_DMG_KNOWN="$(shasum -a 256 "$g/outer.dmg" | cut -c1-64) outer 4.0b2
$(shasum -a 256 "$g/eval.dmg" | cut -c1-64) eval 4.0b2"
    export NP_TEST_GPTK_DMG_KNOWN
    lsha="$(shasum -a 256 "$src/License.rtf" | cut -c1-64)"
    export NP_TEST_APPLE_LICENSES="$lsha"
    r="$g/runner"
    make_fake_runner "$r"
    printf '{\n  "id": "r",\n  "kind": "selfbuilt",\n  "renderers": { "d3dmetal": "3.0", "dxmt": "v0.80" }\n}\n' > "$r/runner.json"
    d3d() { RC=0; env D3DMETAL_CACHE="$g/cache" "$@" bash "$REPO/scripts/install-d3dmetal.sh" --gptk-dmg "$DMG" "$r" > "$T/out/out" 2> "$T/out/err" < /dev/null || RC=$?; }
    DMG="$g/outer.dmg"
    d3d
    check "GPTK dmg without acceptance: exit 2" eq "$RC" 2
    check "machine-readable licence line with the licence hash" grep -q "^license-required $lsha $g/cache/gptk-4.0b2-License.rtf" "$T/out/err"
    check "the licence file is there for a GUI to show" test -f "$g/cache/gptk-4.0b2-License.rtf"
    check "nothing installed" test ! -e "$r/lib/external"
    d3d D3DMETAL_LICENSE_SHA256="$lsha"
    check "with the licence token: exit 0" eq "$RC" 0
    check "renderers.d3dmetal replaced 3.0 with 4.0b2" eq "$(jq -r .renderers.d3dmetal "$r/runner.json")" 4.0b2
    check "the selfbuilt line format is kept" grep -q '"kind": "selfbuilt"' "$r/runner.json"
    check "framework symlinks copied as symlinks" eq "$(readlink "$r/lib/external/D3DMetal.framework/Versions/Current")" A
    check "nvngx from nvngx-on-metalfx, dll and so" test -f "$r/lib/renderers/d3dmetal/x86_64-windows/nvngx.dll" -a -L "$r/lib/renderers/d3dmetal/x86_64-unix/nvngx.so"
    check "no atidxx64 (4.0b2 has none)" test ! -e "$r/lib/renderers/d3dmetal/x86_64-windows/atidxx64.dll"
    check "D3DMetal.source records the dmg" eq "$(sed -n 's/^version=//p' "$r/lib/external/D3DMetal.source") $(sed -n 's/^source=//p' "$r/lib/external/D3DMetal.source")" "4.0b2 dmg"
    check "file hashes verify" bash -c 'cd "$1" && shasum -a 256 -c --quiet lib/external/D3DMetal.files.sha256' _ "$r"
    check "both images detached again" bash -c '! hdiutil info | grep -q "$1"' _ "$g"
    DMG="$g/eval.dmg"
    d3d D3DMETAL_LICENSE_SHA256="$lsha"
    check "the evaluation dmg on its own works too" eq "$RC" 0
    cp "$g/eval.dmg" "$g/unknown.dmg"
    printf 'x' >> "$g/unknown.dmg"
    DMG="$g/unknown.dmg"
    d3d D3DMETAL_ACCEPT_LICENSE=1
    check "an unknown dmg hash is refused" bash -c '[ "$1" = 1 ] && grep -q "not a known Game Porting Toolkit image" "$2"' _ "$RC" "$T/out/err"
    printf '{\\rtf1 some other text}\n' > "$src/License.rtf"
    hdiutil create -quiet -srcfolder "$src" -volname "Evaluation environment" -format UDZO "$g/eval2.dmg"
    NP_TEST_GPTK_DMG_KNOWN="$NP_TEST_GPTK_DMG_KNOWN
$(shasum -a 256 "$g/eval2.dmg" | cut -c1-64) eval 4.0b2"
    DMG="$g/eval2.dmg"
    d3d D3DMETAL_ACCEPT_LICENSE=1
    check "a licence text that is not a known Apple GPTK licence is refused" bash -c '[ "$1" = 1 ] && grep -q "not a known Apple GPTK licence" "$2"' _ "$RC" "$T/out/err"

    # Through the installer, as a GUI would drive it.
    inst NP_TEST_D3DMETAL_SCRIPT="$REPO/scripts/install-d3dmetal.sh" -- --json all --from dist --gptk-dmg "$g/outer.dmg"
    check "install.sh --json all --gptk-dmg: a d3dmetal_license confirm event with the licence hash" \
        eq "$(jq -r 'select(.event=="confirm" and .id=="d3dmetal_license") | .token' "$T/out/out")" "$lsha"
    check "and the licence path" eq "$(jq -r 'select(.event=="confirm" and .id=="d3dmetal_license") | .license_path' "$T/out/out")" "$NP_CACHE/gptk-4.0b2-License.rtf"
    inst NP_TEST_D3DMETAL_SCRIPT="$REPO/scripts/install-d3dmetal.sh" NP_D3DMETAL_LICENSE_TOKEN="$lsha" "${YES[@]}" -- all --from dist --gptk-dmg "$g/outer.dmg"
    check "with NP_D3DMETAL_LICENSE_TOKEN the install completes (exit 0)" eq "$RC" 0
    check "state records D3DMetal 4.0b2 from the dmg" eq "$(st '.runners["selfbuilt-test-r1"].d3dmetal | "\(.status) \(.version) \(.source)"')" "installed 4.0b2 dmg"
    check "the runner says 4.0b2" eq "$(jq -r .renderers.d3dmetal "$NP_SUPPORT/runners/selfbuilt-test-r1/runner.json")" 4.0b2
fi

# ================================================================================================
if want gate_crossdb; then
    begin gate_crossdb
    echo crossdb > "$T/ctl/anchor-mode"
    inst "${YES[@]}" -- all --from dist
    check "cross-DB noise in the all-profiles run does not fail a clean live profile (exit 0)" eq "$RC" 0
    check "anchorcheck ran twice: all profiles, then the live one alone" eq "$(sed -n '1p;2p' "$T/ctl/anchorcheck.log" | tr '\n' '|')" "0 |1 signatures/macos.arm64/1788400362.json|"
    check "patched" app_patched
fi

# ================================================================================================
if want interrupts; then
    begin interrupts
    inst "${YES[@]}" NP_TEST_FAIL_AT=backup.after_copy NP_TEST_FAIL_SIGNAL=1 -- all --from dist
    check "Ctrl-C during the backup copy: exit 130" eq "$RC" 130
    check "no .partial backup left" bash -c '! ls "$1" 2>/dev/null | grep -q partial' _ "$NP_BACKUP_DIR"
    check "Steam.app untouched" app_is_original
    inst "${YES[@]}" -- all --from dist
    patched_hash="$(tree_hash "$NP_STEAM_APP")"
    inst NP_TEST_ANSWER_UNINSTALL=yes NP_TEST_FAIL_AT=restore.after_copy NP_TEST_FAIL_SIGNAL=1 -- uninstall
    check "Ctrl-C right after the restore copy: exit 130" eq "$RC" 130
    check "no hidden .Steam.app.restore-* left in the Applications folder" bash -c '! ls -a "$(dirname "$1")" | grep -q "^\.Steam"' _ "$NP_STEAM_APP"
    check "Steam.app still the patched one" eq "$(tree_hash "$NP_STEAM_APP")" "$patched_hash"
fi

# ================================================================================================
if want detach_rollback; then
    begin detach_rollback
    cp "$T/bin/notproton-a.dylib" "$NP_STEAM_APP/Contents/MacOS/notproton.dylib"
    plutil -insert LSEnvironment -dictionary "$NP_STEAM_APP/Contents/Info.plist"
    plutil -insert LSEnvironment.DYLD_INSERT_LIBRARIES -string "$NP_STEAM_APP/Contents/MacOS/notproton.dylib" "$NP_STEAM_APP/Contents/Info.plist"
    codesign -f -s - "$NP_STEAM_APP" 2>/dev/null
    before="$(tree_hash "$NP_STEAM_APP")"
    inst NP_TEST_ANSWER_RESTORE_VALVE=no NP_TEST_ANSWER_DETACH=yes NP_TEST_ANSWER_UNINSTALL=yes NP_TEST_FAIL_AT=detach.after_snapshot -- uninstall
    check "a failed detach: exit 1" eq "$RC" 1
    check "the snapshot was restored (Steam.app as before the detach)" eq "$(tree_hash "$NP_STEAM_APP")" "$before"
    inst NP_TEST_ANSWER_RESTORE_VALVE=no NP_TEST_ANSWER_DETACH=yes NP_TEST_ANSWER_UNINSTALL=yes NP_TEST_FAIL_AT=detach.after_snapshot NP_TEST_FAIL_SIGNAL=1 -- uninstall
    check "Ctrl-C during the detach: exit 130" eq "$RC" 130
    check "the snapshot was restored" eq "$(tree_hash "$NP_STEAM_APP")" "$before"
fi

# ================================================================================================
if want d3d_source; then
    begin d3d_source
    r="$NP_DIST_DIR/selfbuilt-test-r1"
    mkdir -p "$r/lib/external/D3DMetal.framework" "$r/lib/renderers/d3dmetal/x86_64-windows"
    echo old > "$r/lib/external/D3DMetal.framework/D3DMetal"
    echo old > "$r/lib/external/libd3dshared.dylib"
    echo old > "$r/lib/renderers/d3dmetal/x86_64-windows/d3d12.dll"
    inst "${YES[@]}" -- all --from dist
    check "D3DMetal in the source without a licence record: the accept flow runs (exit 0)" eq "$RC" 0
    check "install-d3dmetal ran" test -s "$T/ctl/d3d.log"
    check "and recorded the acceptance" eq "$(st '.runners["selfbuilt-test-r1"].d3dmetal.status')" installed
    : > "$T/ctl/d3d.log"
    inst "${YES[@]}" -- all --from dist
    check "the dist runner still has no record, so it is asked again" test -s "$T/ctl/d3d.log"
    printf 'source=tarball\nversion=3.0\narchive_sha256=x\nlicense_sha256=none\n' > "$r/lib/external/D3DMetal.source"
    : > "$T/ctl/d3d.log"
    inst "${YES[@]}" -- all --from dist
    check "with a record in the source runner it is not asked again" bash -c '[ ! -s "$1" ]' _ "$T/ctl/d3d.log"
    check "recorded as from_source with that version" eq "$(st '.runners["selfbuilt-test-r1"].d3dmetal | "\(.status) \(.version)"')" "from_source 3.0"
fi

# ================================================================================================
if want tree_rules; then
    begin tree_rules
    echo evil > "$T/ctl/d3d-mode"
    inst "${YES[@]}" -- all --from dist
    check "a symlink out of the runner added by the D3DMetal step is refused" bash -c '[ "$1" = 1 ] && grep -q "leaves the runner tree" "$2"' _ "$RC" "$T/out/err"
    echo accept > "$T/ctl/d3d-mode"
    grep -v '^file ' "$NP_TEST_VALVE_MANIFEST" > "$T/m" && cp "$T/m" "$NP_TEST_VALVE_MANIFEST"
    inst "${YES[@]}" -- all --from dist
    check "a Valve manifest without file lines is refused" bash -c '[ "$1" = 1 ] && grep -q "lists no bridge files" "$2"' _ "$RC" "$T/out/err"
    check "Steam.app untouched" app_is_original
fi

# ================================================================================================
if want gptk_sla; then
    begin gptk_sla
    g="$W/gptk"
    src="$g/evalsrc"
    fw="$src/redist/lib/external/D3DMetal.framework"
    mkdir -p "$fw/Versions/A" "$src/redist/lib/wine/x86_64-windows"
    echo d3dmetal-4 > "$fw/Versions/A/D3DMetal"
    ln -s A "$fw/Versions/Current"
    echo shared4 > "$src/redist/lib/external/libd3dshared.dylib"
    for d in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do echo "$d-4" > "$src/redist/lib/wine/x86_64-windows/$d.dll"; done
    printf '{\\rtf1 fake Apple GPTK licence}\n' > "$src/License.rtf"
    hdiutil create -quiet -srcfolder "$src" -volname "Evaluation environment" -format UDZO "$g/eval.dmg"
    # A licence agreement in the image (like Apple's), added with udifrez.
    printf '{\\rtf1 fake Apple GPTK licence}\n' > "$g/sla.rtf"
    python3 -I - "$g/sla.rtf" "$g/res.xml" <<'PY'
import plistlib, struct, sys
def pstr(x):
    b = x.encode("mac_roman"); return bytes([len(b)]) + b
strs = ["English", "Agree", "Disagree", "Print", "Save...", "If you agree, press Agree."]
d = {"LPic": [{"Attributes": "0x0000", "Data": struct.pack(">HHHHH", 0, 1, 0, 0, 0), "ID": "5000", "Name": ""}],
     "STR#": [{"Attributes": "0x0000", "Data": struct.pack(">H", len(strs)) + b"".join(pstr(x) for x in strs), "ID": "5000", "Name": "English"}],
     "RTF ": [{"Attributes": "0x0000", "Data": open(sys.argv[1], "rb").read(), "ID": "5000", "Name": "English SLA"}]}
plistlib.dump(d, open(sys.argv[2], "wb"))
PY
    hdiutil udifrez -xml "$g/res.xml" '' "$g/eval.dmg" >/dev/null 2>&1
    check "the fixture carries a licence agreement" bash -c 'hdiutil imageinfo "$1" 2>/dev/null | grep -q "Software License Agreement: true"' _ "$g/eval.dmg"
    NP_TEST_GPTK_DMG_KNOWN="$(shasum -a 256 "$g/eval.dmg" | cut -c1-64) eval 4.0b2"
    export NP_TEST_GPTK_DMG_KNOWN
    lsha="$(shasum -a 256 "$g/sla.rtf" | cut -c1-64)"
    export NP_TEST_APPLE_LICENSES="$lsha"
    r="$g/runner"
    make_fake_runner "$r"
    d3d() { RC=0; env D3DMETAL_CACHE="$g/cache" "$@" bash "$REPO/scripts/install-d3dmetal.sh" --gptk-dmg "$DMG" "$r" > "$T/out/out" 2> "$T/out/err" < /dev/null || RC=$?; }
    DMG="$g/eval.dmg"
    d3d
    check "SLA image, no acceptance: exit 2" eq "$RC" 2
    check "the licence offered is the image's own agreement" grep -q "^license-required $lsha " "$T/out/err"
    check "nothing was mounted (the agreement was read without attaching)" bash -c '! mount | grep -qF "$1"' _ "$T"
    d3d D3DMETAL_ACCEPT_LICENSE=1
    check "D3DMETAL_ACCEPT_LICENSE does not accept a disk image licence (exit 2)" eq "$RC" 2
    check "and says why" grep -q 'does not accept the licence of a GPTK disk image' "$T/out/err"
    check "nothing installed" test ! -e "$r/lib/external"
    printf '{\\rtf1 another allowlisted text}\n' > "$g/other.rtf"
    NP_TEST_APPLE_LICENSES="$lsha $(shasum -a 256 "$g/other.rtf" | cut -c1-64)"
    d3d D3DMETAL_LICENSE_FILE="$g/other.rtf"
    check "D3DMETAL_LICENSE_FILE with a different (even allowlisted) text is refused" eq "$RC" 2
    d3d D3DMETAL_LICENSE_SHA256="$lsha" NP_TEST_D3D_KILL_AFTER_ATTACH=1
    check "killed right after the mount: exit 130" eq "$RC" 130
    check "and the image was ejected anyway" bash -c '! mount | grep -qF "$1"' _ "$T"
    d3d D3DMETAL_LICENSE_SHA256="$lsha"
    check "with the token: exit 0" eq "$RC" 0
    check "installed" eq "$(sed -n 's/^version=//p' "$r/lib/external/D3DMetal.source")" 4.0b2
    rm -rf "$r/lib/external" "$r/lib/renderers"
    d3d D3DMETAL_LICENSE_FILE="$g/sla.rtf"
    check "D3DMETAL_LICENSE_FILE with exactly the image's allowlisted text: exit 0" eq "$RC" 0
    check "no image left mounted" bash -c '! mount | grep -qF "$1"' _ "$T"
    printf 'not a disk image' > "$g/bogus.dmg"
    NP_TEST_GPTK_DMG_KNOWN="$NP_TEST_GPTK_DMG_KNOWN
$(shasum -a 256 "$g/bogus.dmg" | cut -c1-64) eval 4.0b2"
    DMG="$g/bogus.dmg"
    d3d D3DMETAL_LICENSE_SHA256="$lsha"
    check "unreadable image info is fatal, not 'no agreement'" bash -c '[ "$1" = 1 ] && grep -q "cannot read the image info" "$2"' _ "$RC" "$T/out/err"
    RC=0
    env NP_TEST_ROOT=/private/tmp bash "$REPO/scripts/install-d3dmetal.sh" --gptk-dmg "$g/eval.dmg" "$r" > "$T/out/out" 2> "$T/out/err" < /dev/null || RC=$?
    check "install-d3dmetal.sh in test mode refuses a test root that is a temp dir itself" bash -c '[ "$1" = 1 ] && grep -q "subdirectory of a temp dir" "$2"' _ "$RC" "$T/out/err"
fi

# ================================================================================================
if want global_env; then
    begin global_env
    mkdir -p "$NP_SUPPORT"
    printf 'NOTPROTON_HIDE_LAUNCHER_TILE=1\nWINEMSYNC=0\n#ROSETTA_ADVERTISE_AVX=1\n' > "$NP_SUPPORT/global.env"
    inst "${YES[@]}" -- all --from dist
    check "install exits 0" eq "$RC" 0
    check "the user's own WINEMSYNC=0 is kept, no default added" bash -c '[ "$(grep -c "WINEMSYNC=" "$1")" = 1 ] && grep -qx WINEMSYNC=0 "$1"' _ "$NP_SUPPORT/global.env"
    check "a commented-out default stays out" bash -c '! grep -qx ROSETTA_ADVERTISE_AVX=1 "$1"' _ "$NP_SUPPORT/global.env"
    check "NOTPROTON_HIDE_LAUNCHER_TILE=1 kept" grep -qx NOTPROTON_HIDE_LAUNCHER_TILE=1 "$NP_SUPPORT/global.env"
fi

# ================================================================================================
# compat_run.sh pieces, cut out of the patched run script by their markers and run on their own.
if want run_script; then
    begin run_script
    RS="$REPO/notproton/dylib/feats/compat_run.sh"
    h="$W/rs"
    mkdir -p "$h/runner" "$h/pfx"
    {
        echo 'set -e'
        echo 'log="$H/log"'
        sed -n '/^runner_kind=crossover$/,/^\[ "\$runner_kind" = selfbuilt \] && msync_default=1$/p' "$RS"
        # where WINEMSYNC came from, recorded before global.env is read
        sed -n '/^np_msync_src=""$/,/^\[ -n "\${WINEMSYNC:-}" \] && np_msync_src=game$/p' "$RS"
        # global.env loader rule: a name already set by the game wins
        echo '[ -n "${GLOBAL_WINEMSYNC:-}" ] && [ -z "${WINEMSYNC:-}" ] && WINEMSYNC=$GLOBAL_WINEMSYNC'
        sed -n '/^  # msync, first match wins on every launch:/,/^  export WINEMSYNC="\${WINEMSYNC:-\$msync_default}"$/p' "$RS"
        sed -n '/^  echo "sync: WINEMSYNC=\$WINEMSYNC from \$msync_from"/p' "$RS"
        echo 'printf "%s|%s|%s\n" "$WINEMSYNC" "$msync_from" "$(cat "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || echo none)"'
    } > "$h/msync.sh"
    check "the msync pieces were found in compat_run.sh" bash -c '[ "$(grep -c "msync_file" "$1")" -ge 3 ] && grep -q "^runner_kind=crossover" "$1" && grep -q "^np_msync_src=\"\"" "$1" && grep -q "sync: WINEMSYNC=" "$1"' _ "$h/msync.sh"
    ms() { # kind [game value] [global.env value] -> "value|from|file"
        if [ "$1" = selfbuilt ]; then printf '{ "kind": "selfbuilt" }\n' > "$h/runner/runner.json"; else rm -f "$h/runner/runner.json"; fi
        local e=(env -i PATH=/usr/bin:/bin H="$h" CX_ROOT="$h/runner" STEAM_COMPAT_DATA_PATH="$h/pfx")
        [ -n "${2:-}" ] && e+=(WINEMSYNC="$2")
        [ -n "${3:-}" ] && e+=(GLOBAL_WINEMSYNC="$3")
        "${e[@]}" sh "$h/msync.sh"
    }
    check "4. nothing anywhere: the runner default (selfbuilt on), nothing saved" eq "$(ms selfbuilt)" "1|default for selfbuilt|none"
    check "4. CrossOver-kind runner: off by default" eq "$(ms crossover)" "0|default for crossover|none"
    printf '0' > "$h/pfx/notproton-msync"
    check "a legacy plain 0 is ignored (the runner default wins)" eq "$(ms selfbuilt)" "1|default for selfbuilt|none"
    check "and the log says so" grep -q 'ignoring legacy .*notproton-msync (0)' "$h/log"
    check "3. global.env beats the runner default and is not saved" eq "$(ms crossover "" 1)" "1|global.env|none"
    check "   and the log names global.env" grep -q 'sync: WINEMSYNC=1 from global.env' "$h/log"
    check "   a global.env change is followed on the next launch" eq "$(ms selfbuilt "" 0)" "0|global.env|none"
    check "1. a per-game value is saved as explicit=" eq "$(ms selfbuilt 0 1)" "0|launch-options|explicit=0"
    check "   and logged as from launch-options" grep -q 'sync: WINEMSYNC=0 from launch-options' "$h/log"
    check "2. the saved explicit value beats global.env on a later launch" eq "$(ms selfbuilt "" 1)" "0|carried-over|explicit=0"
    check "2. and the runner default" eq "$(ms selfbuilt)" "0|carried-over|explicit=0"
    check "1. a new per-game value replaces the saved one" eq "$(ms crossover 1 0)" "1|launch-options|explicit=1"
    check "2. carried over on a CrossOver-kind runner too" eq "$(ms crossover "" 0)" "1|carried-over|explicit=1"
    # The real loader: the top of compat_run.sh (launch options, then global.env) with a fake HOME.
    n="$(grep -nF 'case "$verb" in' "$RS" | head -1 | cut -d: -f1)"
    { head -n "$((n - 1))" "$RS"; echo 'echo "${np_msync_src:-none}|${WINEMSYNC:-unset}"'; } > "$h/top.sh"
    mkdir -p "$h/home/Library/Application Support/notproton"
    printf 'WINEMSYNC=1\n' > "$h/home/Library/Application Support/notproton/global.env"
    check "real loader: WINEMSYNC from global.env is not marked per-game" eq "$(env -i PATH=/usr/bin:/bin HOME="$h/home" sh "$h/top.sh" run game.exe)" "none|1"
    check "real loader: a launch option WINEMSYNC=0 is per-game and beats global.env" eq "$(env -i PATH=/usr/bin:/bin HOME="$h/home" sh "$h/top.sh" run WINEMSYNC=0 game.exe)" "game|0"
    check "real loader: the Compatibility-panel toggle (env) is per-game too" eq "$(env -i PATH=/usr/bin:/bin HOME="$h/home" WINEMSYNC=0 sh "$h/top.sh" run game.exe)" "game|0"

    {
        sed -n '/^if \[ -f "\$CX_ROOT\/lib\/external\/libd3dshared.dylib" \]; then$/,/^fi$/p' "$RS"
        echo 'echo "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-unset}"'
    } > "$h/gptk.sh"
    check "without libd3dshared the GPTK path stays unset" eq "$(env -i PATH=/usr/bin:/bin CX_ROOT="$h/runner" sh "$h/gptk.sh")" unset
    mkdir -p "$h/runner/lib/external"
    : > "$h/runner/lib/external/libd3dshared.dylib"
    check "with libd3dshared it is exported whatever the backend" eq "$(env -i PATH=/usr/bin:/bin CX_ROOT="$h/runner" CX_GRAPHICS_BACKEND=wined3d sh "$h/gptk.sh")" "$h/runner/lib/external/libd3dshared.dylib"

    order="$(grep -n -e '^fix_file=' -e 'autofix_run "\$1"' -e '^if \[ "\$verb" = waitforexitandrun \] && \[ -r "\$fix_file" \]' \
        -e 'eval "set -- \$(autofix_argv "\$@")"' -e '^target="\$1"' -e 'autofix_post || true' -e '^kill_wine_prefix$' "$RS" | cut -d: -f2- | tr '\n' '|')"
    check "autofix hooks in order: fix_file, autofix_run, fix file, argv eval, target, post, kill" bash -c '
        case "$1" in *'"'"'fix_file='"'"'*autofix_run*'"'"'-r "$fix_file"'"'"'*autofix_argv*'"'"'target="$1"'"'"'*autofix_post*kill_wine_prefix*) exit 0 ;; esac; exit 1' _ "$order"
    check "the patched run script parses (sh -n)" sh -n "$RS"
    check "the patch series is recognised as fully applied" "$REPO/scripts/apply-notproton-patches.sh" --check
fi

echo
echo "installer tests: $PASS passed, $FAIL failed${FAILED_NAMES:+ (in:$(echo "$FAILED_NAMES" | tr ' ' '\n' | sort -u | tr '\n' ' '))}"
[ "$FAIL" = 0 ]
