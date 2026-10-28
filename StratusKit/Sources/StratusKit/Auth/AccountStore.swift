import Foundation
import Security

/// The signed-in account (including tokens) as one generic-password Keychain item, shared by the
/// app and the File Provider extension through the keychain access group.
public struct AccountStore: Sendable {
    let service: String
    let accessGroup: String?
    let useDataProtectionKeychain: Bool

    public init(service: String = "com.arteq.stratus", accessGroup: String?) {
        self.init(service: service, accessGroup: accessGroup, useDataProtectionKeychain: true)
    }

    /// Unit tests without keychain entitlements fall back to the file-based keychain.
    init(service: String, accessGroup: String?, useDataProtectionKeychain: Bool) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private var identity: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() throws -> Account? {
        var q = identity
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AuthError.keychain(status) }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// Readable after the first unlock (the extension runs in the background), never migrated to
    /// another Mac via backups. Written on add and on update, so older items are tightened too.
    static func writeAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    public func save(_ account: Account) throws {
        let attributes = Self.writeAttributes(try JSONEncoder().encode(account))
        var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.keychain(status) }
    }
}
