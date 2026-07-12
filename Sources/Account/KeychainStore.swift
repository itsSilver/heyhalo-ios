// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

/// Tiny Keychain wrapper for the one secret the phone holds: the Halo Cloud
/// session token (used to prove the account is active before Reach unlocks).
/// Mirrors the Mac's `KeychainStore` (same service id + `genericPassword` shape)
/// so the two stay conceptually aligned.
///
/// Keychain, not UserDefaults: UserDefaults serialises to a readable plist;
/// Keychain is encrypted at rest and access-gated by the system. Auth tokens
/// belong here.
enum KeychainStore {

    private static let service = "com.silvercommerce.halo"

    /// The one account key the phone uses — the Halo Cloud session token.
    /// Same name the Mac uses for its credential.
    static let sessionTokenAccount = "halo.cloud.sessionToken"

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
            let data = item as? Data,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Insert or replace. Empty string deletes the entry.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if value.isEmpty {
            delete(account: account)
            return true
        }
        guard let data = value.data(using: .utf8) else { return false }
        let baseQ = baseQuery(account: account)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQ as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }
        var addQuery = baseQ
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary) == errSecSuccess
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
