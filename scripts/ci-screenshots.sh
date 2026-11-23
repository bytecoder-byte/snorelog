#!/usr/bin/env bash
# Builds the app for the iOS Simulator, launches it with demo data and saves screenshots.
# Runs on a macOS GitHub Actions runner, or any Mac with Xcode 16+.
set -euo pipefail

OUT="${1:-screenshots}"
mkdir -p "$OUT"
BUNDLE_ID="com.example.snorelog"
DEVICE_ID="$(./scripts/pick-simulator.sh)"
echo "Using simulator $DEVICE_ID"

if ! xcodebuild build \
  -project SnoreLog.xcodeproj -scheme SnoreLog -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO > build.log 2>&1; then
  grep -E "error:" build.log | sort -u | head -80
  echo "Build failed. Full log in build.log"
  exit 1
fi
echo "Build succeeded"

APP="build/Build/Products/Debug-iphonesimulator/SnoreLog.app"
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl status_bar "$DEVICE_ID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$DEVICE_ID" "$APP"

shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" "$@"
  sleep 8
  xcrun simctl io "$DEVICE_ID" screenshot "$OUT/$name.png"
  echo "Saved $OUT/$name.png"
}

shoot 1-intro
shoot 2-tonight -demoData -hasSeenIntro YES -screen tonight
shoot 3-report -demoData -hasSeenIntro YES -screen report
shoot 4-history -demoData -hasSeenIntro YES -screen history
shoot 5-settings -demoData -hasSeenIntro YES -screen settings

# Zip the simulator build so it can be uploaded to a browser-based simulator such as Appetize.
ROOT="$PWD"
(cd "$(dirname "$APP")" && zip -qr "$ROOT/$OUT/SnoreLog-simulator.zip" SnoreLog.app)
