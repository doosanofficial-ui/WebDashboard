"""Apply opt-in audit hooks only to isolated fixture source copies."""
import hashlib
from pathlib import Path

SWIFT_CONDITION = "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG EXPORT_DISMISSAL_AUDIT_FIXTURE"

def instrument_export_sources(root, destination):
    evidence = {"scope": "isolated DEBUG Simulator fixture source transform; production App sources unchanged", "swiftCondition": SWIFT_CONDITION, "inputs": {}}
    def replace(path, old, new):
        file = destination / path
        source = file.read_text()
        if source.count(old) != 1: raise ValueError("Export audit source boundary changed: " + path)
        evidence["inputs"].setdefault(path, {"sourceSHA256": hashlib.sha256(file.read_bytes()).hexdigest()})
        file.write_text(source.replace(old, new, 1))
        evidence["inputs"][path]["stagedSHA256"] = hashlib.sha256(file.read_bytes()).hexdigest()
    request = 'App/MeasurementExportRequest.swift'
    replace(request, '    var presented = false\n', '''    enum AuditEvent: String { case begin, accept, presented, finish, cancel, completion, onChange, appear, disappear }
        #if EXPORT_DISMISSAL_AUDIT_FIXTURE && DEBUG && targetEnvironment(simulator)
        @ObservationIgnored private let audit: ExportDismissalAudit?
        @ObservationIgnored private let auditOwnerID = UUID()
        init(audit: ExportDismissalAudit? = .active) { self.audit = audit }
        #else
        init() {}
        #endif
        func recordAudit(_ event: AuditEvent, callbackID: UUID? = nil,
                         previousPresented: Bool? = nil, completionAccepted: Bool? = nil) {
            #if EXPORT_DISMISSAL_AUDIT_FIXTURE && DEBUG && targetEnvironment(simulator)
            guard let audit else { return }
            audit.append(.init(runID: audit.runID, ownerID: auditOwnerID, requestID: request?.id,
                callbackID: callbackID, event: event.rawValue, format: request.map { $0.format == .csv ? "csv" : "json" },
                presented: presented, previousPresented: previousPresented, completionAccepted: completionAccepted,
                uptime: ProcessInfo.processInfo.systemUptime, epoch: Date().timeIntervalSince1970))
            #endif
        }
        var presented = false {
            didSet { recordAudit(.presented, previousPresented: oldValue) }
        }
    ''')
    replace(request, '        self.request = request\n', '        self.request = request\n        recordAudit(.begin)\n')
    replace(request, '        presented = true\n', '        recordAudit(.accept, callbackID: request.id)\n        presented = true\n')
    replace(request, '    func finish(requestID: UUID) {\n', '    func finish(requestID: UUID) {\n        recordAudit(.finish, callbackID: requestID)\n')
    replace(request, '    func cancel() {\n', '    func cancel() {\n        recordAudit(.cancel)\n')

    view = 'App/SessionsView.swift'
    replace(view, '            ) { result in\n', '''            ) { result in
                    exportRequest.recordAudit(.completion, callbackID: request?.id,
                        completionAccepted: request.map { exportRequest.acceptsCompletion(requestID: $0.id) })
    ''')
    replace(view, '            .onChange(of: exportRequest.presented) { old, new in\n', '''            .onChange(of: exportRequest.presented) { old, new in
                    exportRequest.recordAudit(.onChange, previousPresented: old)
    ''')
    replace(view, '            .onDisappear { exportRequest.cancel() }', '''            .onAppear { exportRequest.recordAudit(.appear) }
                .onDisappear { exportRequest.recordAudit(.disappear); exportRequest.cancel() }''')

    asset = root / "mobile-ios/Diagnostics/ExportDismissalAudit.swift"
    target = destination / "App/ExportDismissalAudit.swift"
    if target.exists(): raise ValueError("Unexpected preexisting export audit helper")
    target.write_bytes(asset.read_bytes())
    evidence["inputs"]["App/ExportDismissalAudit.swift"] = {"sourcePath": "mobile-ios/Diagnostics/ExportDismissalAudit.swift", "stagedSHA256": hashlib.sha256(target.read_bytes()).hexdigest()}
    return evidence
