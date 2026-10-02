#!/usr/bin/env python3
"""Run the production GATT selection method against observed and ambiguous layouts."""
import hashlib
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "mobile-ios/App/BLEDiscoveryController.swift").read_text()
start = source.index("    func makeDiagnosticProfile(")
end = source.index("\n    func centralManagerDidUpdateState", start)
method = source[start:end].replace("return try AdapterProfile(", "return AdapterProfile(")
prefix = r'''
import Foundation
struct Characteristic { let id: String; let properties: [String] }
struct Service { let id: String; let characteristics: [Characteristic] }
struct Device { let id: UUID; let name: String; let services: [Service] }
struct OBDQueryDefinition {}
enum BLEObservedProfileError: Error { case deviceNotFound, serviceCountIsAmbiguous, writeCharacteristicIsAmbiguous, notifyCharacteristicIsAmbiguous }
enum Transport { case ble }
struct AdapterProfile {
    let id: String; let name: String; let transport: Transport; let peripheralID: UUID?
    let serviceUUID: String?; let writeCharacteristicUUID: String?; let notifyCharacteristicUUID: String?
    let host: String?; let port: Int?; let signals: [String]; let diagnosticQueries: [OBDQueryDefinition]
}
struct Probe {
    let devices: [UUID: Device]
'''
suffix = r'''
}
var count = 0; var failures = 0
func check(_ good: Bool, _ name: String) {
    count += 1; if !good { failures += 1 }
    print("\(good ? "PASS" : "FAIL"): \(name)")
}
let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
func service(_ name: String, _ write: String, _ notify: String) -> Service {
    Service(id: name, characteristics: [Characteristic(id: write, properties: ["write", "write_without_response"]), Characteristic(id: notify, properties: ["read", "notify"])])
}
// Captured from physical OBDII on 2026-10-02, not a guessed transport profile.
let ancillary = [
    Service(id: "1804", characteristics: [Characteristic(id: "2A07", properties: ["read", "write_without_response"])]),
    Service(id: "180F", characteristics: [Characteristic(id: "2A19", properties: ["read", "notify"])])
]
let uart = service("FFF0", "FFF2", "FFF1")
func select(_ services: [Service]) throws -> AdapterProfile {
    try Probe(devices: [id: Device(id: id, name: "observed OBDII", services: services)]).makeDiagnosticProfile(for: id, queries: [])
}
do {
    let profile = try select(ancillary + [uart])
    check(profile.serviceUUID == "FFF0" && profile.writeCharacteristicUUID == "FFF2" && profile.notifyCharacteristicUUID == "FFF1", "captured three-service layout selects its unique duplex service")
} catch { check(false, "captured three-service layout rejected: \(error)") }
do { _ = try select([uart]); check(true, "existing single-service layout retained") }
catch { check(false, "existing single-service rejected") }
do { _ = try select([uart, service("ABCD", "ABCE", "ABCF")]); check(false, "multiple duplex services must fail closed") }
catch { check(true, "multiple duplex services fail closed") }
do { _ = try select(ancillary); check(false, "separate write and notify services must not be combined") }
catch { check(true, "separate ancillary services are not combined") }
do { _ = try select([Service(id: "FFF0", characteristics: [Characteristic(id: "FFF1", properties: ["write", "notify"])])]); check(false, "same characteristic must remain rejected") }
catch { check(true, "same characteristic remains rejected") }
do { _ = try select([Service(id: "FFF0", characteristics: [Characteristic(id: "FFF1", properties: ["notify"]), Characteristic(id: "FFF2", properties: ["write"]), Characteristic(id: "FFF3", properties: ["write"])])]); check(false, "ambiguous write characteristics must be rejected") }
catch { check(true, "ambiguous write characteristics rejected") }
print("GATT SELECTION SOURCE PROBE: \(count) assertions, \(failures) failures; no Bluetooth runtime")
exit(failures == 0 ? 0 : 1)
'''
print("BLEDiscoveryController source SHA256:", hashlib.sha256(source.encode()).hexdigest(), flush=True)
with tempfile.TemporaryDirectory(prefix="gatt-profile-probe-") as directory:
    swift = Path(directory) / "probe.swift"
    binary = Path(directory) / "probe"
    swift.write_text(prefix + method + suffix)
    subprocess.run(["swiftc", "-swift-version", "5", str(swift), "-o", str(binary)], check=True, timeout=120)
    raise SystemExit(subprocess.run([str(binary)], timeout=30).returncode)
