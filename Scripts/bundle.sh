#!/bin/bash
# Build the release binary and wrap it into build/AnnotationStation.app, signed.
#
# The .app bundle matters: macOS keys TCC grants (Screen Recording, Accessibility) by bundle id
# + code requirement. Always launch the .app, never the bare binary, when testing permissions.
#
#   Scripts/bundle.sh              # dev build, signed with the self-signed identity
#   RELEASE=1 Scripts/bundle.sh    # release build: requires Developer ID + hardened runtime
#   IDENTITY="..." Scripts/bundle.sh   # force a specific signing identity
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AnnotationStation"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.gabe.annotation-station"
DEV_IDENTITY="Annotation Station Dev"

cd "$ROOT"

# --- pick a signing identity ------------------------------------------------------------
# Release builds must use a Developer ID: it is the only identity Apple will notarize, and
# only a notarized build opens on someone else's Mac without a Gatekeeper detour. Dev builds
# use the stable self-signed cert so TCC grants survive rebuilds (see Scripts/make-signing-cert.sh).
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"

HARDENED=0
if [[ -n "${IDENTITY:-}" ]]; then
    :                                       # caller knows what they want
elif [[ "${RELEASE:-0}" == "1" ]]; then
    if [[ -z "$DEVELOPER_ID" ]]; then
        cat >&2 <<'MSG'
✗ RELEASE=1 needs a "Developer ID Application" certificate and none is installed.
  That requires an Apple Developer Program membership (developer.apple.com/programs, $99/yr):
  enrol, then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application.
  Without it a build cannot be notarized, and friends get "Apple could not verify" on launch.
MSG
        exit 1
    fi
    IDENTITY="$DEVELOPER_ID"
    HARDENED=1
else
    IDENTITY="$DEV_IDENTITY"
fi
[[ "$IDENTITY" == Developer\ ID\ Application:* ]] && HARDENED=1

# --- build ------------------------------------------------------------------------------
echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" 2>&1 | grep -vE '^\s*$' || true
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[[ -x "$BIN" ]] || { echo "build failed: $BIN not found" >&2; exit 1; }

echo "▸ bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# --- embed Sparkle ------------------------------------------------------------------------
# SwiftPM resolves Sparkle as a binary xcframework but does not embed anything into an .app,
# so we copy the framework in ourselves. The executable finds it via the @executable_path/../Frameworks
# rpath set in Package.swift.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -maxdepth 6 -type d -name "Sparkle.framework" -path "*macos-arm64_x86_64*" | head -1)"
if [[ -z "$SPARKLE_FW" ]]; then
    echo "✗ Sparkle.framework not found under .build/artifacts — run 'swift package resolve' first" >&2
    exit 1
fi
echo "▸ embedding $(basename "$(dirname "$(dirname "$SPARKLE_FW")")")/Sparkle.framework"
# -R preserves the symlink farm a versioned framework needs; a plain -r would break signing.
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# --- sign -----------------------------------------------------------------------------------
# Inside-out, and never with --deep: --deep re-signs nested code with the outer bundle's
# options and is documented as unsuitable for exactly this shape of bundle (a framework that
# contains its own XPC services and a helper app).
SIGN_OPTS=(--force --timestamp"$([[ $HARDENED == 1 ]] || echo =none)")
[[ $HARDENED == 1 ]] && SIGN_OPTS+=(--options runtime)

sign() { codesign "${SIGN_OPTS[@]}" --sign "$IDENTITY" "$@"; }

echo "▸ codesign ($IDENTITY$([[ $HARDENED == 1 ]] && echo ", hardened runtime"))"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B"
if ! sign --identifier "$BUNDLE_ID" "$APP"; then
    if [[ "$IDENTITY" == "$DEV_IDENTITY" ]]; then
        cat >&2 <<MSG
⚠ signing with '$IDENTITY' failed (errSecInternalComponent = codesign may not use the key yet).
  Fix once, in your own terminal (asks for your login password):
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
  Falling back to ad-hoc signing for this build; permission grants will not survive rebuilds.
MSG
        codesign --force --sign - "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
        codesign --force --sign - "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
        codesign --force --sign - "$SPARKLE/Versions/B/Updater.app"
        codesign --force --sign - "$SPARKLE/Versions/B/Autoupdate"
        codesign --force --sign - "$SPARKLE/Versions/B"
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    else
        exit 1
    fi
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/  /'

echo "✓ $APP"
