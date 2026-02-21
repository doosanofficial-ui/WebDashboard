#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios"

if [ ! -d "$IOS_DIR" ]; then
  echo "ios directory not found. Run: npm run init-native"
  exit 1
fi

PLIST_PATH="$(find "$IOS_DIR" -maxdepth 3 -name Info.plist | grep -v '/Pods/' | head -n 1 || true)"
if [ -z "$PLIST_PATH" ]; then
  echo "Info.plist not found under $IOS_DIR"
  exit 1
fi

PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [ ! -x "$PLIST_BUDDY" ]; then
  echo "PlistBuddy not found: $PLIST_BUDDY"
  exit 1
fi

ensure_key() {
  local key="$1"
  local type="$2"
  local value="$3"
  if "$PLIST_BUDDY" -c "Print :$key" "$PLIST_PATH" >/dev/null 2>&1; then
    "$PLIST_BUDDY" -c "Set :$key $value" "$PLIST_PATH"
  else
    "$PLIST_BUDDY" -c "Add :$key $type $value" "$PLIST_PATH"
  fi
}

ensure_array_item() {
  local key="$1"
  local value="$2"
  if ! "$PLIST_BUDDY" -c "Print :$key" "$PLIST_PATH" >/dev/null 2>&1; then
    "$PLIST_BUDDY" -c "Add :$key array" "$PLIST_PATH"
  fi

  local items
  items="$("$PLIST_BUDDY" -c "Print :$key" "$PLIST_PATH" | tr -d '\r' || true)"
  if echo "$items" | grep -q "$value"; then
    return
  fi

  local idx
  idx="$(echo "$items" | grep -E '^[[:space:]]*[0-9]+ = ' | wc -l | tr -d '[:space:]')"
  "$PLIST_BUDDY" -c "Add :$key:$idx string $value" "$PLIST_PATH"
}

ensure_key "NSLocationWhenInUseUsageDescription" "string" "Telemetry dashboard needs location while app is in use."
ensure_key "NSLocationAlwaysAndWhenInUseUsageDescription" "string" "Telemetry dashboard needs location updates during driving, including background."
ensure_array_item "UIBackgroundModes" "location"

echo "Updated iOS location keys in: $PLIST_PATH"
echo "Next: open Xcode -> Signing & Capabilities -> verify Background Modes > Location updates is enabled."
