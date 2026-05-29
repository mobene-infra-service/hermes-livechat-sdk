import Foundation
import Security

// `appKey` pins which app this session was issued under and never changes for
// a given persisted record. The remaining fields are mutated through the
// facade (token renewal, conversation memory) so they are `var` — this keeps
// the call sites to a one-line mutation instead of rebuilding the whole
// struct.
internal struct StoredSession: Codable {
    let appKey: String
    var visitorId: String
    var contactId: Int
    var token: String
    var tokenExp: Int
    var realtimeUrl: URL?
    var lastConversationId: String?
    // identityKey pins the cached session to the customerId it was issued
    // under. When the caller hands startSession() a different customerId we
    // must discard the cache and re-init so the backend sees the new visitor.
    // Optional for backward compatibility with sessions persisted by older
    // SDK builds; a nil here is treated as "unknown" and invalidates on any
    // non-empty incoming key.
    var identityKey: String?

    func toVisitorSession(defaultRealtimeUrl: URL) -> VisitorSession {
        VisitorSession(
            visitorId: visitorId,
            contactId: contactId,
            tokenExp: tokenExp,
            realtimeUrl: realtimeUrl ?? defaultRealtimeUrl
        )
    }
}

internal final class SessionStore {
    private let service = "com.mobene.hermes.livechat.session"

    func load(appKey: String) -> StoredSession? {
        if let data = KeychainStore.read(service: service, account: appKey) {
            return try? JSONDecoder().decode(StoredSession.self, from: data)
        }
        let legacyKey = userDefaultsKey(appKey)
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let session = try? JSONDecoder().decode(StoredSession.self, from: data)
        else { return nil }
        save(session)
        return session
    }

    func save(_ session: StoredSession) {
        if let data = try? JSONEncoder().encode(session) {
            if KeychainStore.write(data, service: service, account: session.appKey) {
                UserDefaults.standard.removeObject(forKey: userDefaultsKey(session.appKey))
            }
        }
    }

    private func userDefaultsKey(_ appKey: String) -> String {
        "hermes.livechat.session.\(appKey)"
    }
}

private enum KeychainStore {
    static func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(_ data: Data, service: String, account: String) -> Bool {
        let status = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }

        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
