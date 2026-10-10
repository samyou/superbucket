# Shared packaging helpers. Source this; do not run it.

SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
LINK_FLAGS=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)

# assemble_app <binary> <app-path>
assemble_app() {
  local bin="$1" app="$2"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "$bin" "$app/Contents/MacOS/SuperBucket"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  mkdir -p build
  [ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build >/dev/null
  cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  [ -d "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle framework not found at $SPARKLE_FRAMEWORK (run swift build first)" >&2; return 1; }
  ditto "$SPARKLE_FRAMEWORK" "$app/Contents/Frameworks/Sparkle.framework"
}

# sign_app <app-path> <identity>   (Sparkle's nested components must be signed inside-out)
sign_app() {
  local app="$1" identity="$2"
  local fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  # Ad-hoc signatures carry no Team ID, so library validation (part of the hardened runtime) would refuse to
  # load the re-signed Sparkle framework. Hardened runtime is only enabled for real Developer ID builds.
  local opts=(--force --options runtime --timestamp --sign "$identity")
  [ "$identity" = "-" ] && opts=(--force --sign "$identity")
  codesign "${opts[@]}" "$fw/XPCServices/Installer.xpc"
  codesign "${opts[@]}" --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
  codesign "${opts[@]}" "$fw/Autoupdate"
  codesign "${opts[@]}" "$fw/Updater.app"
  codesign "${opts[@]}" "$app/Contents/Frameworks/Sparkle.framework"
  codesign "${opts[@]}" --entitlements Resources/SuperBucket.entitlements "$app"
  codesign --verify --deep --strict "$app"
}
