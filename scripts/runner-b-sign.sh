#!/bin/bash
# Signs Runner B's loader bundle (lib/wine/aarch64-unix/wine.app) with the user's own free Apple
# developer identity, so the kernel grants it Apple's cross-architecture entitlement
# (research/RUNNER-B-PLAN.md, B1 "Signing"). Runs on the user's Mac only; CI never signs.
#
# Prerequisite (T0, done by the user in Xcode): a macOS App project "WineLoader" in
# ~/Library/Application Support/notproton/signing/WineLoader/, Personal Team, automatic signing,
# no App Sandbox, no Hardened Runtime, the Cross-Architecture Support capability, built once (⌘B).
#
# What it does:
#   1. finds the stub's built app through `xcodebuild -showBuildSettings` (BUILT_PRODUCTS_DIR);
#   2. reads its embedded.provisionprofile: team, App ID, devices, ExpirationDate (hours left);
#      with --refresh-below H and fewer than H hours left, rebuilds the stub with
#      `xcodebuild -allowProvisioningUpdates` (Xcode's own signed-in account renews the profile);
#   3. copies the profile into wine.app/Contents and writes the stub's CFBundleIdentifier into
#      wine.app/Contents/Info.plist (the profile is tied to that exact App ID);
#   4. takes the entitlements from `codesign -d --entitlements - --xml` of the stub and adds
#      cs.allow-dyld-environment-variables, cs.disable-library-validation and get-task-allow;
#   5. signs with the codesigning identity whose certificate is in the profile (matched by SHA-1
#      against `security find-identity -v -p codesigning`), no hardened runtime;
#   6. verifies with `codesign --verify --strict`.
# It never asks for, reads or passes Apple ID credentials; Xcode holds the account.
#
# Usage: scripts/runner-b-sign.sh [--runner DIR] [--signing-dir DIR] [--project PATH]
#            [--scheme NAME] [--stub-app PATH] [--refresh-below HOURS] [--status]
#   --status   only report the profile (hours left); change nothing. Exit 3 when expired.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/dist/runners/selfbuilt-wine11.18-arm64-r1"
SIGNING="${NOTPROTON_SIGNING_DIR:-$HOME/Library/Application Support/notproton/signing}"
PROJECT="" SCHEME=WineLoader STUB="" REFRESH_BELOW="" STATUS=0
PB=/usr/libexec/PlistBuddy

die() { echo "runner-b-sign: $*" >&2; exit 1; }
note() { echo "runner-b-sign: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --runner) RUNNER="${2:?}"; shift 2 ;;
        --signing-dir) SIGNING="${2:?}"; shift 2 ;;
        --project) PROJECT="${2:?}"; shift 2 ;;
        --scheme) SCHEME="${2:?}"; shift 2 ;;
        --stub-app) STUB="${2:?}"; shift 2 ;;
        --refresh-below) REFRESH_BELOW="${2:?}"; shift 2 ;;
        --status) STATUS=1; shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case "$REFRESH_BELOW" in ''|*[!0-9]*) [ -z "$REFRESH_BELOW" ] || die "--refresh-below takes whole hours" ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/runner-b-sign.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

find_project() {
    [ -n "$PROJECT" ] && { [ -d "$PROJECT" ] || die "no project at $PROJECT"; return; }
    if [ -d "$SIGNING/WineLoader/WineLoader.xcodeproj" ]; then
        PROJECT="$SIGNING/WineLoader/WineLoader.xcodeproj"
    else
        PROJECT="$(find "$SIGNING" -maxdepth 3 -name '*.xcodeproj' -type d 2>/dev/null | head -1)"
    fi
    [ -n "$PROJECT" ] || die "no Xcode project under $SIGNING (T0: create the WineLoader stub in Xcode first)"
}

find_stub() { # sets STUB from the project's build settings (DerivedData is Xcode's choice)
    [ -n "$STUB" ] && [ -z "${1:-}" ] && return
    local settings dir name
    settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -showBuildSettings 2>/dev/null)" \
        || die "xcodebuild -showBuildSettings failed for $PROJECT (scheme $SCHEME)"
    dir="$(printf '%s\n' "$settings" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)"
    name="$(printf '%s\n' "$settings" | sed -n 's/^ *FULL_PRODUCT_NAME = //p' | head -1)"
    [ -n "$dir" ] && [ -n "$name" ] || die "no BUILT_PRODUCTS_DIR/FULL_PRODUCT_NAME in the build settings"
    STUB="$dir/$name"
}

read_profile() { # decodes the stub's profile into $TMP/profile.plist, sets profile facts
    PROFILE="$STUB/Contents/embedded.provisionprofile"
    [ -d "$STUB" ] || die "stub app not built: $STUB (build it once in Xcode with ⌘B)"
    [ -f "$PROFILE" ] || die "no embedded.provisionprofile in $STUB (automatic signing with the Personal Team?)"
    security cms -D -i "$PROFILE" > "$TMP/profile.plist" 2>/dev/null || die "cannot decode $PROFILE"
    TEAM="$($PB -c 'Print :TeamIdentifier:0' "$TMP/profile.plist")"
    APPID="$($PB -c 'Print :Entitlements:application-identifier' "$TMP/profile.plist" 2>/dev/null \
        || $PB -c 'Print :Entitlements:com.apple.application-identifier' "$TMP/profile.plist")"
    PNAME="$($PB -c 'Print :Name' "$TMP/profile.plist")"
    local exp
    exp="$(plutil -extract ExpirationDate raw -o - "$TMP/profile.plist")"
    EXPIRES="$exp"
    EXP_EPOCH="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s)" || die "cannot parse ExpirationDate $exp"
    HOURS_LEFT=$(( (EXP_EPOCH - $(date +%s)) / 3600 ))
}

