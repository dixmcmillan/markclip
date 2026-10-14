#if !OFFLINE
import Foundation

/// The user's Cloudflare account ID and API token, kept in the Keychain (never
/// `UserDefaults`, never the settings export). Main-actor like `SecretStore`;
/// hand `credentials` to the nonisolated clients for off-main work.
///
/// The token needs **Stream: Edit** and **Images: Edit** on the account.
struct CloudflareAccount {
    static let service = "com.dixmcmillan.markclip.cloudflare"
    private static let accountIDKey = "account-id"
    private static let apiTokenKey = "api-token"

    /// Keychain-backed, except under XCTest, where it is in memory (see `KeychainSecretStore.makeDefault`).
    static let shared = CloudflareAccount(store: KeychainSecretStore.makeDefault())

    private let store: SecretStore
    private let session: URLSession

    init(store: SecretStore, session: URLSession = CloudflareAPI.makeSession()) {
        self.store = store
        self.session = session
    }

    var accountID: String? { store.read(service: Self.service, account: Self.accountIDKey) }
    var apiToken: String? { store.read(service: Self.service, account: Self.apiTokenKey) }

    var credentials: CloudflareCredentials? {
        guard let accountID, let apiToken else { return nil }
        return CloudflareCredentials(accountID: accountID, apiToken: apiToken)
    }

    var isConfigured: Bool { credentials != nil }

    /// Stores both values (surrounding whitespace, e.g. from a paste, is
    /// trimmed). An empty value removes it, so the account is unconfigured.
    func save(accountID: String, apiToken: String) {
        store.write(accountID.trimmingCharacters(in: .whitespacesAndNewlines), service: Self.service, account: Self.accountIDKey)
        store.write(apiToken.trimmingCharacters(in: .whitespacesAndNewlines), service: Self.service, account: Self.apiTokenKey)
    }

    func clear() {
        store.write(nil, service: Self.service, account: Self.accountIDKey)
        store.write(nil, service: Self.service, account: Self.apiTokenKey)
    }

    // MARK: Clients

    func streamClient(chunkSize: Int = CloudflareTus.recommendedChunkSize) throws -> CloudflareStreamClient {
        guard let credentials else { throw CloudflareError.notConfigured }
        return CloudflareStreamClient(credentials: credentials, session: session, chunkSize: chunkSize)
    }

    func imagesClient() throws -> CloudflareImagesClient {
        guard let credentials else { throw CloudflareError.notConfigured }
        return CloudflareImagesClient(credentials: credentials, session: session)
    }

    // MARK: Connection test

    nonisolated struct TestResult: Sendable, Equatable {
        /// Cloudflare's token status; always "active" here (anything else throws).
        let tokenStatus: String
        /// `GET /stream?limit=1` succeeded.
        let streamAccess: Bool
        /// `GET /images/v1` succeeded; `nil` when it couldn't be determined
        /// (for example Images isn't enabled on the account).
        let imagesAccess: Bool?

        /// Stream works and Images isn't known to be blocked.
        var isUsable: Bool { streamAccess && imagesAccess != false }

        /// Short, user-presentable outcome.
        var summary: String {
            var missing: [String] = []
            if !streamAccess { missing.append("Stream") }
            if imagesAccess == false { missing.append("Images") }
            if !missing.isEmpty {
                return "Token is valid but can't use \(missing.joined(separator: " or ")). Grant it Stream Edit and Images Edit for this account."
            }
            if imagesAccess == nil { return "Connected. Stream works; Images couldn't be checked." }
            return "Connected. Stream and Images are available."
        }
    }

    /// Verifies the token, then probes Stream and Images. Throws
    /// `notConfigured`, `authFailed`, `tokenInactive`, `network` or `cancelled`;
    /// a token that's valid but lacks a product is reported in the result.
    func testConnection() async throws -> TestResult {
        guard let credentials else { throw CloudflareError.notConfigured }
        return try await Self.runConnectionTest(credentials: credentials, session: session)
    }

    @concurrent
    private static func runConnectionTest(credentials: CloudflareCredentials, session: URLSession) async throws -> TestResult {
        let api = CloudflareAPI(credentials: credentials, session: session)
        let tokenStatus = try await verifyToken(api)
        guard tokenStatus == "active" else { throw CloudflareError.tokenInactive(status: tokenStatus) }

        let streamAccess = try await probe(api, URL(string: "\(api.accountURL)/stream?limit=1")!, .stream)
        let imagesAccess = try await probe(api, URL(string: "\(api.accountURL)/images/v1?page=1&per_page=10")!, .images)
        return TestResult(tokenStatus: tokenStatus, streamAccess: streamAccess == true, imagesAccess: imagesAccess)
    }

    private struct TokenInfo: Decodable { var status: String? }

    /// Account-scoped verify first (account-owned tokens only work there), then
    /// the user endpoint.
    private nonisolated static func verifyToken(_ api: CloudflareAPI) async throws -> String {
        let urls = ["\(api.accountURL)/tokens/verify", "\(CloudflareAPI.baseURL)/user/tokens/verify"]
        var lastError: CloudflareError = .authFailed
        for string in urls {
            do {
                let (data, response) = try await api.send(api.request("GET", URL(string: string)!))
                let info = try CloudflareAPI.decodeResult(TokenInfo.self, data, response, capability: .token)
                return info.status ?? "unknown"
            } catch {
                let mapped = CloudflareError.wrap(error)
                switch mapped {
                case .network, .cancelled: throw mapped
                default: lastError = mapped
                }
            }
        }
        throw lastError
    }

    /// `true` = allowed, `false` = permission missing, `nil` = inconclusive.
    private nonisolated static func probe(_ api: CloudflareAPI, _ url: URL, _ capability: CloudflareCapability) async throws -> Bool? {
        do {
            let (data, response) = try await api.send(api.request("GET", url))
            try CloudflareAPI.check(data, response, capability: capability)
            return true
        } catch {
            switch CloudflareError.wrap(error) {
            case .permissionMissing, .authFailed: return false
            case .network(let detail): throw CloudflareError.network(detail)
            case .cancelled: throw CloudflareError.cancelled
            default: return nil
            }
        }
    }
}
#endif
