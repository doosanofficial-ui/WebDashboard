import Foundation
import TelemetryCore

@MainActor
final class BackgroundUploader: NSObject, @preconcurrency URLSessionDataDelegate, BackgroundTransferScheduling {
    static let identifier = "local.webdashboard.telemetry.upload"
    private var delivery: BackgroundDelivery!
    private var responseBodies: [Int: Data] = [:]
    private var pendingCompletions = 0
    private var finishedEvents = false
    var onStatus: ((String) -> Void)?
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 300
        // The delegate's actor isolation requires callbacks on the main queue.
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(outbox: DurableOutbox, clientID: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        super.init()
        delivery = try BackgroundDelivery(outbox: outbox, clientID: clientID, directory: directory, scheduler: self)
        delivery.onStatus = { [weak self] message in self?.onStatus?(message) }
    }

    func restoreSession(baseURL: URL?, credential: String?) {
        if let baseURL, let credential {
            do { try delivery.configure(baseURL: baseURL, credential: credential) }
            catch { onStatus?("Saved server or credential is invalid") }
        }
        _ = session
        Task { await delivery.flush() }
    }

    func flush(to baseURL: URL, credential: String, force: Bool = false) async {
        do {
            try delivery.configure(baseURL: baseURL, credential: credential, force: force)
            await delivery.flush()
        } catch { onStatus?("Valid HTTPS server and pairing credential required") }
    }

    func hasActiveTransfer(excluding filename: String?) async -> Bool {
        await session.allTasks.contains { task in
            task.state != .completed && (filename == nil || task.taskDescription != filename)
        }
    }

    func registerUpload(_ request: URLRequest, from file: URL, earliestBeginDate: Date?) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = file.lastPathComponent
        task.earliestBeginDate = earliestBeginDate
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let existing = responseBodies[dataTask.taskIdentifier] ?? Data()
        guard existing.count + data.count <= 64 * 1024 else { dataTask.cancel(); return }
        responseBodies[dataTask.taskIdentifier] = existing + data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let filename = task.taskDescription else { return }
        let status = error == nil ? (task.response as? HTTPURLResponse)?.statusCode ?? 0 : 0
        pendingCompletions += 1
        Task {
            await delivery.complete(filename: filename, status: status, body: response)
            pendingCompletions -= 1
            finishBackgroundEventsIfReady()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishedEvents = true
        finishBackgroundEventsIfReady()
    }

    private func finishBackgroundEventsIfReady() {
        guard finishedEvents, pendingCompletions == 0, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil; finishedEvents = false
        completion()
    }
}
