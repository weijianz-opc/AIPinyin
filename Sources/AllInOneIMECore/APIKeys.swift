import Foundation
import Security

/// The API keys of the Claude, Gemini and OpenAI-compatible providers, and of other services the
/// user brings a key for (the web search, `WebSearch`). They are kept in the login keychain (never in
/// the config file); a key set in the user's shell (`ANTHROPIC_API_KEY`, …) is used when the keychain
/// has none.
public enum APIKeys {
    static let service = "AllInOneIME API key"

    /// The key for `provider`: the keychain's, else the login shell's.
    public static func load(_ provider: Provider) -> String? {
        load(account: provider.rawValue, variables: provider.keyVariables)
    }

    /// The key kept under `account`: the keychain's, else the first of `variables` the login shell sets.
    public static func load(account: String, variables: [String]) -> String? {
        if let key = keychainKey(account: account) { return key }
        return variables.lazy.compactMap { ShellEnvironment.login[$0] }.first
    }

    /// Where the key comes from, for the settings window.
    public enum Source: Equatable, Sendable {
        case keychain
        case environment(String)
        case none
    }

    public static func source(_ provider: Provider) -> Source {
        source(account: provider.rawValue, variables: provider.keyVariables)
    }

    public static func source(account: String, variables: [String]) -> Source {
        if keychainKey(account: account) != nil { return .keychain }
        if let name = variables.first(where: { ShellEnvironment.login[$0] != nil }) { return .environment(name) }
        return .none
    }

    public static func keychainKey(_ provider: Provider) -> String? {
        keychainKey(account: provider.rawValue)
    }

    public static func keychainKey(account: String) -> String? {
        var query = baseQuery(account: account)
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
        try save(key, account: provider.rawValue, label: "AllInOneIME: \(provider.displayName)")
    }

    /// Stores `key` under `account`, shown in Keychain Access as `label`; an empty key removes it.
    public static func save(_ key: String, account: String, label: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard !key.isEmpty else { return }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = label
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
