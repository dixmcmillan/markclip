#if !OFFLINE
import XCTest

final class CloudflareAccountTests: XCTestCase {
    override func tearDown() { CloudflareFixtureProtocol.uninstall() }

    private func account(configured: Bool = true) -> (CloudflareAccount, InMemorySecretStore) {
        let store = InMemorySecretStore()
        let account = CloudflareAccount(store: store, session: CloudflareFixtureProtocol.makeSession())
        if configured { account.save(accountID: "acct123", apiToken: "tok-secret") }
        return (account, store)
    }

    func testCredentialsRoundTripThroughSecretStore() {
        let (account, store) = account(configured: false)
        XCTAssertFalse(account.isConfigured)
        XCTAssertNil(account.credentials)

        account.save(accountID: "  abc123\n", apiToken: " token-xyz \n")

        XCTAssertTrue(account.isConfigured)
        XCTAssertEqual(account.accountID, "abc123")
        XCTAssertEqual(account.apiToken, "token-xyz")
        XCTAssertEqual(account.credentials, CloudflareCredentials(accountID: "abc123", apiToken: "token-xyz"))
        XCTAssertEqual(store.read(service: CloudflareAccount.service, account: "api-token"), "token-xyz")

        account.clear()
        XCTAssertFalse(account.isConfigured)
        XCTAssertNil(store.read(service: CloudflareAccount.service, account: "api-token"))
        XCTAssertNil(store.read(service: CloudflareAccount.service, account: "account-id"))
    }

    func testEmptyValueLeavesAccountUnconfigured() {
        let (account, _) = account()
        account.save(accountID: "abc", apiToken: "   ")
        XCTAssertFalse(account.isConfigured)
    }

    func testTokenIsNeverWrittenToUserDefaults() {
        let marker = "tok-" + UUID().uuidString
        let (account, _) = account(configured: false)
        account.save(accountID: "abc", apiToken: marker)
        let dump = UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(dump.contains(marker))
    }

    func testClientsRequireConfiguration() throws {
        let (empty, _) = account(configured: false)
        XCTAssertThrowsError(try empty.streamClient()) { XCTAssertEqual($0 as? CloudflareError, .notConfigured) }
        XCTAssertThrowsError(try empty.imagesClient()) { XCTAssertEqual($0 as? CloudflareError, .notConfigured) }
        let (ready, _) = account()
        XCTAssertEqual(try ready.streamClient().chunkSize, 50 * 1024 * 1024)
        _ = try ready.imagesClient()
    }

    func testTestConnectionWhenUnconfigured() async {
        let (empty, _) = account(configured: false)
        do { _ = try await empty.testConnection(); XCTFail() }
        catch { XCTAssertEqual(error as? CloudflareError, .notConfigured) }
    }

    func testTestConnectionSucceedsAndProbesStreamAndImages() async throws {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct123/tokens/verify": return .envelope(["id": "t", "status": "active"])
            case "/client/v4/accounts/acct123/stream": return .envelope([Any]())
            case "/client/v4/accounts/acct123/images/v1": return .envelope(["images": [Any]()])
            default: return .failure(404, code: 7003, message: "No route")
            }
        }
        let result = try await account().0.testConnection()
        XCTAssertEqual(result, .init(tokenStatus: "active", streamAccess: true, imagesAccess: true))
        XCTAssertTrue(result.isUsable)
        let requests = CloudflareFixtureProtocol.requests
        XCTAssertEqual(requests.map(\.path), ["/client/v4/accounts/acct123/tokens/verify",
                                              "/client/v4/accounts/acct123/stream",
                                              "/client/v4/accounts/acct123/images/v1"])
        XCTAssertEqual(requests[1].request.url?.query, "limit=1")
        XCTAssertTrue(requests.allSatisfy { $0.header("Authorization") == "Bearer tok-secret" })
    }

    func testTestConnectionFallsBackToUserTokenVerify() async throws {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct123/tokens/verify": return .failure(403, code: 1000, message: "nope")
            case "/client/v4/user/tokens/verify": return .envelope(["status": "active"])
            default: return .envelope([Any]())
            }
        }
        let result = try await account().0.testConnection()
        XCTAssertTrue(result.isUsable)
        XCTAssertEqual(CloudflareFixtureProtocol.requests.prefix(2).map(\.path),
                       ["/client/v4/accounts/acct123/tokens/verify", "/client/v4/user/tokens/verify"])
    }

    func testTestConnectionRejectsInvalidToken() async {
        CloudflareFixtureProtocol.install { _ in .failure(401, code: 1000, message: "Invalid API Token") }
        do { _ = try await account().0.testConnection(); XCTFail() }
        catch { XCTAssertEqual(error as? CloudflareError, .authFailed) }
    }

    func testTestConnectionRejectsInactiveToken() async {
        CloudflareFixtureProtocol.install { _ in .envelope(["status": "expired"]) }
        do { _ = try await account().0.testConnection(); XCTFail() }
        catch { XCTAssertEqual(error as? CloudflareError, .tokenInactive(status: "expired")) }
    }

    func testTestConnectionReportsMissingStreamPermissionInResult() async throws {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct123/tokens/verify": return .envelope(["status": "active"])
            case "/client/v4/accounts/acct123/stream": return .failure(403, code: 10000, message: "Authentication error")
            default: return .envelope([Any]())
            }
        }
        let result = try await account().0.testConnection()
        XCTAssertFalse(result.streamAccess)
        XCTAssertEqual(result.imagesAccess, true)
        XCTAssertFalse(result.isUsable)
        XCTAssertTrue(result.summary.contains("Stream"))
    }

    func testImagesProbeInconclusiveWhenImagesIsNotEnabled() async throws {
        CloudflareFixtureProtocol.install { r in
            switch r.path {
            case "/client/v4/accounts/acct123/tokens/verify": return .envelope(["status": "active"])
            case "/client/v4/accounts/acct123/images/v1": return .failure(400, code: 5400, message: "Images not enabled")
            default: return .envelope([Any]())
            }
        }
        let result = try await account().0.testConnection()
        XCTAssertNil(result.imagesAccess)
        XCTAssertTrue(result.isUsable)
    }

    func testNetworkFailureDuringTestSurfaces() async {
        CloudflareFixtureProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await account().0.testConnection(); XCTFail() }
        catch { guard case .network = error as? CloudflareError else { return XCTFail("\(error)") } }
    }
}
#endif
