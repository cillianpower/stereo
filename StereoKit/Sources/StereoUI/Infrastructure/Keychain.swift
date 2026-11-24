import Foundation
import Security

/// Small Keychain wrapper. Items are iCloud-synchronizable when the app has the entitlement,
/// so every device signs in automatically; unsigned dev builds fall back to a local item.
enum Keychain {
    static let service = "app.stereo.credentials"

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let data = Data(value.utf8)
        var query = baseQuery(account, synchronizable: true)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return true }

        var local = baseQuery(account, synchronizable: false)
        local[kSecValueData as String] = data
        local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(local as CFDictionary, nil) == errSecSuccess { return true }

        #if os(macOS)
        // Builds without an App ID can't use the data protection keychain; use the login keychain.
        var login = loginQuery(account)
        login[kSecValueData as String] = data
        return SecItemAdd(login as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account, synchronizable: nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        #if os(macOS)
        var login = loginQuery(account)
        login[kSecReturnData as String] = true
        login[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(login as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        #endif
        return nil
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account, synchronizable: nil) as CFDictionary)
        #if os(macOS)
        SecItemDelete(loginQuery(account) as CFDictionary)
        #endif
    }

    #if os(macOS)
    private static func loginQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

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
