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
  --install   Install cleanly into /Applications/ztat.app and unregister duplicate dist copy
  --open      Launch the installed app (when --install) or dist/ztat.app
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

# Copy ZtatIsland vendored MediaRemoteAdapter.framework, NowPlayingTestClient, and .lproj tables
ISLAND_VENDOR="$ROOT/Packages/ZtatIsland/Vendor"
if [[ -d "$ISLAND_VENDOR/MediaRemoteAdapter.framework" ]]; then
    ditto "$ISLAND_VENDOR/MediaRemoteAdapter.framework" "$CONTENTS/Resources/MediaRemoteAdapter.framework"
fi
if [[ -f "$ISLAND_VENDOR/NowPlayingTestClient" ]]; then
    cp "$ISLAND_VENDOR/NowPlayingTestClient" "$CONTENTS/Helpers/NowPlayingTestClient"
    chmod +x "$CONTENTS/Helpers/NowPlayingTestClient"
fi
ISLAND_LOC_DIR="$ROOT/Packages/ZtatIsland/Sources/ZtatIsland/Resources/Localizations"
if [[ -d "$ISLAND_LOC_DIR" ]]; then
    for lproj in "$ISLAND_LOC_DIR"/*.lproj(N); do
        ditto "$lproj" "$CONTENTS/Resources/$(basename "$lproj")"
    done
fi

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

# Prefer an explicit ZTAT_CODESIGN_IDENTITY or an existing valid local code-signing identity (resolved
# to its unambiguous 40-char SHA-1 hash) so macOS TCC permissions survive rebuilds cleanly.
SIGN_ID="${ZTAT_CODESIGN_IDENTITY:-}"
SIGN_LABEL="$SIGN_ID"
resolve_signing_identity() {
    local pattern="$1"
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v pat="$pattern" 'index($0, pat) > 0 { print $2; exit }'
}
if [[ -z "$SIGN_ID" ]]; then
    if [[ -z "$(resolve_signing_identity '"Ztat Code Signing"')" ]] \
       && security find-certificate -c "Ztat Code Signing" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
        tmp_cer="$(mktemp "${TMPDIR:-/tmp}/ztat-cert.XXXXXX.cer")"
        security find-certificate -c "Ztat Code Signing" -p ~/Library/Keychains/login.keychain-db > "$tmp_cer" 2>/dev/null || true
        security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp_cer" 2>/dev/null || true
        rm -f "$tmp_cer"
    fi

    for candidate in '"Ztat Code Signing"' '"ztat Local Signing"' '"Apple Development:' '"Developer ID Application:'; do
        HASH="$(resolve_signing_identity "$candidate" || true)"
        if [[ -n "$HASH" ]]; then
            SIGN_ID="$HASH"
            SIGN_LABEL="$(security find-identity -v -p codesigning 2>/dev/null | awk -v h="$HASH" '$2 == h { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }')"
            break
        fi
    done

    if [[ -z "$SIGN_ID" ]]; then
        SIGN_ID="-"
        SIGN_LABEL="ad-hoc (-)"
    fi
fi

echo "▸ [6/6] Signing ($SIGN_LABEL) & verifying bundle..."
if [[ -d "$CONTENTS/Resources/MediaRemoteAdapter.framework" ]]; then
    codesign --force --sign "$SIGN_ID" --timestamp=none "$CONTENTS/Resources/MediaRemoteAdapter.framework"
fi
for dylib in "$CONTENTS/Frameworks"/*.dylib(N); do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib"
done
for helper in "$CONTENTS/Helpers"/*(N); do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$helper"
done
codesign --force --sign "$SIGN_ID" --timestamp=none "$CONTENTS/MacOS/ztat-hold"
codesign --force --sign "$SIGN_ID" --timestamp=none "$DIST_DIR/ztat-hold"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
if [[ -d "$CONTENTS/Resources/MediaRemoteAdapter.framework" ]]; then
    codesign --verify --strict "$CONTENTS/Resources/MediaRemoteAdapter.framework"
fi
DR_OUTPUT="$(codesign -d -r- "$APP_BUNDLE" 2>&1 || true)"
if [[ "$SIGN_ID" != "-" ]] && ! echo "$DR_OUTPUT" | grep -q "certificate leaf"; then
    echo "Error: expected certificate-pinned designated requirement for stable TCC, got:" >&2
    echo "$DR_OUTPUT" >&2
    exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
FINAL_APP="$APP_BUNDLE"

if [[ "$INSTALL_MODE" == "1" ]]; then
    DEST_APP="/Applications/$(basename "$APP_BUNDLE")"
    STAGING_APP="${DEST_APP}.staging"
    OLD_APP="${DEST_APP}.old"

    echo "▸ Stopping running ztat instances targeting $DEST_APP..."
    TARGET_PIDS=("${(@f)$(pgrep -f "$DEST_APP/Contents/MacOS/ztat" 2>/dev/null || true)}")
    for pid in "${TARGET_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    # Poll cleanly up to 5 seconds for graceful teardown before forcing exit
    for _ in {1..50}; do
        pgrep -f "$DEST_APP/Contents/MacOS/ztat" >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -f "$DEST_APP/Contents/MacOS/ztat" >/dev/null 2>&1; then
        pkill -KILL -f "$DEST_APP/Contents/MacOS/ztat" 2>/dev/null || true
        sleep 0.2
    fi

    echo "▸ Installing atomically to $DEST_APP..."
    rm -rf "$STAGING_APP" "$OLD_APP"
    ditto "$APP_BUNDLE" "$STAGING_APP"
    codesign --verify --deep --strict "$STAGING_APP"
    if [[ -d "$STAGING_APP/Contents/Resources/MediaRemoteAdapter.framework" ]]; then
        codesign --verify --strict "$STAGING_APP/Contents/Resources/MediaRemoteAdapter.framework"
    fi
    if [[ -d "$DEST_APP" ]]; then
        mv "$DEST_APP" "$OLD_APP"
    fi
    mv "$STAGING_APP" "$DEST_APP"
    rm -rf "$OLD_APP"

    # CRITICAL: Unregister & remove dist/.app when installing into /Applications so LaunchServices & macOS TCC
    # never have two competing dev.ztat.app bundles on disk.
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$APP_BUNDLE"
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
    FINAL_APP="$DEST_APP"
    echo "✓ Installed $DEST_APP (sole LaunchServices bundle)"
fi

echo "✓ Built successfully:"
echo "  App : $FINAL_APP"
echo "  CLI : $DIST_DIR/ztat-hold"
echo "  Sign: $SIGN_LABEL ($SIGN_ID)"
echo "  DR  : $(echo "$DR_OUTPUT" | grep -E 'designated =>' | head -n 1)"
if [[ "$SIGN_ID" == "-" ]]; then
    echo "  Note: Ad-hoc signed (-). After rebuilding, if macOS TCC ignores an old toggle, click '重新开始' in ztat 设置 → 权限与隐私."
fi

if [[ "$OPEN_APP" == "1" ]]; then
    open "$FINAL_APP"
fi
