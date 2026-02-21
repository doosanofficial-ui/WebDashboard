#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");

const requiredFiles = [
  "package.json",
  "app.json",
  "index.js",
  "src/App.js",
  "src/config.js",
  "src/telemetry/protocol.js",
  "src/telemetry/ws-client.js",
  "src/telemetry/gps-client.js",
  "src/telemetry/store-forward-queue.js",
  "scripts/init-native-project.sh",
  "scripts/apply-ios-location-background.sh",
  "scripts/apply-android-location-background.sh",
  "native-ios-bridge/RNIosLocationBridge.h",
  "native-ios-bridge/RNIosLocationBridge.m",
  "native-android-bridge/LocationForegroundService.kt",
  "native-android-bridge/RNAndroidLocationBridge.kt",
  "README.md",
];

const missing = requiredFiles.filter((relativePath) => !fs.existsSync(path.join(root, relativePath)));

if (missing.length > 0) {
  console.error("Mobile scaffold validation failed:");
  missing.forEach((file) => console.error(`- missing: ${file}`));
  process.exit(1);
}

console.log("Mobile scaffold validation passed.");