report() {
    note "stub:    $STUB"
    note "profile: $PNAME, team $TEAM, App ID $APPID"
    note "expires: $EXPIRES ($HOURS_LEFT hours left)"
}

find_project
find_stub
read_profile

if [ -n "$REFRESH_BELOW" ] && [ "$HOURS_LEFT" -lt "$REFRESH_BELOW" ]; then
    note "$HOURS_LEFT h left (< $REFRESH_BELOW): rebuilding the stub with -allowProvisioningUpdates"
    # Uses the account signed in to Xcode (Settings > Accounts); no credentials pass through here.
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -allowProvisioningUpdates build -quiet \
        || die "xcodebuild could not renew the profile (is the Apple ID still signed in to Xcode?)"
    find_stub again
    read_profile
    [ "$HOURS_LEFT" -ge "$REFRESH_BELOW" ] || note "warning: still only $HOURS_LEFT h left after the rebuild"
fi
report
if [ "$STATUS" = 1 ]; then [ "$HOURS_LEFT" -gt 0 ] && exit 0 || exit 3; fi
[ "$HOURS_LEFT" -gt 0 ] || die "the provisioning profile has expired; rerun with --refresh-below 72"

# --- checks on the profile and the stub ------------------------------------------------------
APP="$RUNNER/lib/wine/aarch64-unix/wine.app"
[ -x "$APP/Contents/MacOS/wine" ] || die "no loader bundle at $APP (scripts/assemble-runner-b.sh)"
[ "$(lipo -archs "$APP/Contents/MacOS/wine")" = arm64 ] || die "the loader is not arm64-only"

udid="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Provisioning UDID: //p' | head -1)"
if [ -n "$udid" ] && ! $PB -c 'Print :ProvisionedDevices' "$TMP/profile.plist" 2>/dev/null | grep -qi "$udid"; then
    die "this Mac is not in the profile's ProvisionedDevices (accept 'register this Mac' in Xcode)"
fi
$PB -c 'Print :Entitlements' "$TMP/profile.plist" | grep -q 'com.apple.developer.cross-architecture-support' \
    || die "the profile grants no cross-architecture-support entitlement (T0 step 5: add the capability)"

codesign -d --entitlements - --xml "$STUB" > "$TMP/stub.xml" 2>/dev/null || die "cannot read the stub's entitlements"
plutil -lint "$TMP/stub.xml" >/dev/null || die "the stub's entitlements are not a plist"
grep -q 'com.apple.developer.cross-architecture-support' "$TMP/stub.xml" \
    || die "the stub is signed without the cross-architecture entitlement"

# --- bundle id: the exact App ID the profile names ------------------------------------------
stub_id="$($PB -c 'Print :CFBundleIdentifier' "$STUB/Contents/Info.plist" 2>/dev/null || true)"
appid_id="${APPID#"$TEAM".}"
[ -n "$stub_id" ] || stub_id="$appid_id"
[ "$stub_id" = "$appid_id" ] || die "stub bundle id $stub_id differs from the profile's App ID $appid_id"
$PB -c "Set :CFBundleIdentifier $stub_id" "$APP/Contents/Info.plist"
note "bundle id: $stub_id"

# --- entitlements ----------------------------------------------------------------------------
cp "$TMP/stub.xml" "$TMP/wine.entitlements"
for key in com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.disable-library-validation \
           com.apple.security.get-task-allow; do
    $PB -c "Delete :$key" "$TMP/wine.entitlements" >/dev/null 2>&1 || true
    $PB -c "Add :$key bool true" "$TMP/wine.entitlements"
done
# A leftover App Sandbox would confine every Windows program; T0 removes it, make sure.
if $PB -c 'Print :com.apple.security.app-sandbox' "$TMP/wine.entitlements" >/dev/null 2>&1; then
    $PB -c 'Delete :com.apple.security.app-sandbox' "$TMP/wine.entitlements"
    note "dropped com.apple.security.app-sandbox from the stub's entitlements"
fi

# --- identity: the certificate the profile was issued for -----------------------------------
security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) .*/\1/p' > "$TMP/identities"
identity="" i=0
while cert="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$TMP/profile.plist" 2>/dev/null)"; do
    sha1="$(printf '%s' "$cert" | base64 -D | shasum -a 1 | cut -c1-40 | tr 'a-f' 'A-F')"
    if grep -qx "$sha1" "$TMP/identities"; then identity="$sha1"; break; fi
    i=$((i + 1))
done
[ -n "$identity" ] || die "no valid codesigning identity in the keychain matches the profile's certificates (team $TEAM)"
note "identity: $identity"

# --- sign and verify -------------------------------------------------------------------------
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# No --options runtime: the plan signs without hardened runtime (open question 3).
codesign -f -s "$identity" --timestamp=none --entitlements "$TMP/wine.entitlements" --generate-entitlement-der "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - | grep -E '<key>' | sed 's/^/  /' || true
note "signed $APP; profile expires in $HOURS_LEFT hours"
