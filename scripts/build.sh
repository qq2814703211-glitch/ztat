#!/usr/bin/env zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure Apple Command Line Tools build & .app bundle packager for ztat (no Xcode.app required).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SDK="${ZTAT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
INTERFACE_COMPILER_VERSION="${ZTAT_INTERFACE_COMPILER_VERSION:-6.3.2}"
STAMP_SDK_VERSION="${ZTAT_STAMP_SDK_VERSION:-26.5}"
MINOS="14.0"

CONFIG="release"
DEV_MODE=0
INSTALL_MODE=0
OPEN_APP=0

for arg in "$@"; do
    case "$arg" in
        --dev)
            CONFIG="debug"
            DEV_MODE=1
            ;;
        --release)
            CONFIG="release"
            DEV_MODE=0
            ;;
        --install)
            INSTALL_MODE=1
            ;;
        --open)
            OPEN_APP=1
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./scripts/build.sh [--dev | --release] [--install] [--open]

Options:
  --dev       Build debug configuration (bundle ID dev.ztat.app.dev, name "ztat (Dev)")
  --release   Build optimized release configuration (default)
  --install   Copy dist/ztat.app into /Applications/ztat.app
  --open      Launch dist/ztat.app after packaging
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$SDK" ]]; then
    echo "Error: pinned macOS 26 SDK not found at $SDK" >&2
    echo "Set ZTAT_SDK to a valid MacOSX26.sdk path." >&2
    exit 1
fi

SWIFT_FLAGS=(
    -c "$CONFIG"
    -Xswiftc -sdk -Xswiftc "$SDK"
    -Xswiftc -Xfrontend -Xswiftc -interface-compiler-version
    -Xswiftc -Xfrontend -Xswiftc "$INTERFACE_COMPILER_VERSION"
)

export SDKROOT="$SDK"
cd "$ROOT"

echo "▸ [1/6] Building ztat ($CONFIG, SDK=$(basename "$SDK"))..."
swift build "${SWIFT_FLAGS[@]}" --product ztat
BIN_PATH="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "▸ [2/6] Building ztat-hold CLI ($CONFIG)..."
swift build --package-path Packages/ZtatPowerGuard "${SWIFT_FLAGS[@]}" --product ztat-hold
CLI_BIN_PATH="$(swift build --package-path Packages/ZtatPowerGuard "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "▸ [3/6] Building optional native helpers..."
AIRPODS_HELPER=""
AIRPODS_DYLIB=""
if swift build --package-path Packages/ZtatStatusTrio "${SWIFT_FLAGS[@]}" --product StatusTrioAirPodsHelper >/dev/null 2>&1; then
    ST_BIN="$(swift build --package-path Packages/ZtatStatusTrio "${SWIFT_FLAGS[@]}" --show-bin-path)"
    [[ -x "$ST_BIN/StatusTrioAirPodsHelper" ]] && AIRPODS_HELPER="$ST_BIN/StatusTrioAirPodsHelper"
fi
if swift build --package-path Packages/ZtatStatusTrio "${SWIFT_FLAGS[@]}" --product AirPodsAudioContext >/dev/null 2>&1; then
    ST_BIN="$(swift build --package-path Packages/ZtatStatusTrio "${SWIFT_FLAGS[@]}" --show-bin-path)"
    [[ -f "$ST_BIN/libAirPodsAudioContext.dylib" ]] && AIRPODS_DYLIB="$ST_BIN/libAirPodsAudioContext.dylib"
fi

NOWPLAYING_DYLIB=""
if swift build --package-path Packages/ZtatVorssaint "${SWIFT_FLAGS[@]}" --product ZtatNowPlayingAdapter >/dev/null 2>&1; then
    VS_BIN="$(swift build --package-path Packages/ZtatVorssaint "${SWIFT_FLAGS[@]}" --show-bin-path)"
    [[ -f "$VS_BIN/libZtatNowPlayingAdapter.dylib" ]] && NOWPLAYING_DYLIB="$VS_BIN/libZtatNowPlayingAdapter.dylib"
fi

echo "▸ [4/6] Generating bespoke AppIcon.icns..."
DIST_DIR="$ROOT/dist"
APP_NAME="ztat"
BUNDLE_ID="dev.ztat.app"
APP_BUNDLE="$DIST_DIR/ztat.app"
if [[ "$DEV_MODE" == "1" ]]; then
    APP_NAME="ztat (Dev)"
    BUNDLE_ID="dev.ztat.app.dev"
    APP_BUNDLE="$DIST_DIR/ztat-dev.app"
