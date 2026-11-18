import Foundation
import Security

/// Thin Keychain wrapper. Items are:
///  - this-device-only (never synced to iCloud Keychain, never restored to another phone)
///  - readable after first unlock, so the background refresh works while the phone is locked.
enum Keychain {
    private static let service = "com.visiocapital.classly"

    static func set<T: Encodable>(_ value: T, for key: String) throws {
        let data = try JSONEncoder().encode(value)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: key] as CFDictionary)
    }

    static func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    enum KeychainError: Error { case status(OSStatus) }
}

/// What we keep for a PowerSchool parent login.
struct PowerSchoolCredential: Codable {
    var username: String?
    var password: String?          // only for username/password districts
    var cookies: [StoredCookie]    // session cookies captured after sign-in (also covers SSO districts)
}

struct StoredCookie: Codable {
    var name, value, domain, path: String
    var expires: Date?
    var secure: Bool

    init(_ c: HTTPCookie) {
        name = c.name; value = c.value; domain = c.domain; path = c.path
        expires = c.expiresDate; secure = c.isSecure
    }

    var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}

/// What we keep for a Membership Toolkit PTO login: just the session cookies (we never store
/// the parent's PTO password — they type it into Membership Toolkit's own page).
struct PTOCredential: Codable {
    var cookies: [StoredCookie]
}

/// OAuth tokens for one kid's Google account.
struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date
    var email: String?
}
