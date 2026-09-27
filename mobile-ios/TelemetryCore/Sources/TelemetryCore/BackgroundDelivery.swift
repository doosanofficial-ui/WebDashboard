import Foundation

@MainActor
public protocol BackgroundTransferScheduling: AnyObject {
    func hasActiveTransfer(excluding filename: String?) async -> Bool
    func registerUpload(_ request: URLRequest, from file: URL, earliestBeginDate: Date?) throws
}

@MainActor
public final class BackgroundDelivery {
    private let outbox: DurableOutbox
    private let clientID: String
    private let directory: URL
    private weak var scheduler: (any BackgroundTransferScheduling)?
    private var configuration: (URL, String)?
    private var configurationRevision = UUID()
    private var preparation: Task<Void, Never>?
    private var paused = false
    private var backoff = 1
    private var nextAttemptAt: Date?
    public var onStatus: ((String) -> Void)?

    public init(outbox: DurableOutbox, clientID: String, directory: URL,
                scheduler: any BackgroundTransferScheduling) throws {
        self.outbox = outbox; self.clientID = clientID; self.directory = directory
        self.scheduler = scheduler
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func configure(baseURL: URL, credential: String, force: Bool = false) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil, ["", "/"].contains(baseURL.path),
              !credential.isEmpty, credential.utf8.count <= 512,
              credential.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw TelemetryError.invalidBatch
        }
        if force || configuration?.0 != baseURL || configuration?.1 != credential {
            paused = false; backoff = 1; nextAttemptAt = nil
            configurationRevision = UUID()
        }
        configuration = (baseURL, credential)
    }

    public func flush() async { await scheduleNext(earliest: nil, excluding: nil) }

    private func scheduleNext(earliest: Date?, excluding: String?) async {
        if let active = preparation {
            await active.value
            await scheduleNext(earliest: earliest, excluding: excluding)
            return
        }
        guard !paused else { return }
        let task = Task {
            await prepareUpload(earliest: earliest, excluding: excluding)
            preparation = nil
        }
        preparation = task
        await task.value
    }

    private func prepareUpload(earliest: Date?, excluding: String?) async {
        guard !paused, let scheduler, let (baseURL, credential) = configuration else { return }
        let revision = configurationRevision
        guard !(await scheduler.hasActiveTransfer(excluding: excluding)) else { return }
        var bodyFile: URL?
        do {
            let events = try await outbox.pending()
            guard !paused, revision == configurationRevision else { return }
            guard !events.isEmpty else { onStatus?("All records acknowledged"); return }
            let batch = try UploadBatch(clientID: clientID, events: events)
            let body = try JSONEncoder().encode(batch)
            guard body.count <= 256 * 1024 else { throw TelemetryError.invalidBatch }
            let file = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
            bodyFile = file
            try body.write(to: file, options: .atomic)
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v2/ingest"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            let scheduledDate = [earliest, nextAttemptAt].compactMap { $0 }.max()
            try scheduler.registerUpload(request, from: file, earliestBeginDate: scheduledDate)
            if scheduledDate == nil { onStatus?("Uploading \(events.count) stored records") }
        } catch {
            if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) }
            onStatus?("Upload preparation failed; records retained")
        }
    }

    public func complete(filename: String, status: Int, body: Data) async {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".json") else { return }
        let file = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: file) }
        switch IngestHTTPReply.decode(status: status, body: body) {
        case .acknowledged(let ack):
            do {
                let batch = try JSONDecoder().decode(UploadBatch.self, from: Data(contentsOf: file))
                try await outbox.acknowledge(ack, for: batch)
                backoff = 1; nextAttemptAt = nil
                onStatus?("Server acknowledged \(ack.acked.count) records")
                await scheduleNext(earliest: nil, excluding: filename)
            } catch {
                paused = true
                onStatus?("Acknowledgement invalid; records retained")
            }
        case .failure(let code, let message, let retryable):
            paused = !retryable
            onStatus?("\(message) (\(code))")
            if retryable {
                let earliest = Date().addingTimeInterval(TimeInterval(backoff))
                nextAttemptAt = earliest
                backoff = min(60, backoff * 2)
                // Register with the OS before the app releases its background completion.
                await scheduleNext(earliest: earliest, excluding: filename)
            }
        }
    }
}
