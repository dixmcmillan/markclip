#if !OFFLINE
import XCTest

/// Settings ▸ Cloudflare: save, clear and test connection against an
/// in-memory secret store and a stubbed URL session (no Keychain, no network).
@MainActor
final class CloudflareSettingsTests: XCTestCase {
    override func tearDown() { CloudflareFixtureProtocol.uninstall() }

    private func make() -> (CloudflareSettingsModel, CloudflareAccount, InMemorySecretStore) {
        let store = InMemorySecretStore()
        let account = CloudflareAccount(store: store, session: CloudflareFixtureProtocol.makeSession())
        return (CloudflareSettingsModel(account: account), account, store)
    }

    func testStartsNotSetUp() {
        let (model, _, _) = make()
        XCTAssertEqual(model.status, .notSetUp)
        XCTAssertEqual(model.accountID, "")
        XCTAssertFalse(model.hasToken)
    }

    func testSaveStoresBothValuesInTheSecretStoreOnly() {
        let (model, account, store) = make()
        let marker = "tok-" + UUID().uuidString
        model.save(accountID: " acct1 ", tokenInput: marker)
        XCTAssertEqual(model.status, .saved)
        XCTAssertEqual(account.accountID, "acct1")
        XCTAssertEqual(store.read(service: CloudflareAccount.service, account: "api-token"), marker)
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().description.contains(marker))
        XCTAssertEqual(model.accountID, "acct1")
        XCTAssertTrue(model.hasToken)
    }

    func testEmptyTokenFieldKeepsTheStoredToken() {
        let (model, account, _) = make()
        model.save(accountID: "acct1", tokenInput: "secret")
        model.save(accountID: "acct2", tokenInput: "")
        XCTAssertEqual(account.accountID, "acct2")
        XCTAssertEqual(account.apiToken, "secret")
        XCTAssertEqual(model.status, .saved)
    }

    func testMissingHalfIsReportedAsIncomplete() {
        let (model, _, _) = make()
        model.save(accountID: "acct1", tokenInput: "")
        XCTAssertEqual(model.status, .incomplete)
        XCTAssertFalse(model.isConfigured)
    }

    func testClearRemovesBothValues() {
        let (model, account, store) = make()
        model.save(accountID: "acct1", tokenInput: "secret")
        model.clear()
        XCTAssertEqual(model.status, .notSetUp)
        XCTAssertNil(account.accountID)
        XCTAssertNil(store.read(service: CloudflareAccount.service, account: "api-token"))
        XCTAssertNil(model.testOutcome)
    }

    func testTestConnectionSavesThenShowsTheSummary() async {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct1/tokens/verify": return .envelope(["status": "active"])
            default: return .envelope([Any]())
            }
        }
        let (model, account, _) = make()
        var outcomes: [CloudflareSettingsModel.TestOutcome?] = []
        model.onChange = { outcomes.append(model.testOutcome) }
        await model.testConnection(accountID: "acct1", tokenInput: "secret")
        XCTAssertTrue(account.isConfigured, "testing uses what was typed")
        XCTAssertEqual(outcomes.last ?? nil, .finished(summary: "Connected. Stream and Images are available.", usable: true))
        XCTAssertTrue(outcomes.contains { $0 == .running })
    }

    func testTestConnectionReportsAMissingPermission() async {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct1/tokens/verify": return .envelope(["status": "active"])
            case "/client/v4/accounts/acct1/stream": return .failure(403, code: 10000, message: "Authentication error")
            default: return .envelope([Any]())
            }
        }
        let (model, _, _) = make()
        await model.testConnection(accountID: "acct1", tokenInput: "secret")
        guard case let .finished(summary, usable)? = model.testOutcome else { return XCTFail("\(String(describing: model.testOutcome))") }
        XCTAssertFalse(usable)
        XCTAssertTrue(summary.contains("Stream"))
    }

    func testTestConnectionShowsAuthFailure() async {
        CloudflareFixtureProtocol.install { _ in .failure(401, code: 1000, message: "Invalid API Token") }
        let (model, _, _) = make()
        await model.testConnection(accountID: "acct1", tokenInput: "bad")
        XCTAssertEqual(model.testOutcome, .failed(CloudflareError.authFailed.localizedDescription))
    }

    func testTestConnectionWithoutCredentialsDoesNotCallTheNetwork() async {
        CloudflareFixtureProtocol.install { _ in .envelope([Any]()) }
        let (model, _, _) = make()
        await model.testConnection(accountID: "", tokenInput: "")
        XCTAssertEqual(model.testOutcome, .failed(CloudflareError.notConfigured.localizedDescription))
        XCTAssertTrue(CloudflareFixtureProtocol.requests.isEmpty)
    }

    // MARK: View

    func testViewSavesAndClearsThroughItsButtons() {
        let (model, account, _) = make()
        let view = CloudflareSettingsView(model: model)
        view.fields.account.stringValue = "acct9"
        view.fields.token.stringValue = "tok9"
        view.buttons.save.performClick(nil)
        XCTAssertEqual(account.credentials, CloudflareCredentials(accountID: "acct9", apiToken: "tok9"))
        XCTAssertEqual(view.fields.token.stringValue, "", "the token is never kept in the field")
        XCTAssertTrue(view.buttons.clear.isEnabled)
        view.buttons.clear.performClick(nil)
        XCTAssertFalse(account.isConfigured)
        XCTAssertEqual(view.fields.account.stringValue, "")
        XCTAssertFalse(view.buttons.clear.isEnabled)
    }

    func testViewShowsTheTestResult() async {
        CloudflareFixtureProtocol.install { r in
            r.path.hasSuffix("/tokens/verify") ? .envelope(["status": "active"]) : .envelope([Any]())
        }
        let (model, _, _) = make()
        let view = CloudflareSettingsView(model: model)
        view.fields.account.stringValue = "acct1"
        view.fields.token.stringValue = "tok"
        view.buttons.test.performClick(nil)
        let shown = await waitUntil { view.resultText.hasPrefix("Connected") }
        XCTAssertTrue(shown, view.resultText)
        XCTAssertEqual(view.fields.token.stringValue, "")
    }
}
#endif
