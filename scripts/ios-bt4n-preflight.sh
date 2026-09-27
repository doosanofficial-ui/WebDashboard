#!/usr/bin/env bash
set -u

pass=0
blocked=0

report() {
  local name="$1" result="$2" detail="$3"
  printf '%s\t%s\t%s\n' "$name" "$result" "$detail"
  if [[ "$result" == "PASS" ]]; then
    pass=$((pass + 1))
  elif [[ "$result" == "BLOCKED" ]]; then
    blocked=$((blocked + 1))
  fi
}

if command -v xcodebuild >/dev/null 2>&1; then
  xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
  if xcodebuild -showsdks 2>/dev/null | grep -q 'iphoneos27'; then
    report "XCODE_IOS27_SDK" "PASS" "$xcode_version"
  else
    report "XCODE_IOS27_SDK" "BLOCKED" "$xcode_version; iphoneos27 SDK not installed"
  fi
else
  report "XCODE_IOS27_SDK" "BLOCKED" "xcodebuild not found"
fi

device_output=""
if command -v xcrun >/dev/null 2>&1; then
  device_output="$(xcrun devicectl list devices 2>&1 || true)"
fi
if printf '%s\n' "$device_output" | grep -Eq 'iPhone .*available .*iPhone 17 \('; then
  report "IPHONE17_CONNECTED" "PASS" "physical device listed by devicectl"
else
  report "IPHONE17_CONNECTED" "BLOCKED" "no physical iPhone 17 in devicectl inventory"
fi

if find docs mobile-ios -type f \( -name '*.elm-capture' -o -name '*bt4n*capture*' \) -print -quit 2>/dev/null | grep -q .; then
  report "BT4N_CAPTURE" "PASS" "capture fixture found"
else
  report "BT4N_CAPTURE" "NOT TESTED" "no physical BT4N capture fixture"
fi

if (( blocked > 0 )); then
  printf 'P0_E2E\tBLOCKED\tsoftware preflight cannot replace physical hardware evidence\n'
else
  printf 'P0_E2E\tNOT TESTED\tconnect BT4N, observe GATT, capture raw CAN, and run vehicle trial\n'
fi
printf 'SUMMARY\tPASS=%d BLOCKED=%d\n' "$pass" "$blocked"
