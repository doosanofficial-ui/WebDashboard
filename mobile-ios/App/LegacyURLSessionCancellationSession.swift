@preconcurrency import Foundation

/// Passive attachment for cancellation only. Never creates/resumes an upload,
/// opens a body file, configures delivery, acknowledges data, or retries.
final class LegacyURLSessionCancellationSession: NSObject, LegacyBackgroundCancellationSession,
                                                URLSessionTaskDelegate, @unchecked Sendable {
    private let identifier: String
    // The coordinator invokes enumeration once per launch, so lazy attachment
    // has one caller. URLSession/task cancellation itself is thread-safe.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    func allTasks(_ completion: @escaping ([LegacyBackgroundCancellationTask]) -> Void) {
        session.getAllTasks { tasks in
            completion(tasks.map { LegacyURLSessionTask($0) })
        }
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class LegacyURLSessionTask: LegacyBackgroundCancellationTask {
    private let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }
    func cancel() { task.cancel() }
}
