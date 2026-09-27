#!/usr/bin/env bash
set -euo pipefail

DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "$DEVICE_UDID" ]]; then
  echo 'Set DEVICE_UDID to the physical iPhone UDID.' >&2
  exit 2
fi

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$XCODEGEN_BIN" ]]; then
  echo 'Install XcodeGen with its SettingPresets resources.' >&2
  exit 2
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-$(mktemp -d /tmp/telemetry-ios-device-build.XXXXXX)}"
mkdir -p "$ARTIFACT_DIR/source"

# Xcode response files split the NBSP-containing canonical workspace path.
rsync -a --exclude '*.xcodeproj' --exclude '.swiftpm' --exclude '.build' --exclude '.DS_Store' \
  "$SOURCE_DIR/" "$ARTIFACT_DIR/source/"
cd "$ARTIFACT_DIR/source"
"$XCODEGEN_BIN" generate --spec project.yml > "$ARTIFACT_DIR/generate.log" 2>&1

xcodebuild -project Telemetry.xcodeproj -scheme Telemetry \
  -destination "id=$DEVICE_UDID" \
  -derivedDataPath "$ARTIFACT_DIR/derived" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=548HKZYKDP \
  build > "$ARTIFACT_DIR/build.log" 2>&1

APP_PATH="$ARTIFACT_DIR/derived/Build/Products/Debug-iphoneos/Telemetry.app"
test -d "$APP_PATH"
printf 'Device build PASS\nArtifact: %s\n' "$APP_PATH"
printf 'Evidence: %s\n' "$ARTIFACT_DIR"
