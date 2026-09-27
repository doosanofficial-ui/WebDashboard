#!/usr/bin/env bash
# Isolated qualification only. This never opens a Bluetooth/vehicle connection.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for tool in gh xcrun xcodebuild xcodegen; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done
ARTIFACT_DIR="$(mktemp -d /tmp/telemetry-obd-eval.XXXXXX)"
printf 'Evaluation artifacts: %s\n' "$ARTIFACT_DIR"
xcodebuild -version > "$ARTIFACT_DIR/toolchain.txt"
xcrun swift --version >> "$ARTIFACT_DIR/toolchain.txt" 2>&1
printf 'SwiftOBD2 fe6def4e8599671dfc1b9597dbcdbc6a7c078b96\nLTSupportAutomotive SPM 909c42a803e74d7e941add4ba31201948a117259\n' > "$ARTIFACT_DIR/versions.txt"
mkdir "$ARTIFACT_DIR/swiftobd2" "$ARTIFACT_DIR/lt-support"
gh api repos/kkonteh97/SwiftOBD2/tarball/fe6def4e8599671dfc1b9597dbcdbc6a7c078b96 > "$ARTIFACT_DIR/swiftobd2.tgz"
gh api repos/mickeyl/LTSupportAutomotive/tarball/909c42a803e74d7e941add4ba31201948a117259 > "$ARTIFACT_DIR/lt-support.tgz"
shasum -a 256 "$ARTIFACT_DIR/"*.tgz > "$ARTIFACT_DIR/archives-sha256.txt"
tar -xzf "$ARTIFACT_DIR/swiftobd2.tgz" --strip-components=1 -C "$ARTIFACT_DIR/swiftobd2"
tar -xzf "$ARTIFACT_DIR/lt-support.tgz" --strip-components=1 -C "$ARTIFACT_DIR/lt-support"

FAILED=0
run_phase() {
  local phase="$1"
  shift
  local result=0
  "$@" > "$ARTIFACT_DIR/$phase.log" 2>&1 || result=$?
  printf '%s\t%s\n' "$phase" "$result" | tee -a "$ARTIFACT_DIR/exit-codes.tsv"
  if [[ "$result" != 0 ]]; then FAILED=1; fi
}
run_phase swift-upstream-tests xcrun swift test --package-path "$ARTIFACT_DIR/swiftobd2"
run_phase lt-upstream-build xcrun swift build --package-path "$ARTIFACT_DIR/lt-support"

cp "$SCRIPT_DIR/SwiftOBD2AcceptanceTests.swift" "$ARTIFACT_DIR/swiftobd2/Tests/SwiftOBD2Tests/DashboardAcceptanceTests.swift"
mkdir -p "$ARTIFACT_DIR/lt-probe/Tests/AcceptanceTests"
cp "$SCRIPT_DIR/LTSupportAcceptanceTests.swift" "$ARTIFACT_DIR/lt-probe/Tests/AcceptanceTests/DashboardAcceptanceTests.swift"
cat > "$ARTIFACT_DIR/lt-probe/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LTQualification", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../lt-support")],
    targets: [.testTarget(name: "AcceptanceTests", dependencies: [
        .product(name: "LTSupportAutomotive", package: "lt-support")
    ])])
EOF
run_phase swift-acceptance xcrun swift test --package-path "$ARTIFACT_DIR/swiftobd2" --filter DashboardAcceptanceTests
run_phase lt-acceptance xcrun swift test --package-path "$ARTIFACT_DIR/lt-probe"

mkdir -p "$ARTIFACT_DIR/host/Sources"
cat > "$ARTIFACT_DIR/host/Sources/QualificationApp.swift" <<'EOF'
import SwiftUI
import SwiftOBD2
import LTSupportAutomotive
@main struct QualificationApp: App {
    var body: some Scene { WindowGroup { Text("Compile qualification only") } }
}
EOF
cat > "$ARTIFACT_DIR/host/project.yml" <<'EOF'
name: OBDQualification
options:
  deploymentTarget:
    iOS: '17.0'
packages:
  SwiftOBD2:
    path: ../swiftobd2
  LTSupportAutomotive:
    path: ../lt-support
targets:
  OBDQualification:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - package: SwiftOBD2
      - package: LTSupportAutomotive
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.webdashboard.OBDQualification
        GENERATE_INFOPLIST_FILE: YES
EOF
(cd "$ARTIFACT_DIR/host" && xcodegen generate) > "$ARTIFACT_DIR/host-generate.log" 2>&1
run_phase ios-simulator-compile xcodebuild -project "$ARTIFACT_DIR/host/OBDQualification.xcodeproj" \
  -scheme OBDQualification -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$ARTIFACT_DIR/host-build" CODE_SIGNING_ALLOWED=NO build
printf 'Qualification exit: %s. Read assertion errors, not just counts. Artifacts: %s\n' "$FAILED" "$ARTIFACT_DIR"
exit "$FAILED"
