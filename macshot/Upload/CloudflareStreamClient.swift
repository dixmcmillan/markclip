#if !OFFLINE
import Foundation

/// What `GET /stream/{uid}` says about a video.
nonisolated struct StreamStatus: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case pendingUpload, downloading, queued, inProgress, ready, error
        case other(String)

        init(rawValue: String?) {
            switch rawValue?.lowercased() {
            case "pendingupload": self = .pendingUpload
            case "downloading": self = .downloading
            case "queued": self = .queued
            case "inprogress": self = .inProgress
            case "ready": self = .ready
            case "error": self = .error
            case let other?: self = .other(other)
            case nil: self = .other("unknown")
            }
        }
    }

    let uid: String
    let state: State
    let readyToStream: Bool
    /// 0...100 while encoding; Cloudflare sends it as a string or a number.
    let percentComplete: Double?
    let errorReasonCode: String?
    let errorReasonText: String?
    let durationSeconds: Double?
    let hlsURL: URL?
    let dashURL: URL?
    let thumbnailURL: URL?
    let previewURL: URL?

    var isFailed: Bool { state == .error }
    var isFinished: Bool { readyToStream || state == .ready || state == .error }
}

extension StreamStatus {
    /// Wire shape; tolerant of missing fields and string/number `pctComplete`.
    fileprivate nonisolated struct Wire: Decodable {
        var uid: String?
        var readyToStream: Bool?
        var duration: Double?
        var thumbnail: String?
        var preview: String?
        var playback: Playback?
        var status: Status?

        nonisolated struct Playback: Decodable { var hls: String?; var dash: String? }
        nonisolated struct Status: Decodable {
            var state: String?
            var pctComplete: LenientDouble?
            var errorReasonCode: String?
            var errorReasonText: String?
        }
    }

    fileprivate nonisolated struct LenientDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { value = number }
            else if let string = try? container.decode(String.self) { value = Double(string) }
            else { value = nil }
        }
    }

    fileprivate nonisolated init(wire: Wire, fallbackUID: String) {
        let state = State(rawValue: wire.status?.state)
        uid = wire.uid ?? fallbackUID
        self.state = state
        readyToStream = wire.readyToStream ?? (state == .ready)
        percentComplete = wire.status?.pctComplete?.value
        errorReasonCode = wire.status?.errorReasonCode.flatMap { $0.isEmpty ? nil : $0 }
        errorReasonText = wire.status?.errorReasonText.flatMap { $0.isEmpty ? nil : $0 }
        durationSeconds = wire.duration.flatMap { $0 >= 0 ? $0 : nil }   // -1 = not known yet
        hlsURL = wire.playback?.hls.flatMap(URL.init(string:))
        dashURL = wire.playback?.dash.flatMap(URL.init(string:))
        thumbnailURL = wire.thumbnail.flatMap(URL.init(string:))
        previewURL = wire.preview.flatMap(URL.init(string:))
    }
}

