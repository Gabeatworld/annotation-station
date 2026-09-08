#!/bin/bash
# Cut a release: build, sign, package, and update the Sparkle appcast.
#
#   Scripts/release.sh --keys            # one-time: the EdDSA key pair Sparkle signs with
#   Scripts/release.sh 0.2.0             # Developer ID build, notarized and stapled
#   Scripts/release.sh --unnotarized 0.2.0   # self-signed build, no Apple membership needed
#
# Afterwards, publish what it leaves in dist/ (the script prints the exact commands).
#
# --unnotarized exists because notarization is the only part of this that costs money, and it
# buys exactly one thing: a clean first launch. Everything else — signing, packaging, EdDSA
# signatures, the appcast, auto-updates — works without an Apple Developer Program membership.
# The cost is that the first launch on someone else's Mac is blocked by Gatekeeper until they
# clear it once, by hand. dist/INSTALL.md is written for you to send them.
#
# It still signs with the stable self-signed certificate rather than ad-hoc, which matters more
# here than it does locally: TCC keys Screen Recording and Accessibility to the code
# requirement, and an ad-hoc requirement is the binary's cdhash. Ad-hoc builds would make every
# teammate re-grant both permissions on every single update.
#
# One-time setup for the notarized path, in this order:
#   1. Apple Developer Program membership, then a "Developer ID Application" certificate.
#   2. xcrun notarytool store-credentials "annotation-station" \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#      (app-specific password from appleid.apple.com — notarytool keeps it in the keychain,
#       so it is never in this repo.)
#   3. Scripts/release.sh --keys, and paste the public key into Resources/Info.plist.
# The unnotarized path needs step 3 only.
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

NOTARIZE=1
if [[ "${1:-}" == "--unnotarized" ]]; then
    NOTARIZE=0
    shift
fi

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: Scripts/release.sh [--unnotarized] <version>   (e.g. 0.2.0)" >&2; exit 1; }
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

if [[ $NOTARIZE == 1 ]]; then
    RELEASE=1 "$ROOT/Scripts/bundle.sh"
else
    # No RELEASE=1: bundle.sh falls back to the stable self-signed identity.
    "$ROOT/Scripts/bundle.sh"
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# --- notarize ---------------------------------------------------------------------------------
# Apple notarizes an archive, then the ticket is stapled to the .app so Gatekeeper can verify
# it offline. Staple before the final zip, or the copy people download is unstapled.
if [[ $NOTARIZE == 1 ]]; then
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
else
    echo "▸ skipping notarization (--unnotarized)"
fi

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

ASSETS=("$ZIP")
if [[ $NOTARIZE == 0 ]]; then
    # Written for the team, not for us: the one thing they have to do that a notarized build
    # would not ask of them.
    cat > "$DIST/INSTALL.md" <<'INSTALL'
# Installing Annotation Station

1. Unzip, and drag **AnnotationStation.app** into your **Applications** folder.
2. Open Terminal, paste this line and press return:

       xattr -dr com.apple.quarantine /Applications/AnnotationStation.app

3. Open the app normally. It lives in the menu bar — there is no window.

Step 2 is needed once, on this first install. macOS quarantines anything downloaded from the
internet, and this build is signed but not notarized by Apple, so without it macOS refuses to
open the app and offers no way through. Updates after this arrive automatically and will not
ask again.

If you would rather not use Terminal: skip step 2, try to open the app, let macOS block it,
then go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**
next to the message about Annotation Station. (On macOS 15 and later, Control-clicking the app
and choosing Open no longer works for this.)

## First run

The app needs two permissions macOS will prompt for, and cannot work without:

- **Screen Recording** — it screenshots the display you are annotating.
- **Accessibility** — it pastes the finished prompt into your editor for you.

Each prompt sends you to System Settings; tick Annotation Station and relaunch. Website
feedback mode will also ask, once per browser, for permission to read the page URL.

Press **⌘⇧A** to capture the screen under your cursor.
INSTALL
    ASSETS+=("$DIST/INSTALL.md")
fi

# macOS ships bash 3.2, which silently drops ${array[*]@Q} rather than quoting — build the
# argument list by hand so the printed command survives a path with a space in it.
ASSET_ARGS=""
for asset in "${ASSETS[@]}"; do ASSET_ARGS="$ASSET_ARGS \"$asset\""; done

cat <<MSG

✓ $VERSION built, signed$([[ $NOTARIZE == 1 ]] && echo ", notarized, stapled") and packaged.

  Publish it:
    git commit -am "Release $VERSION"
    gh release create "v$VERSION"$ASSET_ARGS --repo $REPO --title "$VERSION" --notes "…"
    git push

  The appcast is served from the repo, so the push is what actually ships the update —
  installs check https://raw.githubusercontent.com/$REPO/main/appcast.xml
MSG

if [[ $NOTARIZE == 0 ]]; then
    cat <<'MSG'
  ⚠ Not notarized. The first launch on someone else's Mac is blocked by Gatekeeper until they
    clear it by hand — dist/INSTALL.md tells them how, send it with the zip. Everything after
    that, updates included, behaves normally: Sparkle clears the quarantine flag on what it
    installs, so this is a one-time cost per person, not per release.
MSG
fi
