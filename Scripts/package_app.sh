#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PullPing"
BUNDLE_ID="com.padina.pullping"
BUILD_CONFIG="release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
# RELEASE=1: strip paths and symbols, then zip into dist/PullPing.zip for GitHub Releases and the Homebrew cask.
RELEASE="${RELEASE:-}"

cd "$ROOT_DIR"

# Universal binary (Apple Silicon + Intel). The output dir differs per build system, so ask SwiftPM for it.
BUILD_ARGS=(-c "$BUILD_CONFIG" --arch arm64 --arch x86_64)
# Release builds must not embed the build machine's home path (public repo).
[[ -n "$RELEASE" ]] && BUILD_ARGS+=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp Info.plist "$CONTENTS_DIR/Info.plist"
cp Assets/icons/menubar.png Assets/icons/menubar@2x.png "$RESOURCES_DIR/"

# macOS 26+ Liquid Glass icon (Dark/Clear/Tinted looks); needs Xcode 26+ actool. Info.plist already names it (CFBundleIconName).
if [[ -d AppIcon.icon ]]; then
    if xcrun actool AppIcon.icon --compile "$RESOURCES_DIR" --platform macosx \
        --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$APP_DIR/icon-partial.plist" >/dev/null; then
        rm -f "$APP_DIR/icon-partial.plist"
    else
        echo "note: AppIcon.icon not compiled (needs Xcode 26+ actool); macOS 26 shows the classic icon" >&2
    fi
fi
# The house-style icns (macOS 14/15 icon) goes in last: actool also writes an AppIcon.icns.
cp Assets/icons/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

chmod +x "$MACOS_DIR/$APP_NAME"
# Strip before signing: strip invalidates a signature.
[[ -n "$RELEASE" ]] && strip -S -x "$MACOS_DIR/$APP_NAME"

# Stable identity (when in the keychain) keeps grants across updates; ad-hoc otherwise (CI, contributors).
SIGN_IDENTITY="${PULLPING_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if grep -q "KeyLayoutSwitcher Dev" <<<"$IDENTITIES"; then
        SIGN_IDENTITY="KeyLayoutSwitcher Dev"
    fi
fi
SIGN_WITH="${SIGN_IDENTITY:--}"

# Inside-out: nested code first (none today), then the app. No hardened runtime: it was never enabled.
for nested in "$CONTENTS_DIR"/Frameworks/* "$CONTENTS_DIR"/XPCServices/*; do
    [[ -e "$nested" ]] && codesign --force --sign "$SIGN_WITH" "$nested"
done
codesign --force --sign "$SIGN_WITH" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "signed with: $SIGN_IDENTITY"
else
    echo "stable signing identity not found: ad-hoc signed"
fi

if [[ -n "$RELEASE" ]]; then
    ZIP="$DIST_DIR/$APP_NAME.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"
    echo "SHA-256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
    echo "$ZIP"
fi

echo "$APP_DIR"
