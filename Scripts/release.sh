#!/bin/bash
# Cut a release: build with a Developer ID, notarize, staple, and update the Sparkle appcast.
#
#   Scripts/release.sh --keys     # one-time: create the EdDSA key pair Sparkle signs with
#   Scripts/release.sh 0.2.0      # build + notarize + staple + sign + appcast entry
#
# Afterwards, publish what it leaves in dist/ (the script prints the exact commands).
#
# One-time setup, in this order:
#   1. Apple Developer Program membership, then a "Developer ID Application" certificate.
#   2. xcrun notarytool store-credentials "annotation-station" \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#      (app-specific password from appleid.apple.com — notarytool keeps it in the keychain,
#       so it is never in this repo.)
#   3. Scripts/release.sh --keys, and paste the public key into Resources/Info.plist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AnnotationStation"
APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
APPCAST="$ROOT/appcast.xml"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-annotation-station}"
REPO="Gabeatworld/annotation-station"

SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -maxdepth 5 -type d -name bin -path "*sparkle*" | head -1)"
[[ -n "$SPARKLE_BIN" ]] || { echo "✗ Sparkle tools not found — run 'swift package resolve' first" >&2; exit 1; }

# --- one-time key generation ---------------------------------------------------------------
# The private key lives in the login keychain and never touches the repo. Losing it means
# existing installs can no longer verify updates, so back up the printed private key somewhere
# safe (1Password) the one time generate_keys shows it.
if [[ "${1:-}" == "--keys" ]]; then
    "$SPARKLE_BIN/generate_keys"
    echo
    echo "▸ Paste the public key above into Resources/Info.plist under SUPublicEDKey, then commit."
    exit 0
fi

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: Scripts/release.sh <version>   (e.g. 0.2.0)" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ version must look like 0.2.0" >&2; exit 1; }

PUBKEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
if [[ -z "$PUBKEY" ]]; then
    echo "✗ SUPublicEDKey is empty in Resources/Info.plist — run 'Scripts/release.sh --keys' first." >&2
    echo "  Shipping without it would leave every install unable to verify this update." >&2
    exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "✗ working tree is dirty; commit first so the release matches a known commit." >&2
    exit 1
fi

# --- version stamp ---------------------------------------------------------------------------
# CFBundleShortVersionString is what people read; CFBundleVersion is what Sparkle compares, so
# it has to increase monotonically — the commit count does that for free.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
echo "▸ version $VERSION (build $BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$ROOT/Resources/Info.plist"

RELEASE=1 "$ROOT/Scripts/bundle.sh"

# --- notarize ---------------------------------------------------------------------------------
# Apple notarizes an archive, then the ticket is stapled to the .app so Gatekeeper can verify
# it offline. Staple before the final zip, or the copy people download is unstapled.
rm -rf "$DIST"
mkdir -p "$DIST"
SUBMIT_ZIP="$DIST/$APP_NAME-submit.zip"
echo "▸ zipping for notarization"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "▸ notarytool submit (this takes a few minutes)"
if ! xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    cat >&2 <<MSG
✗ notarization failed. For the per-issue detail:
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE"
    xcrun notarytool log <submission-id> --keychain-profile "$KEYCHAIN_PROFILE"
  If it says the profile does not exist, run the store-credentials command in this file's header.
MSG
    exit 1
fi

echo "▸ stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$SUBMIT_ZIP"

# --- package + appcast --------------------------------------------------------------------------
# generate_appcast signs each archive with the private key from the keychain and writes the
# appcast. Only this version's zip sits in dist/, so entries for older versions are carried over
# from the existing appcast untouched — their download URLs point at their own release tags.
ZIP="$DIST/$APP_NAME-$VERSION.zip"
echo "▸ packaging $(basename "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"
[[ -f "$APPCAST" ]] && cp "$APPCAST" "$DIST/appcast.xml"

echo "▸ generate_appcast"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    "$DIST"
cp "$DIST/appcast.xml" "$APPCAST"

cat <<MSG

✓ $VERSION built, notarized, stapled and signed.

  Publish it:
    git commit -am "Release $VERSION"
    gh release create "v$VERSION" "$ZIP" --repo $REPO --title "$VERSION" --notes "…"
    git push

  The appcast is served from the repo, so the push is what actually ships the update —
  installs check https://raw.githubusercontent.com/$REPO/main/appcast.xml
MSG
