#if !OFFLINE
import Foundation
import UniformTypeIdentifiers

/// Account ID + API token. Plain value so clients (which run off the main
/// actor) never touch the Keychain; `CloudflareAccount` owns persistence.
nonisolated struct CloudflareCredentials: Sendable, Equatable {
    let accountID: String
    let apiToken: String
}

/// What a request needs the token to be able to do. Decides how a 403 reads.
nonisolated enum CloudflareCapability: Sendable {
    case token, stream, images

    var displayName: String {
        switch self {
        case .token: return "this account"
        case .stream: return "Cloudflare Stream"
        case .images: return "Cloudflare Images"
        }
    }
}

/// Shared REST plumbing: authenticated requests, error-envelope mapping and
/// multipart bodies built on disk. Stateless apart from the injected session.
nonisolated struct CloudflareAPI: Sendable {
    static let baseURL = "https://api.cloudflare.com/client/v4"

    let credentials: CloudflareCredentials
    let session: URLSession

    init(credentials: CloudflareCredentials, session: URLSession = CloudflareAPI.makeSession()) {
        self.credentials = credentials
        self.session = session
    }

    /// Ephemeral (no cache or cookies); the request timeout is an idle timeout,
    /// so it's safe for large chunk uploads on slow links.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: URLs

    var accountURL: String { "\(Self.baseURL)/accounts/\(credentials.accountID)" }
    var streamURL: URL { URL(string: "\(accountURL)/stream")! }
    var imagesURL: URL { URL(string: "\(accountURL)/images/v1")! }

    func streamURL(uid: String, path: String? = nil) throws -> URL {
        var string = "\(accountURL)/stream/\(try Self.pathComponent(uid))"
        if let path { string += "/" + path }
        guard let url = URL(string: string) else { throw CloudflareError.invalidResponse("bad URL \(string)") }
        return url
    }

    /// Percent-encodes one URL path component (rejects empty values).
    static func pathComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                  .replacingOccurrences(of: "/", with: "%2F") else {
            throw CloudflareError.invalidResponse("empty path component")
        }
        return encoded
    }

    // MARK: Requests

    func request(_ method: String, _ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.apiToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            return (data, try Self.http(response))
        } catch { throw CloudflareError.wrap(error) }
    }

    func send(_ request: URLRequest, body: Data,
              delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            return (data, try Self.http(response))
        } catch { throw CloudflareError.wrap(error) }
    }

    func send(_ request: URLRequest, bodyFile: URL,
              delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.upload(for: request, fromFile: bodyFile, delegate: delegate)
            return (data, try Self.http(response))
        } catch { throw CloudflareError.wrap(error) }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareError.invalidResponse("not an HTTP response")
        }
        return http
    }

    // MARK: Envelope

    struct Envelope<Result: Decodable>: Decodable {
        let success: Bool?
        let errors: [Item]?
        let result: Result?
        struct Item: Decodable {
            let code: Int?
            let message: String?
        }
    }

    private struct ErrorEnvelope: Decodable {
        let success: Bool?
        let errors: [Envelope<String>.Item]?
    }

    /// Codes Cloudflare uses for a missing / malformed / unknown token.
    private static let authErrorCodes: Set<Int> = [1000, 6003, 6111, 9103, 9106, 9109]

    /// Throws the mapped `CloudflareError` unless the response is a 2xx whose
    /// envelope (when it has one) says `success`.
    static func check(_ data: Data, _ response: HTTPURLResponse, capability: CloudflareCapability,
                      sizeLimit: (what: String, bytes: Int)? = nil) throws {
        let status = response.statusCode
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        if (200..<300).contains(status), envelope?.success != false { return }

        let first = envelope?.errors?.first
        if status == 401 || (first?.code).map(authErrorCodes.contains) == true {
            throw CloudflareError.authFailed
        }
        if status == 403 {
            if capability == .token { throw CloudflareError.authFailed }
            throw CloudflareError.permissionMissing(capability: capability.displayName)
        }
        if status == 413, let sizeLimit {
            throw CloudflareError.fileTooLarge(what: sizeLimit.what, limitBytes: sizeLimit.bytes)
        }
        throw CloudflareError.api(code: first?.code,
                                  message: first?.message ?? HTTPURLResponse.localizedString(forStatusCode: status),
                                  status: status)
    }

    /// `check`, then decode `result` from the envelope.
    static func decodeResult<Result: Decodable>(_ type: Result.Type, _ data: Data, _ response: HTTPURLResponse,
                                                capability: CloudflareCapability,
                                                sizeLimit: (what: String, bytes: Int)? = nil) throws -> Result {
        try check(data, response, capability: capability, sizeLimit: sizeLimit)
        do {
            let envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
            guard let result = envelope.result else {
                throw CloudflareError.invalidResponse("missing result")
            }
            return result
        } catch let error as CloudflareError {
            throw error
        } catch {
            throw CloudflareError.invalidResponse("couldn't read the response (\(error.localizedDescription))")
        }
    }

    /// 408 / 429 / 5xx are worth retrying; everything else is final.
    static func isTransient(status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }

    // MARK: Multipart

    /// Writes `fields` plus one streamed file part to `destination`; the file
    /// is copied in 1 MiB chunks, never loaded whole.
    static func writeMultipartBody(to destination: URL, boundary: String, fields: [(name: String, value: String)],
                                   fileField: String, fileURL: URL, filename: String, mimeType: String) throws {
        try MultipartBodyWriter.write(to: destination) { append in
            for field in fields {
                try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(headerSafe(field.name))\"\r\n\r\n\(field.value)\r\n".utf8))
            }
            try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(headerSafe(fileField))\"; filename=\"\(headerSafe(filename))\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
            try UploadPayload.file(fileURL).forEachChunk(append)
            try append(Data("\r\n--\(boundary)--\r\n".utf8))
        }
    }

    private static func headerSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Size of a regular file. Reads fresh attributes (a `URL` instance caches
    /// resource values, which goes stale if the same URL is reused after the
    /// file changed).
    static func fileSize(of url: URL) throws -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw CloudflareError.invalidFile("\(url.lastPathComponent) isn't a readable file.")
        }
        return size
    }
}

/// Reports `(baseBytes + sent) / totalBytes` for one task. Called on the
/// URLSession delegate queue, so the callback must be thread-safe.
nonisolated final class CloudflareProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseBytes: Int64
    private let totalBytes: Int64
    private let report: @Sendable (Double) -> Void

    init(baseBytes: Int64 = 0, totalBytes: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.baseBytes = baseBytes
        self.totalBytes = totalBytes
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytes > 0 else { return }
        report(min(1, max(0, Double(baseBytes + totalBytesSent) / Double(totalBytes))))
    }
}
#endif
