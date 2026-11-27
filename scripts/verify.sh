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
# The app enforces a single instance (flock). If a ztat is already running, the smoke
# launch would exit immediately by design, so pause the running copy and restore it afterwards.
RESTORE_APP=""
RUNNING_PID="$(pgrep -x ztat | head -n 1 || true)"
if [[ -n "$RUNNING_PID" ]]; then
    RESTORE_APP="$(ps -o comm= -p "$RUNNING_PID" | sed -E 's#(\.app)/Contents/MacOS/.*#\1#')"
    echo "Pausing running ztat (PID $RUNNING_PID) for the smoke test..."
    kill -TERM "$RUNNING_PID" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$RUNNING_PID" 2>/dev/null || break; sleep 0.1; done
fi
restore_running_app() {
    rm -f "$SMOKE_LOG"
    # Keep LaunchServices pointing at the installed copy, not the dist build we just opened.
    if [[ -d /Applications/ztat.app ]]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$ROOT/dist/ztat.app" >/dev/null 2>&1 || true
    fi
    if [[ -n "$RESTORE_APP" && -d "$RESTORE_APP" ]]; then
        open "$RESTORE_APP" || true
    fi
}
trap restore_running_app EXIT
# Launch through LaunchServices so the app is its own TCC "responsible process"
# (a raw shell exec makes TCC attribute privacy requests to the parent shell/terminal).
open -g -n --stdout "$SMOKE_LOG" --stderr "$SMOKE_LOG" "$ROOT/dist/ztat.app"
APP_PID=""
for _ in {1..50}; do
    APP_PID="$(pgrep -f "^$APP_BIN\$" | head -n 1 || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
done
if [[ -z "$APP_PID" ]]; then
    echo "Error: ztat failed to launch during smoke test!" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi
sleep 3
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "Error: ztat exited prematurely during smoke test!" >&2
    cat "$SMOKE_LOG" >&2
    exit 1
fi
echo "✓ ztat stayed alive cleanly (PID $APP_PID); sending SIGTERM..."
kill -TERM "$APP_PID"
for _ in {1..50}; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "Error: ztat did not terminate within 5s of SIGTERM!" >&2
    kill -KILL "$APP_PID" 2>/dev/null || true
    exit 1
fi
if [[ -s "$SMOKE_LOG" ]]; then
    echo "Runtime log excerpt:"
    head -n 30 "$SMOKE_LOG"
fi
echo "✓ ztat terminated cleanly."
echo ""
echo "=== ALL ZTAT VERIFICATION GATES PASSED ==="
