import Foundation

#if EXPORT_DISMISSAL_AUDIT_FIXTURE && DEBUG && targetEnvironment(simulator)
import Darwin

/// Opt-in, synthetic-fixture diagnostics. No payload, session, URL or error text.
final class ExportDismissalAudit {
    struct Admission: Codable {
        let scope: String
        let runID: UUID
        let commit: String
    }
    struct Row: Codable {
        let runID: UUID
        let ownerID: UUID
        let requestID: UUID?
        let callbackID: UUID?
        let event: String
        let format: String?
        let presented: Bool
        let previousPresented: Bool?
        let completionAccepted: Bool?
        let uptime: Double
        let epoch: Double
        var sequence = 0
    }
    static func admission(arguments: [String], marker: Data?) -> Admission? {
        guard arguments.contains("--audit-export-dismissal"), let marker, marker.count <= 1024,
              let value = try? JSONDecoder().decode(Admission.self, from: marker),
              value.scope == "qualified-synthetic-fixture", value.commit.count == 40,
              value.commit.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    static let active: ExportDismissalAudit? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--audit-export-dismissal"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = support.appendingPathComponent("ExportDismissalAudit", isDirectory: true)
        let markerURL = directory.appendingPathComponent("admission.json")
        guard let values = try? markerURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink == false, let size = values.fileSize, size <= 1024,
              let marker = try? Data(contentsOf: markerURL),
              let admission = admission(arguments: arguments, marker: marker) else { return nil }
        return ExportDismissalAudit(admission: admission, file: directory.appendingPathComponent("export-dismissal-audit.jsonl"))
    }()
    let runID: UUID
    private let file: URL
    private let queue = DispatchQueue(label: "synthetic-export-audit", qos: .utility)
    private var count = 0
    private var failed = false
    init(admission: Admission, file: URL) { runID = admission.runID; self.file = file }
    func flushForTesting() { queue.sync {} }
    func append(_ row: Row) {
        // Capture clocks/state on the caller; encoding and append never block its actor.
        queue.async { [self] in
            guard count < 128, !failed else { return }
            count += 1
            var row = row; row.sequence = count
            guard var data = try? JSONEncoder().encode(row) else { failed = true; return }
            data.append(0x0A)
            let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { failed = true; return }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size + Int64(data.count) <= 65536 else { failed = true; return }
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written != data.count { failed = true }
        }
    }
}
#endif