fi

mkdir -p "$DIST_DIR"
ICON_PATH="$DIST_DIR/AppIcon.icns"
swift -sdk "$SDK" "$ROOT/scripts/generate-icon.swift" "$ICON_PATH"

echo "▸ [5/6] Assembling $(basename "$APP_BUNDLE")..."
rm -rf "$APP_BUNDLE"
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$CONTENTS/Helpers"

cp "$BIN_PATH/ztat" "$CONTENTS/MacOS/ztat"
chmod +x "$CONTENTS/MacOS/ztat"

cp "$CLI_BIN_PATH/ztat-hold" "$CONTENTS/MacOS/ztat-hold"
chmod +x "$CONTENTS/MacOS/ztat-hold"
cp "$CLI_BIN_PATH/ztat-hold" "$DIST_DIR/ztat-hold"
chmod +x "$DIST_DIR/ztat-hold"

cp "$ICON_PATH" "$CONTENTS/Resources/AppIcon.icns"
rm -f "$ICON_PATH"

# Copy all SwiftPM resource bundles produced by root & local packages into Contents/Resources
for bundle in "$BIN_PATH"/*.bundle(N); do
    ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
done

if [[ -n "$AIRPODS_HELPER" ]]; then
    cp "$AIRPODS_HELPER" "$CONTENTS/Helpers/StatusTrioAirPodsHelper"
    chmod +x "$CONTENTS/Helpers/StatusTrioAirPodsHelper"
fi
if [[ -n "$AIRPODS_DYLIB" ]]; then
    cp "$AIRPODS_DYLIB" "$CONTENTS/Helpers/libAirPodsAudioContext.dylib"
    install_name_tool -id "@loader_path/libAirPodsAudioContext.dylib" "$CONTENTS/Helpers/libAirPodsAudioContext.dylib" 2>/dev/null || true
fi
if [[ -n "$NOWPLAYING_DYLIB" ]]; then
    cp "$NOWPLAYING_DYLIB" "$CONTENTS/Frameworks/libZtatNowPlayingAdapter.dylib"
    install_name_tool -id "@rpath/libZtatNowPlayingAdapter.dylib" "$CONTENTS/Frameworks/libZtatNowPlayingAdapter.dylib" 2>/dev/null || true
fi

if ! otool -l "$CONTENTS/MacOS/ztat" | grep -Fq 'path @executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/ztat"
fi

cp "$ROOT/Support/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

# Stamp LC_BUILD_VERSION sdk to macOS 26.5 so Tahoe/27 renders native Liquid Glass (NSGlassEffectView)
stamp_binary() {
    local target="$1"
    if [[ "$CONFIG" == "release" ]]; then
        strip -x "$target" 2>/dev/null || true
    fi
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/ztat-vtool.XXXXXX")"
    xcrun vtool -set-build-version macos "$MINOS" "$STAMP_SDK_VERSION" -replace -output "$tmp" "$target"
    mv "$tmp" "$target"
    chmod +x "$target"
}

stamp_binary "$CONTENTS/MacOS/ztat"
stamp_binary "$CONTENTS/MacOS/ztat-hold"
stamp_binary "$DIST_DIR/ztat-hold"
[[ -x "$CONTENTS/Helpers/StatusTrioAirPodsHelper" ]] && stamp_binary "$CONTENTS/Helpers/StatusTrioAirPodsHelper"

echo "▸ [6/6] Ad-hoc signing & verifying bundle..."
SIGN_ID="${ZTAT_CODESIGN_IDENTITY:--}"
for dylib in "$CONTENTS/Frameworks"/*.dylib(N); do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib"
done
for helper in "$CONTENTS/Helpers"/*(N); do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$helper"
done
codesign --force --sign "$SIGN_ID" --timestamp=none "$CONTENTS/MacOS/ztat-hold"
codesign --force --sign "$SIGN_ID" --timestamp=none "$DIST_DIR/ztat-hold"
codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "✓ Built successfully:"
echo "  App : $APP_BUNDLE"
echo "  CLI : $DIST_DIR/ztat-hold"

if [[ "$INSTALL_MODE" == "1" ]]; then
    DEST_APP="/Applications/$(basename "$APP_BUNDLE")"
    echo "▸ Installing to $DEST_APP..."
    rm -rf "$DEST_APP"
    ditto "$APP_BUNDLE" "$DEST_APP"
    echo "✓ Installed $DEST_APP"
fi

if [[ "$OPEN_APP" == "1" ]]; then
    open "$APP_BUNDLE"
fi
