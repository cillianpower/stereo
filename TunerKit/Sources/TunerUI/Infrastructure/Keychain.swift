import Foundation
import Security

/// Small Keychain wrapper. Items are iCloud-synchronizable when the app has the entitlement,
/// so every device signs in automatically; unsigned dev builds fall back to a local item.
enum Keychain {
    static let service = "app.tuner.credentials"

    static func set(_ value: String, for account: String) {
        delete(account)
        let data = Data(value.utf8)
        var query = baseQuery(account, synchronizable: true)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            var local = baseQuery(account, synchronizable: false)
            local[kSecValueData as String] = data
            local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(local as CFDictionary, nil)
        }
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account, synchronizable: nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account, synchronizable: nil) as CFDictionary)
    }

    private static func baseQuery(_ account: String, synchronizable: Bool?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        switch synchronizable {
        case .some(true): q[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .some(false): q[kSecAttrSynchronizable as String] = kCFBooleanFalse
        case .none: q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return q
    }
}
