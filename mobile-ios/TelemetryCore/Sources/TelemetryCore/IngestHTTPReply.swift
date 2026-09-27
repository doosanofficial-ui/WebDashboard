import Foundation

public enum IngestHTTPReply: Sendable {
    case acknowledged(Acknowledgement)
    case failure(code: String, message: String, retryable: Bool)

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    public static func decode(status: Int, body: Data) -> Self {
        if status == 200, let ack = try? JSONDecoder().decode(Acknowledgement.self, from: body),
           ack.version == 2, !ack.acked.isEmpty, ack.acked.count <= 200 {
            return .acknowledged(ack)
        }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.code
        // Preserve known error codes without reflecting arbitrary server text or secrets.
        switch (status, code) {
        case (401, "unauthorized"):
            return .failure(code: "unauthorized", message: "Pairing credential rejected; records retained", retryable: false)
        case (503, "ingest_unconfigured"):
            return .failure(code: "ingest_unconfigured", message: "Server ingestion is not configured; records retained", retryable: false)
        case (422, "invalid_batch"):
            return .failure(code: "invalid_batch", message: "Batch rejected; records retained for diagnosis", retryable: false)
        case (409, "event_conflict"):
            return .failure(code: "event_conflict", message: "Event identity conflict; records retained", retryable: false)
        case (503, "storage_unavailable"):
            return .failure(code: "storage_unavailable", message: "Server storage unavailable; retry scheduled", retryable: true)
        case (426, "https_required"):
            return .failure(code: "https_required", message: "Server requires HTTPS; records retained", retryable: false)
        case (413, "body_too_large"):
            return .failure(code: "body_too_large", message: "Batch exceeds server limit; records retained", retryable: false)
        case (400, "invalid_json"):
            return .failure(code: "invalid_json", message: "Server rejected JSON; records retained", retryable: false)
        case (429, _):
            return .failure(code: "rate_limited", message: "Server rate limit reached; retry scheduled", retryable: true)
        case (0, _), (500...599, _):
            return .failure(code: "transport_unavailable", message: "Upload unavailable; retry scheduled", retryable: true)
        default:
            return .failure(code: "invalid_response", message: "Invalid server response; records retained", retryable: true)
        }
    }
}
