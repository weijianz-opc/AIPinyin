import Foundation
import Security

/// The API keys of the Claude, Gemini and OpenAI-compatible providers. They are kept in the login
/// keychain (never in the config file); a key set in the user's shell (`ANTHROPIC_API_KEY`, …) is
/// used when the keychain has none.
public enum APIKeys {
    static let service = "AllInOneIME API key"

    /// The key for `provider`: the keychain's, else the login shell's.
    public static func load(_ provider: Provider) -> String? {
        if let key = keychainKey(provider) { return key }
        return provider.keyVariables.lazy.compactMap { ShellEnvironment.login[$0] }.first
    }

    /// Where the key comes from, for the settings window.
    public enum Source: Equatable, Sendable {
        case keychain
        case environment(String)
        case none
    }

    public static func source(_ provider: Provider) -> Source {
        if keychainKey(provider) != nil { return .keychain }
        if let name = provider.keyVariables.first(where: { ShellEnvironment.login[$0] != nil }) { return .environment(name) }
        return .none
    }

    public static func keychainKey(_ provider: Provider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Stores `key` for `provider`; an empty key removes it.
    public static func save(_ key: String, for provider: Provider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(provider) as CFDictionary)
        guard !key.isEmpty else { return }
        var item = baseQuery(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "AllInOneIME: \(provider.displayName)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func baseQuery(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
