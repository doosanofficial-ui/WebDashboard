#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${DEVICE_ID:-}"
APP_PATH="${APP_PATH:-}"
BUNDLE_ID="${BUNDLE_ID:-local.webdashboard.Telemetry}"
LOG_DIR="${LOG_DIR:-$(mktemp -d /tmp/telemetry-ios-device-run.XXXXXX)}"

if [[ -z "$DEVICE_ID" || -z "$APP_PATH" ]]; then
  cat >&2 <<'USAGE'
Usage:
  DEVICE_ID="<core-device-id>" \
  APP_PATH="/path/to/Telemetry.app" \
  ./mobile-ios/scripts/verify_device.sh

The app must already be signed for the target device. This script does not
enter credentials, approve MFA, or bypass device trust.
USAGE
  exit 2
fi

mkdir -p "$LOG_DIR"
DETAILS="$LOG_DIR/device-details.log"
INSTALL_LOG="$LOG_DIR/install.log"
LAUNCH_LOG="$LOG_DIR/launch.log"
PROCESS_LOG="$LOG_DIR/processes.log"

echo "Device verification artifacts: $LOG_DIR"
xcrun devicectl device info details --device "$DEVICE_ID" >"$DETAILS" 2>&1
sed -n '1,70p' "$DETAILS"

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
  2>&1 | tee "$INSTALL_LOG"

set +e
xcrun devicectl --timeout 30 device process launch \
  --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" \
  2>&1 | tee "$LAUNCH_LOG"
launch_status=${PIPESTATUS[0]}
set -e

xcrun devicectl device info processes --device "$DEVICE_ID" \
  >"$PROCESS_LOG" 2>&1 || true

if [[ "$launch_status" -ne 0 ]]; then
  if rg -qi 'not been explicitly trusted|Untrusted|Unable to Verify' "$LAUNCH_LOG"; then
    cat >&2 <<'TRUST'

Launch was denied by device trust/verification.
On the iPhone, open the installed app once, then complete:
Settings > General > VPN & Device Management >
Apple Development > Trust or Allow & Restart.
Keep the device online and rerun this script.
TRUST
    exit 10
  fi
  if rg -qi 'device was not, or could not, be unlocked|BSErrorCodeDescription = Locked|FBSOpenApplicationServiceErrorDomain.*Locked' "$LAUNCH_LOG"; then
    cat >&2 <<'LOCKED'

Launch was denied because the iPhone is locked.
Unlock the device, keep it connected, and rerun this script.
This is not a developer-trust failure and the script will not enter a passcode.
LOCKED
    exit 12
  fi
  echo "Launch failed for a non-trust reason. See $LAUNCH_LOG." >&2
  exit "$launch_status"
fi

if ! rg -q "$BUNDLE_ID|Telemetry.app/Telemetry" "$PROCESS_LOG"; then
  echo "Launch returned success but the process was not observed. See $PROCESS_LOG." >&2
  exit 11
fi

echo "Physical launch PASS: $BUNDLE_ID"
echo "Logs: $LOG_DIR"
