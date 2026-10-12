import XCTest

/// The API key for the OpenAI-compatible transcription provider must never
/// touch `UserDefaults` (it would otherwise leak into the settings export
/// JSON — see `SettingsPortability`) or the system Keychain in a headless
/// test run. `SecretStore` is the seam: these tests exercise
/// `InMemorySecretStore` directly and through the `TranscriptionSecrets`
/// facade with the real Keychain swapped out, so none of this ever touches
/// the actual Keychain.
final class SecretStoreTests: XCTestCase {

    func testInMemoryStoreRoundTrips() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.read(service: "svc", account: "acct"))
        store.write("sk-12345", service: "svc", account: "acct")
        XCTAssertEqual(store.read(service: "svc", account: "acct"), "sk-12345")
    }

    func testInMemoryStoreOverwrites() {
        let store = InMemorySecretStore()
        store.write("first", service: "svc", account: "acct")
        store.write("second", service: "svc", account: "acct")
        XCTAssertEqual(store.read(service: "svc", account: "acct"), "second")
    }

    func testWritingNilDeletes() {
        let store = InMemorySecretStore()
        store.write("value", service: "svc", account: "acct")
        store.write(nil, service: "svc", account: "acct")
        XCTAssertNil(store.read(service: "svc", account: "acct"))
    }

    func testWritingEmptyStringDeletes() {
        // Mirrors the real Keychain store: an empty API key field means
        // "no key", not a stored empty string.
        let store = InMemorySecretStore()
        store.write("value", service: "svc", account: "acct")
        store.write("", service: "svc", account: "acct")
        XCTAssertNil(store.read(service: "svc", account: "acct"))
    }

    func testStoresAreIsolatedByServiceAndAccount() {
        let store = InMemorySecretStore()
        store.write("a", service: "svc1", account: "acct")
        store.write("b", service: "svc2", account: "acct")
        store.write("c", service: "svc1", account: "acct2")
        XCTAssertEqual(store.read(service: "svc1", account: "acct"), "a")
        XCTAssertEqual(store.read(service: "svc2", account: "acct"), "b")
        XCTAssertEqual(store.read(service: "svc1", account: "acct2"), "c")
    }

    // MARK: - TranscriptionSecrets facade

    func testTranscriptionSecretsUsesTheInjectedStore() {
        let previous = TranscriptionSecrets.store
        let fake = InMemorySecretStore()
        TranscriptionSecrets.store = fake
        defer { TranscriptionSecrets.store = previous }

        XCTAssertNil(TranscriptionSecrets.openAIAPIKey)
        TranscriptionSecrets.openAIAPIKey = "sk-test-key"
        XCTAssertEqual(TranscriptionSecrets.openAIAPIKey, "sk-test-key")
        // Went through the fake store, not the real Keychain.
        XCTAssertNotNil(fake.read(service: "com.dixmcmillan.markclip.transcription", account: "openai-api-key"))
    }

    func testTranscriptionSecretsClearingSetsNil() {
        let previous = TranscriptionSecrets.store
        TranscriptionSecrets.store = InMemorySecretStore()
        defer { TranscriptionSecrets.store = previous }

        TranscriptionSecrets.openAIAPIKey = "sk-test-key"
        TranscriptionSecrets.openAIAPIKey = nil
        XCTAssertNil(TranscriptionSecrets.openAIAPIKey)
    }
}
