#if !OFFLINE
import CryptoKit
import Foundation

/// Where Coach OS (TrainWithDixon's coaching tool) lives. Coach OS holds the
/// TrainWithDixon credentials and runs on the tailnet, so its address is the
/// only thing markclip stores for this destination, and it isn't a secret.
nonisolated enum CoachOSSettings {
    static let baseURLKey = "coachOSBaseURL"

    static func baseURL(defaults: UserDefaults = .standard) -> URL? {
        defaults.string(forKey: baseURLKey).flatMap(normalized)
    }

    /// Saves `text` when it is a usable address (an empty one clears it).
    /// Returns false, and changes nothing, for anything else.
    @discardableResult
    static func save(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: baseURLKey); return true }
        guard let url = normalized(trimmed) else { return false }
        defaults.set(url.absoluteString, forKey: baseURLKey)
        return true
    }

    /// `https://host[:port]` (or http) with no path, query or credentials.
    static func normalized(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = scheme
        components.path = ""
        return components.url
    }

    /// The Coach OS Media page, where uploads appear.
    static func mediaPageURL(defaults: UserDefaults = .standard) -> URL? {
        baseURL(defaults: defaults)?.appendingPathComponent("media")
    }
}

nonisolated enum CoachOSError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case invalidFile(String)
    /// Coach OS (or Stream, for tus requests) answered with an error status.
    case server(status: Int, message: String)
    case invalidResponse(String)
    case network(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "TrainWithDixon isn't set up yet. Add the Coach OS address in Settings."
        case .invalidFile(let detail):
            return detail
        case .server(let status, let message):
            return "Coach OS error \(status): \(message)"
        case .invalidResponse(let detail):
            return "Unexpected response from Coach OS: \(detail)"
        case .network(let detail):
            return "Couldn't reach Coach OS: \(detail)"
        case .cancelled:
            return "The upload was cancelled."
        }
    }

    static func wrap(_ error: Error) -> CoachOSError {
        if let error = error as? CoachOSError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }

    /// Network drops and 408/429/5xx are worth retrying with the same request.
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .server(let status, _): return CloudflareAPI.isTransient(status: status)
        default: return false
        }
    }
}

