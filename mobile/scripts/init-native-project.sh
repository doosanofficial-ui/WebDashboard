#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ -d "ios" ] && [ -d "android" ]; then
  echo "ios/android already exist. Skip init."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Generating bare React Native native folders in temp workspace..."
npx @react-native-community/cli@latest init TelemetryMobileNative \
  --directory "$TMP_DIR/bootstrap" \
  --skip-install \
  --skip-git-init

cp -R "$TMP_DIR/bootstrap/ios" "$ROOT_DIR/ios"
cp -R "$TMP_DIR/bootstrap/android" "$ROOT_DIR/android"

if [ -f "$TMP_DIR/bootstrap/Gemfile" ] && [ ! -f "$ROOT_DIR/Gemfile" ]; then
  cp "$TMP_DIR/bootstrap/Gemfile" "$ROOT_DIR/Gemfile"
fi

if [ -f "$TMP_DIR/bootstrap/.watchmanconfig" ] && [ ! -f "$ROOT_DIR/.watchmanconfig" ]; then
  cp "$TMP_DIR/bootstrap/.watchmanconfig" "$ROOT_DIR/.watchmanconfig"
fi

echo "Native bootstrap complete."
echo "Next:"
echo "  1) cd mobile && npm install"
echo "  2) cd ios && pod install && cd ..   # iOS only"
echo "  3) npm run ios  or  npm run android"
