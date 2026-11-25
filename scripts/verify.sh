#!/usr/bin/env zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Comprehensive build, unit-test, signing, binary-hygiene & smoke verification for ztat.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SDK="${ZTAT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
INTERFACE_COMPILER_VERSION="${ZTAT_INTERFACE_COMPILER_VERSION:-6.3.2}"
export SDKROOT="$SDK"
cd "$ROOT"

echo "=== 1. Upstream Governance & Patch Audit ==="
./scripts/sync-upstream.sh status
echo ""
echo "ZTAT-PATCH summary:"
./scripts/sync-upstream.sh patches --summary

echo ""
echo "=== 2. Swift Testing Suite (ZtatTests) ==="
TESTING_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"
TEST_EXTRA_FLAGS=()
if [[ -d "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing" ]]; then
    TEST_EXTRA_FLAGS+=(-Xswiftc -external-plugin-path -Xswiftc "$TESTING_PLUGIN")
fi
swift test \
    --disable-xctest \
    --enable-swift-testing \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -Xfrontend -Xswiftc -interface-compiler-version \
    -Xswiftc -Xfrontend -Xswiftc "$INTERFACE_COMPILER_VERSION" \
    "${TEST_EXTRA_FLAGS[@]}"

echo ""
echo "=== 3. Release Build & Bundle Verification ==="
./scripts/build.sh --release

APP_BIN="$ROOT/dist/ztat.app/Contents/MacOS/ztat"
CLI_BIN="$ROOT/dist/ztat-hold"

echo ""
echo "=== 4. Binary SDK Stamp, Resource Bundles & Dynamic Linkage Audit ==="
xcrun vtool -show-build "$APP_BIN" | grep -E "platform|minos|sdk"
echo "Embedded SwiftPM resource bundles:"
ls -1 "$ROOT/dist/ztat.app/Contents/Resources" | grep '\.bundle$' || true
echo "Embedded helpers & frameworks:"
ls -1 "$ROOT/dist/ztat.app/Contents/Helpers" "$ROOT/dist/ztat.app/Contents/Frameworks" 2>/dev/null || true
echo "Dynamic linkage (otool -L):"
otool -L "$APP_BIN"
codesign --verify --deep --strict --verbose=2 "$ROOT/dist/ztat.app"

echo ""
echo "=== 5. CLI Hardware Probe Smoke Test (ztat-hold status) ==="
"$CLI_BIN" status

echo ""
echo "=== 6. Headless Launch & Clean Termination Smoke Test ==="
SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/ztat-smoke.XXXXXX.log")"
trap 'rm -f "$SMOKE_LOG"' EXIT
"$APP_BIN" >"$SMOKE_LOG" 2>&1 &
APP_PID=$!
sleep 3
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "Error: ztat exited prematurely during smoke test!" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi
echo "✓ ztat stayed alive cleanly (PID $APP_PID); sending SIGTERM..."
kill -TERM "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
if [[ -s "$SMOKE_LOG" ]]; then
    echo "Runtime log excerpt:"
    head -n 30 "$SMOKE_LOG"
fi
echo "✓ ztat terminated cleanly."
echo ""
echo "=== ALL ZTAT VERIFICATION GATES PASSED ==="
