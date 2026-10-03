import Foundation
import Security

/// Serializes same-process Keychain transactions, including multiple InboxClient instances.
struct KeychainStorage: Sendable {
    let service: String
    private static let lock = NSLock()
    var clientStorage: ClientStorage {
        ClientStorage(credential: { try self.credential() }, pending: { try self.locked { try self.readPending() } },
            admit: { candidate, context in try self.locked {
                if let existing = try self.readPending() {
                    guard existing.matchesForRetry(candidate) else { throw InboxClient.Failure.pendingSendConflict }
                    return existing
                }
                var submission = candidate
                if submission.clientContext == nil { submission.clientContext = context }
                let status = self.add(try JSONEncoder().encode(submission), account: "pending-send")
                if status == errSecDuplicateItem {
                    guard let existing = try self.readPending(), existing.matchesForRetry(candidate) else { throw InboxClient.Failure.pendingSendConflict }
                    return existing
                }
                guard status == errSecSuccess else { throw InboxClient.Failure.storage(status: status) }
                return submission
            } }, clear: { candidate in try self.locked {
                // A late receipt must never clear another newly admitted send.
                guard let current = try self.readPending() else { return }
                guard current == candidate else { return }
                let status = SecItemDelete(self.query("pending-send") as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw InboxClient.Failure.storage(status: status) }
            } })
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }; return try work()
    }
    private func credential() throws -> Credential {
        try locked {
            if let existing: Credential = try read("installation") { try validate(existing); return existing }
            var bytes = [UInt8](repeating: 0, count: 32)
            let random = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard random == errSecSuccess else { throw InboxClient.Failure.storage(status: random) }
            let candidate = Credential(id: UUID(), secret: bytes.map { String(format: "%02x", $0) }.joined())
            let status = add(try JSONEncoder().encode(candidate), account: "installation")
            if status == errSecDuplicateItem, let existing: Credential = try read("installation") { try validate(existing); return existing }
            guard status == errSecSuccess else { throw InboxClient.Failure.storage(status: status) }
            return candidate
        }
    }
    private func validate(_ credential: Credential) throws {
        guard credential.secret.count == 64, credential.secret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw InboxClient.Failure.invalidStoredState }
    }
    private func readPending() throws -> InboxClient.PendingSend? {
        let value: InboxClient.PendingSend? = try read("pending-send")
        if let value, !InboxClient.Policy.accepts(value.body) { throw InboxClient.Failure.invalidStoredState }
        return value
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
    }
    private func read<T: Decodable>(_ account: String) throws -> T? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw InboxClient.Failure.storage(status: status) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw InboxClient.Failure.invalidStoredState }
    }
    private func add(_ data: Data, account: String) -> OSStatus {
        var q = query(account); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }
}
