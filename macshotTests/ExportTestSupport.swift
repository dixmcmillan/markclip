import XCTest

// Fakes for the export run, queue and sync tests. Nothing here encodes video or
// touches the network: the "render" writes a few bytes to a file.

/// Polls `condition` (main actor) until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Sleeps without waiting and remembers what it was asked to wait for.
final class InstantExportClock: ExportClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Double] = []
    var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return _sleeps }
    func sleep(seconds: Double) async throws {
        lock.lock(); _sleeps.append(seconds); lock.unlock()
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Writes `bytes` to a file instead of rendering. Can stall until cancelled.
@MainActor
final class FakeRenderer: ExportRenderer {
    var nativeSize: CGSize? = CGSize(width: 1920, height: 1080)
    var vtt: String?
    var bytes = Data("rendered".utf8)
    /// Block in `render` until the task is cancelled (or `release()`).
    var stalls = false
    var failure: Error?
    var fitSummary: String?
    /// Returns this existing file instead of writing one (a direct source copy).
    var directFile: URL?
    private(set) var requests: [ExportRenderRequest] = []
    private var released = false

    func release() { released = true }

    func captionsVTT() -> String? { vtt }

    func render(_ request: ExportRenderRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput {
        requests.append(request)
        progress(0.25)
        while stalls && !released {
            try await Task.sleep(nanoseconds: 5_000_000)   // throws CancellationError when cancelled
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        progress(1)
        if let directFile { return ExportRenderOutput(fileURL: directFile, fitSummary: nil, retain: nil) }
        try bytes.write(to: request.outputURL)
        return ExportRenderOutput(fileURL: request.outputURL, fitSummary: fitSummary, retain: nil)
    }
}

/// A scripted Cloudflare. Records every call, in order.
final class FakeRemote: ExportRemoteService, @unchecked Sendable {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _uploadedBytes: [Data] = []
    private var _uploadedPaths: [String] = []
    private var _uploadNames: [String] = []
    private var _signed: [Bool] = []
    private var _statuses: [String: [ExportRemoteStatus]] = [:]
    private var _statusError: Error?
    private var _statusCalls = 0
    private var _deleteFailures = 0
    private var _uids: [String]
    private var _uploadFailure: Error?
    private var _captionsFailure: Error?
    private var _stallUpload = false
    private var _stallCaptions = false

    init(uids: [String] = ["uid-1", "uid-2", "uid-3"]) { _uids = uids }

    private func with<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var calls: [String] { with { _calls } }
    var uploadedBytes: [Data] { with { _uploadedBytes } }
    var uploadedPaths: [String] { with { _uploadedPaths } }
    var uploadNames: [String] { with { _uploadNames } }
    var signedFlags: [Bool] { with { _signed } }
    var statusCallCount: Int { with { _statusCalls } }

    func script(statuses: [ExportRemoteStatus], for uid: String) { with { _statuses[uid] = statuses } }
    func failUpload(_ error: Error?) { with { _uploadFailure = error } }
    func failCaptions(_ error: Error?) { with { _captionsFailure = error } }
    func failStatus(_ error: Error?) { with { _statusError = error } }
    func failNextDeletes(_ count: Int) { with { _deleteFailures = count } }
    func stallUpload(_ stall: Bool) { with { _stallUpload = stall } }
    func stallCaptions(_ stall: Bool) { with { _stallCaptions = stall } }

    private func record(_ call: String) { with { _calls.append(call) } }

    func uploadStream(fileURL: URL, name: String, requireSignedURLs: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        record("uploadStream")
        with {
            _uploadedPaths.append(fileURL.path)
            _uploadedBytes.append((try? Data(contentsOf: fileURL)) ?? Data())
            _uploadNames.append(name)
            _signed.append(requireSignedURLs)
        }
        progress(0.5)
        while with({ _stallUpload }) { try await Task.sleep(nanoseconds: 5_000_000) }
        if let failure = with({ _uploadFailure }) { throw failure }
        progress(1)
        return with { _uids.isEmpty ? "uid-extra" : _uids.removeFirst() }
    }

    func uploadImage(fileURL: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        record("uploadImage")
        with {
            _uploadedPaths.append(fileURL.path)
            _uploadedBytes.append((try? Data(contentsOf: fileURL)) ?? Data())
            _uploadNames.append(name)
        }
        while with({ _stallUpload }) { try await Task.sleep(nanoseconds: 5_000_000) }
        if let failure = with({ _uploadFailure }) { throw failure }
        return "image-1"
    }

    func putCaptions(uid: String, language: String, vttFileURL: URL) async throws {
        record("putCaptions:\(uid):\(language):\((try? String(contentsOf: vttFileURL, encoding: .utf8)) ?? "")")
        while with({ _stallCaptions }) { try await Task.sleep(nanoseconds: 5_000_000) }
        if let failure = with({ _captionsFailure }) { throw failure }
    }

    private var _holdStatus = false
    /// While true, status calls wait before answering.
    func holdStatus(_ hold: Bool) { with { _holdStatus = hold } }

    func streamStatus(uid: String) async throws -> ExportRemoteStatus {
        record("status:\(uid)")
        let (error, status): (Error?, ExportRemoteStatus) = with {
            _statusCalls += 1
            if let error = _statusError { return (error, .ready) }
            var queue = _statuses[uid] ?? [.ready]
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            _statuses[uid] = queue
            return (nil, next)
        }
        while with({ _holdStatus }) { try await Task.sleep(nanoseconds: 5_000_000) }
        if let error { throw error }
        return status
    }

    func deleteStream(uid: String) async throws {
        record("delete:\(uid)")
        let fail = with { () -> Bool in
            guard _deleteFailures > 0 else { return false }
            _deleteFailures -= 1
            return true
        }
        if fail { throw Failure(message: "delete failed") }
    }
}

/// TrainWithDixon (Coach OS) over a `FakeRemote`: uploads and status checks
/// show up in `remote.calls` as `uploadStream` and `status:<reservation id>`,
/// and use its scripted statuses and failures.
final class FakeManagedRemote: ExportManagedUploadService, @unchecked Sendable {
    let remote: FakeRemote
    private let lock = NSLock()
    private var _titles: [String] = []
    private var _ids: [String]

    init(remote: FakeRemote = FakeRemote(), ids: [String] = ["media-upload-reservation:1", "media-upload-reservation:2"]) {
        self.remote = remote
        _ids = ids
    }

    var titles: [String] { lock.lock(); defer { lock.unlock() }; return _titles }

    func uploadVideo(fileURL: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        lock.lock(); _titles.append(title); lock.unlock()
        _ = try await remote.uploadStream(fileURL: fileURL, name: title, requireSignedURLs: true, progress: progress)
        lock.lock(); defer { lock.unlock() }
        return _ids.isEmpty ? "media-upload-reservation:extra" : _ids.removeFirst()
    }

    func uploadStatus(reservationID: String) async throws -> ExportRemoteStatus {
        try await remote.streamStatus(uid: reservationID)
    }
}
