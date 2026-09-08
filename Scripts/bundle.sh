#!/bin/bash
# Build the release binary and wrap it into build/AnnotationStation.app, signed.
#
# The .app bundle matters: macOS keys TCC grants (Screen Recording, Accessibility) by bundle id
# + code requirement. Always launch the .app, never the bare binary, when testing permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AnnotationStation"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONFIG="${CONFIG:-release}"

cd "$ROOT"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" 2>&1 | grep -vE '^\s*$' || true
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[[ -x "$BIN" ]] || { echo "build failed: $BIN not found" >&2; exit 1; }

echo "▸ bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Sign with the stable self-signed identity from Scripts/make-signing-cert.sh so TCC grants
# (Screen Recording, Accessibility) survive rebuilds. Ad-hoc signing changes identity per build.
IDENTITY="Annotation Station Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "▸ codesign ($IDENTITY)"
    if ! codesign --force --deep --sign "$IDENTITY" --identifier com.gabe.annotation-station "$APP"; then
        cat >&2 <<MSG
⚠ signing with '$IDENTITY' failed (errSecInternalComponent = codesign may not use the key yet).
  Fix once, in your own terminal (asks for your login password):
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
  Falling back to ad-hoc signing for this build; permission grants will not survive rebuilds.
MSG
        codesign --force --deep --sign - --identifier com.gabe.annotation-station "$APP"
    fi
else
    echo "⚠ no '$IDENTITY' identity; signing ad-hoc. Run Scripts/make-signing-cert.sh once so permission grants stick across rebuilds." >&2
    codesign --force --deep --sign - --identifier com.gabe.annotation-station "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/  /'

echo "✓ $APP"
