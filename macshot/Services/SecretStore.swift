import Foundation
import Security

/// A place to persist a small secret (an API key) outside `UserDefaults`.
/// `KeychainSecretStore` is the real backing; tests substitute
/// `InMemorySecretStore` so they never touch the system Keychain, which
/// needs entitlements and can prompt — neither is available to a headless
/// `macshotTests` run.
protocol SecretStore: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ value: String?, service: String, account: String)
}

/// Real Keychain-backed store (`kSecClassGenericPassword`) — the first use
/// of Keychain in this app. The earlier uploaders (Google Drive, S3) kept
/// their credentials in `UserDefaults`/a token file to avoid Keychain ACL
/// prompts; they've since been removed (`LegacyUploadCleanup`). A secret
/// introduced for transcription (an OpenAI-compatible API key) must never
/// touch `UserDefaults` or the settings-export JSON, which is why it gets
/// the real thing instead of following that precedent.
struct KeychainSecretStore: SecretStore {
    static let shared = KeychainSecretStore()

    /// True inside an XCTest process. The Keychain holds the user's real
    /// credentials (the installed app shares service names with the tests'
    /// code), and touching them from a test shows password prompts.
    nonisolated static let isUnderTest = NSClassFromString("XCTestCase") != nil

    /// The store app code should default to: the Keychain, or a throwaway
    /// in-memory store under XCTest so tests can never reach the real one.
    nonisolated static func makeDefault() -> SecretStore {
        isUnderTest ? InMemorySecretStore() : shared
    }

    func read(service: String, account: String) -> String? {
        // Backstop for anything that builds a `KeychainSecretStore` directly.
        guard !Self.isUnderTest else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, service: String, account: String) {
        guard !Self.isUnderTest else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

/// In-memory store for tests and previews: never touches the real Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key(service, account)]
    }

    func write(_ value: String?, service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        let k = key(service, account)
        if let value, !value.isEmpty { storage[k] = value } else { storage.removeValue(forKey: k) }
    }
}

/// Facade the app calls through. `store` is swappable so tests never touch
/// the real Keychain (`TranscriptionSecrets.store = InMemorySecretStore()`).
enum TranscriptionSecrets {
    private static let service = "com.dixmcmillan.markclip.transcription"
    private static let openAIAccount = "openai-api-key"

    static var store: SecretStore = KeychainSecretStore.makeDefault()

    static var openAIAPIKey: String? {
        get { store.read(service: service, account: openAIAccount) }
        set { store.write(newValue, service: service, account: openAIAccount) }
    }
}