/// Uploads a video through Coach OS's managed Stream upload flow, so
/// TrainWithDixon records it as Managed with signed delivery:
///
/// 1. `POST /api/media-stream-upload-reservations` reserves the upload and
///    returns a one-time tus `uploadUrl` (already created, signed-only).
/// 2. tus HEAD/PATCH to `uploadUrl`. No credentials are sent; the URL is the
///    capability. A dropped connection resumes from the server's offset.
/// 3. If the URL is gone (expired, 404/410),
///    `POST …/{id}/upload-attempts` gets a fresh one on the same reservation.
/// 4. `POST …/{id}/reconcile` (`reconcile(reservationID:)`) until ready.
///
/// Every POST carries a `commandKey`; a retry of the same intent reuses its
/// key, so Coach OS replays the outcome instead of acting twice.
nonisolated struct CoachOSClient: Sendable {
    enum ReconcileState: Equatable, Sendable {
        case processing(percent: Double?)
        case ready
    }

    let baseURL: URL
    let chunkSize: Int
    /// Consecutive failures tolerated before giving up. With the doubling
    /// back-off (capped at 30 s) the default rides out about three minutes
    /// offline, so a dropped Wi-Fi resumes this reservation instead of failing
    /// the run (a retried run re-renders and needs a new reservation).
    let maxResumeAttempts: Int
    /// Fresh upload URLs one upload may ask for after its first one dies.
    let maxUploadAttempts: Int
    private let session: URLSession
    private let retryDelay: TimeInterval
    private let makeKey: @Sendable (String) -> String

    init(baseURL: URL,
         session: URLSession = CloudflareAPI.makeSession(),
         chunkSize: Int = CloudflareTus.recommendedChunkSize,
         minimumChunkSize: Int = CloudflareTus.minimumChunkSize,
         maxResumeAttempts: Int = 10,
         maxUploadAttempts: Int = 2,
         retryDelay: TimeInterval = 1,
         makeKey: @escaping @Sendable (String) -> String = { "command:markclip-\($0):\(UUID().uuidString.lowercased())" }) {
        self.baseURL = baseURL
        self.session = session
        self.chunkSize = CloudflareTus.normalizedChunkSize(chunkSize, minimum: minimumChunkSize)
        self.maxResumeAttempts = max(0, maxResumeAttempts)
        self.maxUploadAttempts = max(0, maxUploadAttempts)
        self.retryDelay = max(0, retryDelay)
        self.makeKey = makeKey
    }

    // MARK: Wire

    nonisolated struct Reservation: Decodable, Sendable, Equatable {
        let id: String
        let status: String?
        let providerAssetId: String?
    }

    private nonisolated struct UploadResponse: Decodable {
        let reservation: Reservation
        let uploadUrl: String?
    }

    private nonisolated struct ReconcileResponse: Decodable {
        let reservation: Reservation?
        let processingState: String?
        let progressPercent: Double?
    }

    private nonisolated struct ErrorBody: Decodable { let error: String? }

    private nonisolated struct CreateBody: Encodable {
        let commandKey: String
        let filename: String
        let contentType: String
        let sizeBytes: Int
        let durationSeconds: Double?
        let title: String
        let contentFingerprint: String
    }

    private nonisolated struct CommandBody: Encodable { let commandKey: String }

    // MARK: Upload

    /// Uploads `fileURL` and returns the reservation id (poll it with
    /// `reconcile`). `progress` gets 0...1 from any thread; it restarts at 0
    /// if a fresh upload URL is needed. Cancellation throws `.cancelled`.
    @concurrent
    func upload(fileURL: URL, title: String, durationSeconds: Double?,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let filename = fileURL.lastPathComponent
        guard let contentType = Self.contentType(forExtension: fileURL.pathExtension) else {
            throw CoachOSError.invalidFile("Coach OS only takes MP4, MOV, WebM, AVI, MKV or MPEG video.")
        }
        let size: Int
        do { size = try CloudflareAPI.fileSize(of: fileURL) }
        catch { throw CoachOSError.invalidFile("\(filename) isn't a readable file.") }
        guard size > 0 else { throw CoachOSError.invalidFile("\(filename) is empty.") }
        let fingerprint = try Self.fingerprint(of: fileURL)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw CoachOSError.invalidFile("\(filename) couldn't be opened: \(error.localizedDescription)") }
        defer { try? handle.close() }

        let body = CreateBody(commandKey: makeKey("reserve-stream"), filename: filename, contentType: contentType,
                              sizeBytes: size, durationSeconds: durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                              title: Self.title(title), contentFingerprint: fingerprint)
        let created = try await postWithRetry(path: ["api", "media-stream-upload-reservations"], body: body,
                                              as: UploadResponse.self)
        let reservationID = created.reservation.id
        guard !reservationID.isEmpty else { throw CoachOSError.invalidResponse("the reservation had no id") }

        // A replayed reservation (our first reply was lost) has no URL; ask for one.
        var uploadURL = try created.uploadUrl.map(Self.uploadURL)
        var freshURLs = 0
        if uploadURL == nil {
            guard let url = try await newUploadAttempt(reservationID: reservationID) else { return reservationID }
            uploadURL = url
        }
        progress?(0)
        while let url = uploadURL {
            do {
                try await sendFile(handle, size: size, to: url, progress: progress)
                return reservationID
            } catch CoachOSError.server(let status, _) where Self.isGone(status) && freshURLs < maxUploadAttempts {
                freshURLs += 1
                progress?(0)
                guard let next = try await newUploadAttempt(reservationID: reservationID) else { return reservationID }
                uploadURL = next
            }
        }
        return reservationID
    }

    /// tus PATCHes from offset 0, resuming from the server's `Upload-Offset`
    /// after a transient failure. Throws `.server(404/410)` when the URL is gone.
    private func sendFile(_ handle: FileHandle, size: Int, to url: URL,
                          progress: (@Sendable (Double) -> Void)?) async throws {
        var offset = 0
        var failures = 0
        while offset < size {
            try Self.checkCancelled()
            do {
                offset = try await sendChunk(handle, offset: offset, size: size, to: url, progress: progress)
                failures = 0
                progress?(Double(offset) / Double(size))
            } catch {
                var lastError = CoachOSError.wrap(error)
                while true {
                    guard Self.isResumable(lastError), failures < maxResumeAttempts else { throw lastError }
                    failures += 1
                    try await pause(attempt: failures)
                    do {
                        offset = try await currentOffset(of: url, size: size)
                        break
                    } catch { lastError = CoachOSError.wrap(error) }
                }
            }
        }
    }

    private func sendChunk(_ handle: FileHandle, offset: Int, size: Int, to url: URL,
                           progress: (@Sendable (Double) -> Void)?) async throws -> Int {
        let chunk: Data
        do {
            try handle.seek(toOffset: UInt64(offset))
            chunk = try handle.read(upToCount: min(chunkSize, size - offset)) ?? Data()
        } catch {
            throw CoachOSError.invalidFile("The file couldn't be read: \(error.localizedDescription)")
        }
        guard !chunk.isEmpty else { throw CoachOSError.invalidFile("The file changed while it was uploading.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(CloudflareTus.version, forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = progress.map { CloudflareProgressDelegate(baseBytes: Int64(offset), totalBytes: Int64(size), report: $0) }
        let (data, response) = try await send(request, body: chunk, delegate: delegate)
        try Self.check(data, response)
        let newOffset = CloudflareTus.offset(in: response) ?? offset + chunk.count
        guard newOffset > offset, newOffset <= size else {
            throw CoachOSError.invalidResponse("the upload server reported offset \(newOffset)")
        }
        return newOffset
    }

    private func currentOffset(of url: URL, size: Int) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(CloudflareTus.version, forHTTPHeaderField: "Tus-Resumable")
        let (data, response) = try await send(request)
        try Self.check(data, response)
        guard let offset = CloudflareTus.offset(in: response), offset <= size else {
            throw CoachOSError.invalidResponse("the upload server didn't report a usable Upload-Offset")
        }
        return offset
    }

    /// A fresh upload URL on the same reservation (Stream starts over at 0).
    /// Nil when Coach OS says the reservation is already verified.
    private func newUploadAttempt(reservationID: String) async throws -> URL? {
        // A replay without a URL means an earlier call with this key succeeded
        // but its reply was lost; only a new key gets a new URL.
        for _ in 0..<2 {
            let response = try await postWithRetry(
                path: ["api", "media-stream-upload-reservations", reservationID, "upload-attempts"],
                body: CommandBody(commandKey: makeKey("resume-stream")), as: UploadResponse.self)
            if let url = response.uploadUrl { return try Self.uploadURL(url) }
            if response.reservation.status == "verified" { return nil }
        }
        throw CoachOSError.invalidResponse("Coach OS didn't return an upload URL")
    }

    // MARK: Reconcile

    /// Asks Coach OS to check the upload with Stream. Each call is a new
    /// command (a reused key would only replay the old answer).
    func reconcile(reservationID: String) async throws -> ReconcileState {
        let response = try await post(path: ["api", "media-stream-upload-reservations", reservationID, "reconcile"],
                                      body: CommandBody(commandKey: makeKey("reconcile-stream")),
                                      as: ReconcileResponse.self)
        if response.processingState == "ready" { return .ready }
        return .processing(percent: response.progressPercent)
    }

    // MARK: HTTP

    private func postWithRetry<Body: Encodable, Response: Decodable>(path: [String], body: Body,
                                                                    as type: Response.Type) async throws -> Response {
        var failures = 0
        while true {
            do { return try await post(path: path, body: body, as: type) }
            catch {
                let mapped = CoachOSError.wrap(error)
                guard mapped.isTransient, failures < maxResumeAttempts else { throw mapped }
                failures += 1
                try await pause(attempt: failures)
            }
        }
    }

    private func post<Body: Encodable, Response: Decodable>(path: [String], body: Body,
                                                           as type: Response.Type) async throws -> Response {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Astro's origin check passes JSON without it; sent anyway so a stricter
        // check still sees a same-origin request.
        request.setValue(Self.origin(of: baseURL), forHTTPHeaderField: "Origin")
        let encoded: Data
        do { encoded = try JSONEncoder().encode(body) }
        catch { throw CoachOSError.invalidResponse("couldn't encode the request") }
        let (data, response) = try await send(request, body: encoded, delegate: nil)
        try Self.check(data, response)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CoachOSError.invalidResponse("couldn't read the response (\(error.localizedDescription))") }
    }

    private func endpoint(_ path: [String]) throws -> URL {
        var string = baseURL.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for component in path {
            guard !component.isEmpty,
                  let encoded = component.addingPercentEncoding(withAllowedCharacters: Self.componentAllowed) else {
                throw CoachOSError.invalidResponse("bad path component")
            }
            string += "/" + encoded
        }
        guard let url = URL(string: string) else { throw CoachOSError.invalidResponse("bad URL") }
        return url
    }

    /// `encodeURIComponent`'s set, which is what Coach OS's own client uses
    /// (reservation ids contain a colon).
    private static let componentAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            return (data, try Self.http(response))
        } catch { throw CoachOSError.wrap(error) }
    }

    private func send(_ request: URLRequest, body: Data,
                      delegate: URLSessionTaskDelegate?) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            return (data, try Self.http(response))
        } catch { throw CoachOSError.wrap(error) }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw CoachOSError.invalidResponse("not an HTTP response") }
        return http
    }

    /// Throws `.server` for a non-2xx, with Coach OS's `{"error": …}` message
    /// when there is one.
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            .flatMap { $0.isEmpty ? nil : $0 } ?? HTTPURLResponse.localizedString(forStatusCode: status)
        throw CoachOSError.server(status: status, message: message)
    }

    // MARK: Helpers

    static func contentType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "mpg", "mpeg": return "video/mpeg"
        default: return nil
        }
    }

    /// Coach OS takes 1-200 characters.
    static func title(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Export" : String(trimmed.prefix(200))
    }

    /// `sha256:<lowercase hex>` of the whole file, read in chunks.
    static func fingerprint(of url: URL) throws -> String {
        var hasher = SHA256()
        do { try UploadPayload.file(url).forEachChunk { try checkCancelled(); hasher.update(data: $0) } }
        catch let error as CoachOSError { throw error }
        catch { throw CoachOSError.invalidFile("The file couldn't be read: \(error.localizedDescription)") }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func uploadURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw CoachOSError.invalidResponse("the upload URL isn't valid")
        }
        return url
    }

    private static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }

    /// The upload URL no longer exists (expired or replaced).
    private static func isGone(_ status: Int) -> Bool { status == 404 || status == 410 }

    /// Network drops, 408/429/5xx and tus offset conflicts (409) can be resumed.
    private static func isResumable(_ error: CoachOSError) -> Bool {
        if error.isTransient { return true }
        if case .server(409, _) = error { return true }
        return false
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw CoachOSError.cancelled }
    }

    private func pause(attempt: Int) async throws {
        guard retryDelay > 0 else { return try Self.checkCancelled() }
        let seconds = min(30, retryDelay * pow(2, Double(attempt - 1)))
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { throw CoachOSError.wrap(error) }
    }
}
#endif
