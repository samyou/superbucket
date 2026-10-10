#!/usr/bin/env bash
# Builds a universal, Developer ID-signed, notarized SuperBucket.dmg in ./dist.
#
# Usage:
#   scripts/release.sh [--version 1.2.3] [--adhoc] [--skip-notarize]
#
# Environment (for a real release):
#   SIGN_IDENTITY    "Developer ID Application: Your Name (TEAMID)"  (default: auto-detect)
#   NOTARY_PROFILE   notarytool keychain profile name                 (default: "superbucket")
#     – or –  APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD             (used by CI)
#
#   SPARKLE_PRIVATE_KEY  EdDSA private key (from `generate_keys -x`); default: the key in your login keychain
#   APPCAST_URL_PREFIX   where the DMGs are downloaded from (default: GitHub release for the tag)
#
# --adhoc builds and packages with an ad-hoc signature (no notarization); for local testing only.
# --appcast forces appcast generation even with --adhoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

VERSION=""
ADHOC=0
SKIP_NOTARIZE=0
APPCAST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --adhoc) ADHOC=1; APPCAST=0; shift ;;
    --appcast) APPCAST=1; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [ "$ADHOC" = 1 ]; then
  SIGN_IDENTITY="-"
  SKIP_NOTARIZE=1
elif [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
  if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<'MSG'
No "Developer ID Application" certificate found in your keychain.

  1. Join the Apple Developer Program: https://developer.apple.com/programs/
  2. Xcode > Settings > Accounts > your team > Manage Certificates > + > Developer ID Application
  3. Store notarization credentials once:
       xcrun notarytool store-credentials superbucket --apple-id <you@example.com> --team-id <TEAMID>
     (use an app-specific password from https://appleid.apple.com)

For a local unsigned test build run:  scripts/release.sh --adhoc
MSG
    exit 1
  fi
fi

echo "==> Version $VERSION ($BUILD_NUMBER), signing as: $SIGN_IDENTITY"

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 "${LINK_FLAGS[@]}" 2>&1 | tail -1
BIN="$(swift build -c release --arch arm64 --arch x86_64 "${LINK_FLAGS[@]}" --show-bin-path)/SuperBucket"
lipo -info "$BIN" | sed 's/^/    /'

echo "==> Assembling app bundle"
DIST=dist
APP="$DIST/SuperBucket.app"
rm -rf "$DIST"
mkdir -p "$DIST"
assemble_app "$BIN" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> Signing app"
sign_app "$APP" "$SIGN_IDENTITY"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Creating DMG"
DMG="$DIST/SuperBucket-$VERSION.dmg"
STAGING="$DIST/dmg-root"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "SuperBucket" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "$SKIP_NOTARIZE" = 1 ]; then
  echo "==> Skipping notarization"
else
  echo "==> Notarizing (this usually takes 1–5 minutes)"
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    xcrun notarytool submit "$DMG" --wait \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
  else
    xcrun notarytool submit "$DMG" --wait --keychain-profile "${NOTARY_PROFILE:-superbucket}"
  fi
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  echo "==> Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"

if [ "$APPCAST" = 1 ]; then
  echo "==> Generating Sparkle appcast"
  PREFIX="${APPCAST_URL_PREFIX:-https://github.com/samyou/superbucket/releases/download/v$VERSION/}"
  KEY_ARGS=()
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    KEY_FILE="$(mktemp)"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
    KEY_ARGS=(--ed-key-file "$KEY_FILE")
  fi
  "$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --download-url-prefix "$PREFIX" \
    --link "https://github.com/samyou/superbucket" -o "$DIST/appcast.xml" "$DIST"
  [ -n "${KEY_FILE:-}" ] && rm -f "$KEY_FILE"
  cp "$DIST/appcast.xml" appcast.xml
  echo "    wrote appcast.xml (commit this to main so installed apps see the update)"
fi
echo
echo "Built $DMG"
echo "sha256: $SHA"
