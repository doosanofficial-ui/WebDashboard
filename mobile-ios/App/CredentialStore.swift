import Foundation
import Security

enum CredentialStore {
    private static let service = "local.webdashboard.telemetry"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "ingest",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "ingest"]
        let changes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw TelemetrySetupError.credentialStorage
            }
        } else if status != errSecSuccess { throw TelemetrySetupError.credentialStorage }
    }
}

enum TelemetrySetupError: Error { case credentialStorage, invalidEndpoint }
