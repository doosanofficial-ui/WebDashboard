#!/usr/bin/env bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-build}"
if [[ "$MODE" != "build" && "$MODE" != "test" ]]; then
  echo 'Usage: verify.sh [build|test] (test requires SIMULATOR_ID)' >&2
  exit 2
fi
if [[ "$MODE" == "test" && -z "${SIMULATOR_ID:-}" ]]; then
  echo 'Set SIMULATOR_ID to an available iOS simulator UUID.' >&2
  exit 2
fi
xcodebuild -version
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$XCODEGEN_BIN" ]]; then
  echo 'Install XcodeGen with its share/xcodegen/SettingPresets resources.' >&2
  exit 2
fi
ARTIFACT_DIR="$(mktemp -d /tmp/telemetry-ios-verify.XXXXXX)"
printf 'Verification artifacts: %s\n' "$ARTIFACT_DIR"
# Xcode response files split NBSP paths. Stage identical sources at an ASCII path.
mkdir "$ARTIFACT_DIR/source"
rsync -a --exclude '*.xcodeproj' --exclude '.swiftpm' --exclude '.build' --exclude '.DS_Store' \
  "$SOURCE_DIR/" "$ARTIFACT_DIR/source/"
cd "$ARTIFACT_DIR/source"
find App TelemetryCore/Sources TelemetryCore/Tests UITests -type f -exec shasum -a 256 {} \; > "$ARTIFACT_DIR/source-sha256.txt"
shasum -a 256 project.yml TelemetryCore/Package.swift >> "$ARTIFACT_DIR/source-sha256.txt"
"$XCODEGEN_BIN" generate --spec project.yml 2>&1 | tee "$ARTIFACT_DIR/generate.log"
if grep -q 'settings found' "$ARTIFACT_DIR/generate.log"; then
  echo 'XcodeGen setting presets are missing; generation is not valid.' >&2
  exit 1
fi
swift test --package-path TelemetryCore --scratch-path "$ARTIFACT_DIR/core-build" 2>&1 | tee "$ARTIFACT_DIR/core-tests.log"
DESTINATION='generic/platform=iOS Simulator'
if [[ "$MODE" == "test" ]]; then DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"; fi
xcodebuild -project Telemetry.xcodeproj -scheme Telemetry \
  -destination "$DESTINATION" -derivedDataPath "$ARTIFACT_DIR/app-build" \
  -resultBundlePath "$ARTIFACT_DIR/result.xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES "$MODE" 2>&1 | tee "$ARTIFACT_DIR/app-build.log"
printf 'Verified %s. Evidence: %s\n' "$MODE" "$ARTIFACT_DIR"