/// Cloudflare Stream: tus resumable upload, status polling, deletion and
/// caption upload. Stateless and `Sendable`; one call is one job.
///
/// Memory stays bounded by `chunkSize`: each PATCH reads one chunk from the
/// source file with `FileHandle`, and a resume re-reads from the offset the
/// server reports, so the file is never loaded whole.
nonisolated struct CloudflareStreamClient: Sendable {
    static let captionsSizeLimit = 10 * 1024 * 1024

    private let api: CloudflareAPI
    let chunkSize: Int
    let maxResumeAttempts: Int
    private let retryDelay: TimeInterval

    /// - Parameters:
    ///   - chunkSize: rounded down to a multiple of 256 KiB and clamped to
    ///     Cloudflare's 5-200 MiB window.
    ///   - minimumChunkSize: only tests lower this, to exercise multi-chunk
    ///     uploads with small fixtures.
    ///   - maxResumeAttempts: consecutive failures tolerated (each one resumes
    ///     from the server's `Upload-Offset`); a successful chunk resets it.
    ///   - retryDelay: base back-off in seconds (multiplied by the attempt).
    init(credentials: CloudflareCredentials,
         session: URLSession = CloudflareAPI.makeSession(),
         chunkSize: Int = CloudflareTus.recommendedChunkSize,
         minimumChunkSize: Int = CloudflareTus.minimumChunkSize,
         maxResumeAttempts: Int = 3,
         retryDelay: TimeInterval = 1) {
        api = CloudflareAPI(credentials: credentials, session: session)
        self.chunkSize = CloudflareTus.normalizedChunkSize(chunkSize, minimum: minimumChunkSize)
        self.maxResumeAttempts = max(0, maxResumeAttempts)
        self.retryDelay = max(0, retryDelay)
    }

    // MARK: Upload

    /// Uploads `fileURL` with tus and returns the Stream video UID.
    /// `progress` receives 0...1 from an arbitrary thread. Task cancellation
    /// stops before the next request and throws `CloudflareError.cancelled`.
    @concurrent
    func upload(fileURL: URL, name: String, requireSignedURLs: Bool = false,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let size = try CloudflareAPI.fileSize(of: fileURL)
        guard size > 0 else { throw CloudflareError.invalidFile("\(fileURL.lastPathComponent) is empty.") }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw CloudflareError.invalidFile("\(fileURL.lastPathComponent) couldn't be opened: \(error.localizedDescription)") }
        defer { try? handle.close() }

        let (location, uid) = try await createUpload(size: size, name: name, requireSignedURLs: requireSignedURLs)
        progress?(0)

        var offset = 0
        var failures = 0
        while offset < size {
            try Self.checkCancelled()
            do {
                offset = try await sendChunk(to: location, from: handle, offset: offset, size: size, progress: progress)
                failures = 0
                progress?(Double(offset) / Double(size))
            } catch {
                var lastError = CloudflareError.wrap(error)
                // Resume loop: wait, ask the server where it got to, continue.
                while true {
                    guard Self.isResumable(lastError), failures < maxResumeAttempts else { throw lastError }
                    failures += 1
                    try await pause(attempt: failures)
                    do {
                        offset = try await currentOffset(of: location, size: size)
                        break
                    } catch { lastError = CloudflareError.wrap(error) }
                }
            }
        }
        return uid
    }

    private func createUpload(size: Int, name: String, requireSignedURLs: Bool) async throws -> (location: URL, uid: String) {
        let request = api.request("POST", api.streamURL, headers: [
            "Tus-Resumable": CloudflareTus.version,
            "Upload-Length": String(size),
            "Upload-Metadata": CloudflareTus.metadataHeader(name: name, requireSignedURLs: requireSignedURLs),
        ])
        let (data, response) = try await api.send(request)
        try CloudflareAPI.check(data, response, capability: .stream)
        // The UID comes from `stream-media-id`; `Location` is the upload URL, not the video.
        guard let uid = response.value(forHTTPHeaderField: "stream-media-id"), !uid.isEmpty else {
            throw CloudflareError.invalidResponse("the upload response had no stream-media-id")
        }
        guard let header = response.value(forHTTPHeaderField: "Location"),
              let location = URL(string: header, relativeTo: request.url)?.absoluteURL else {
            throw CloudflareError.invalidResponse("the upload response had no Location")
        }
        return (location, uid)
    }

    /// PATCHes one chunk starting at `offset`; returns the server's new offset.
    private func sendChunk(to location: URL, from handle: FileHandle, offset: Int, size: Int,
                           progress: (@Sendable (Double) -> Void)?) async throws -> Int {
        let chunk: Data
        do {
            try handle.seek(toOffset: UInt64(offset))
            chunk = try handle.read(upToCount: min(chunkSize, size - offset)) ?? Data()
        } catch {
            throw CloudflareError.invalidFile("The file couldn't be read: \(error.localizedDescription)")
        }
        guard !chunk.isEmpty else { throw CloudflareError.invalidFile("The file changed while it was uploading.") }

        let request = api.request("PATCH", location, headers: [
            "Tus-Resumable": CloudflareTus.version,
            "Upload-Offset": String(offset),
            "Content-Type": "application/offset+octet-stream",
        ])
        let delegate = progress.map { CloudflareProgressDelegate(baseBytes: Int64(offset), totalBytes: Int64(size), report: $0) }
        let (data, response) = try await api.send(request, body: chunk, delegate: delegate)
        try CloudflareAPI.check(data, response, capability: .stream)
        let newOffset = CloudflareTus.offset(in: response) ?? offset + chunk.count
        guard newOffset <= size else { throw CloudflareError.invalidResponse("the server reported offset \(newOffset) past the file end") }
        return newOffset
    }

    private func currentOffset(of location: URL, size: Int) async throws -> Int {
        let request = api.request("HEAD", location, headers: ["Tus-Resumable": CloudflareTus.version])
        let (data, response) = try await api.send(request)
        try CloudflareAPI.check(data, response, capability: .stream)
        guard let offset = CloudflareTus.offset(in: response), offset <= size else {
            throw CloudflareError.invalidResponse("the server didn't report a usable Upload-Offset")
        }
        return offset
    }

    /// Network drops, 408/429/5xx and tus offset conflicts (409) can be resumed.
    private static func isResumable(_ error: CloudflareError) -> Bool {
        switch error {
        case .network: return true
        case .api(_, _, let status?): return status == 409 || CloudflareAPI.isTransient(status: status)
        default: return false
        }
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw CloudflareError.cancelled }
    }

    private func pause(attempt: Int) async throws {
        guard retryDelay > 0 else { return try Self.checkCancelled() }
        do { try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000)) }
        catch { throw CloudflareError.wrap(error) }
    }

    // MARK: Status / delete / captions

    func status(uid: String) async throws -> StreamStatus {
        let (data, response) = try await api.send(api.request("GET", try api.streamURL(uid: uid)))
        let wire = try CloudflareAPI.decodeResult(StreamStatus.Wire.self, data, response, capability: .stream)
        return StreamStatus(wire: wire, fallbackUID: uid)
    }

    func delete(uid: String) async throws {
        let (data, response) = try await api.send(api.request("DELETE", try api.streamURL(uid: uid)))
        try CloudflareAPI.check(data, response, capability: .stream)
    }

    /// Adds (or replaces) a caption track from a WebVTT file (10 MB max).
    @concurrent
    func putCaptions(uid: String, language: String, vttFileURL: URL) async throws {
        let size = try CloudflareAPI.fileSize(of: vttFileURL)
        guard size <= Self.captionsSizeLimit else {
            throw CloudflareError.fileTooLarge(what: "The caption file", limitBytes: Self.captionsSizeLimit)
        }
        let url = try api.streamURL(uid: uid, path: "captions/\(try CloudflareAPI.pathComponent(language))")
        let boundary = "markclip-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("markclip_captions_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: body) }
        do {
            try CloudflareAPI.writeMultipartBody(to: body, boundary: boundary, fields: [], fileField: "file",
                fileURL: vttFileURL, filename: vttFileURL.lastPathComponent, mimeType: "text/vtt")
        } catch { throw CloudflareError.invalidFile("The caption file couldn't be prepared: \(error.localizedDescription)") }
        let request = api.request("PUT", url, headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
        let (data, response) = try await api.send(request, bodyFile: body)
        try CloudflareAPI.check(data, response, capability: .stream)
    }
}
#endif
