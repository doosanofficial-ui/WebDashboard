#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
SRC_DIR="$ROOT_DIR/native-android-bridge"
MANIFEST_PATH="$ANDROID_DIR/app/src/main/AndroidManifest.xml"

if [ ! -d "$ANDROID_DIR" ]; then
  echo "android directory not found. Run: npm run init-native"
  exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "native android bridge source not found: $SRC_DIR"
  exit 1
fi

MAIN_APP_PATH="$(find "$ANDROID_DIR/app/src/main/java" -name 'MainApplication.*' | head -n 1 || true)"
if [ -z "$MAIN_APP_PATH" ]; then
  echo "MainApplication.* not found under $ANDROID_DIR/app/src/main/java"
  exit 1
fi

APP_PACKAGE="$(sed -n 's/^package[[:space:]]\+\([^;[:space:]]\+\).*/\1/p' "$MAIN_APP_PATH" | head -n 1)"
if [ -z "$APP_PACKAGE" ]; then
  echo "Could not detect package from: $MAIN_APP_PATH"
  exit 1
fi

APP_SRC_DIR="$(dirname "$MAIN_APP_PATH")"

copy_with_package() {
  local src="$1"
  local dest="$2"
  sed "s|__APP_PACKAGE__|$APP_PACKAGE|g" "$src" > "$dest"
  echo "Copied $(basename "$src") -> $dest"
}

copy_with_package "$SRC_DIR/LocationForegroundService.kt" "$APP_SRC_DIR/LocationForegroundService.kt"
copy_with_package "$SRC_DIR/RNAndroidLocationBridge.kt" "$APP_SRC_DIR/RNAndroidLocationBridge.kt"

echo ""
echo "Detected app package: $APP_PACKAGE"
echo "App source directory: $APP_SRC_DIR"

echo ""
echo "Manifest checklist ($MANIFEST_PATH):"
if [ -f "$MANIFEST_PATH" ]; then
  for pattern in \
    'android.permission.ACCESS_FINE_LOCATION' \
    'android.permission.ACCESS_BACKGROUND_LOCATION' \
    'android.permission.FOREGROUND_SERVICE' \
    'android.permission.FOREGROUND_SERVICE_LOCATION' \
    'android.permission.POST_NOTIFICATIONS' \
    'android:name=".LocationForegroundService"' \
    'android:foregroundServiceType="location"'
  do
    if grep -q "$pattern" "$MANIFEST_PATH"; then
      echo "  [ok] $pattern"
    else
      echo "  [missing] $pattern"
    fi
  done
else
  echo "  [missing] AndroidManifest.xml"
fi

echo ""
echo "ACTION REQUIRED in Android project:"
echo "  1) Merge permission/service blocks from mobile/scripts/android-manifest-fgs-scaffold.xml"
echo "  2) Register RNAndroidLocationBridge in a ReactPackage and add it to MainApplication#getPackages()"
echo "  3) Build and run on emulator/device, then verify events: locationUpdate/locationError"
