#!/usr/bin/env python3
"""Control-flow regression for profile import, including unavailable storage and BLE result propagation. Native hosted tests separately exercise real AdapterProfile validation."""
from pathlib import Path
import subprocess, sys, hashlib, tempfile
path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'mobile-ios/App/TelemetryModel.swift'
source = path.read_text(encoding='utf-8')
def method(name):
    marker = '    func '+name+'('
    if source.count(marker) != 1:
        raise ValueError('Expected exactly one production method: '+name)
    start = source.index(marker)
    body = source.index('{', start)
    depth=1
    i=body+1
    while depth:
        depth += (source[i]=='{')-(source[i]=='}')
        i+=1
    prefix = '    @discardableResult\n' if source[:start].endswith('    @discardableResult\n') else ''
    return prefix + source[start:i]
methods = '\n'.join(method(n) for n in ['importAdapterProfile','createSantaFeDiagnosticProfile'])
pre = r'''
import Foundation
struct Signal: Codable, Equatable { let id: String; let timeout: Double }
struct Query: Codable, Equatable { let signals: [Signal] }
struct AdapterProfile: Codable, Equatable { let name: String; let signals: [Signal]; let diagnosticQueries: [Query] }
enum BLEObservedProfileError: Error { case serviceCountIsAmbiguous, writeCharacteristicIsAmbiguous, notifyCharacteristicIsAmbiguous }
enum SantaFeMX5HybridQueryCatalog { static func initialQueries() throws -> [Query] { [] } }
struct Discovery {
    var profile: AdapterProfile
    func makeDiagnosticProfile(for: UUID, queries: [Query]) throws -> AdapterProfile { profile }
}
final class Model {
    var adapterProfile: AdapterProfile?
    var adapterProfileURL: URL?
    var adapterProfileStatus = ""
    var bleDiscoveryStatus = ""
    var localSignalTimeouts: [String: Double] = [:]
    var calls = 0
    var bleDiscovery: Discovery
    init(_ url: URL?, _ profile: AdapterProfile) { adapterProfileURL=url; bleDiscovery=Discovery(profile: profile) }
    func configureLocalSignalTimeouts(_ signals: [Signal]) { calls += 1; localSignalTimeouts=Dictionary(uniqueKeysWithValues: signals.map{($0.id,$0.timeout)}) }
    func configureDiagnosticSignalTimeouts(_ queries: [Query]) { calls += 1; for signal in queries.flatMap(\.signals) { localSignalTimeouts[signal.id]=signal.timeout } }
'''
post = r'''
}
var failures=0; var count=0
func check(_ condition: Bool, _ label: String) { count+=1; print("\(condition ? "PASS" : "FAIL"): \(label)"); if !condition { failures+=1 } }
let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url=root.appendingPathComponent("profile.json")
let old=AdapterProfile(name:"old",signals:[Signal(id:"old",timeout:1)], diagnosticQueries:[])
let next=AdapterProfile(name:"new",signals:[Signal(id:"new",timeout:9)], diagnosticQueries:[])
let oldData=try JSONEncoder().encode(old); let newData=try JSONEncoder().encode(next)
let model=Model(url,next)
model.importAdapterProfile(oldData)
model.importAdapterProfile(Data("{invalid".utf8))
check(model.adapterProfile==old, "invalid JSON preserves previous profile")
check(model.localSignalTimeouts==["old":1], "invalid JSON preserves previous timeouts")
check(try Data(contentsOf:url)==oldData, "invalid JSON preserves disk bytes")
model.importAdapterProfile(oldData)
let countBefore=model.calls
let backup=root.appendingPathComponent("backup")
try FileManager.default.moveItem(at:url,to:backup)
try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
model.importAdapterProfile(newData)
check(model.adapterProfile==old, "save failure preserves previous profile")
check(model.localSignalTimeouts==["old":1], "save failure does not publish replacement timeouts")
check(model.calls==countBefore, "save failure does not schedule new configuration")
check(try Data(contentsOf:backup)==oldData, "failed replacement preserves original saved bytes")
model.createSantaFeDiagnosticProfile(from:UUID())
check(!model.bleDiscoveryStatus.hasPrefix("Observed GATT profile converted"), "BLE caller does not report failed persistence as success")
try FileManager.default.removeItem(at:url); try FileManager.default.moveItem(at:backup,to:url)
model.importAdapterProfile(newData)
check(model.adapterProfile==next && model.localSignalTimeouts==["new":9], "successful replacement publishes profile and timeouts")
check(try Data(contentsOf:url)==newData, "successful replacement persists bytes")
model.adapterProfileURL=nil
model.importAdapterProfile(oldData)
check(model.adapterProfile==next && model.localSignalTimeouts==["new":9], "missing destination preserves profile and timeouts")
check(!model.adapterProfileStatus.hasPrefix("Profile loaded:"), "missing destination cannot report saved success")
print("PROFILE CONTROL-FLOW PROBE: \(count) assertions, \(failures) failures; profile/GATT substitutes, real Foundation file I/O")
exit(failures==0 ? 0:1)
'''
code = pre + methods + post
print('Source SHA256:',hashlib.sha256(source.encode()).hexdigest(),flush=True)
print('Actual import/caller methods; profile and GATT are substitutes, Foundation file I/O is real.',flush=True)
with tempfile.TemporaryDirectory(prefix='profile-import-probe-') as directory:
    out=Path(directory)/'probe.swift'
    binary=Path(directory)/'probe'
    out.write_text(code, encoding='utf-8')
    subprocess.run(['swiftc','-swift-version','5',str(out),'-o',str(binary)],check=True,timeout=120)
    sys.exit(subprocess.run([str(binary)],timeout=30).returncode)
