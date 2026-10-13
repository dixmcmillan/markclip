#if !OFFLINE
import XCTest

/// In-memory tus server: validates offsets like the real one and can drop the
/// connection part-way through a PATCH.
private final class FakeTusServer: @unchecked Sendable {
    static let uid = "5f1c0de0c0ffee"
    static let upload = "https://upload.cloudflarestream.com/tus/session-1"

    private let lock = NSLock()
    private var _received = Data()
    private var _failures: [Int?] = []   // per PATCH: nil = ok, n = keep n bytes then drop the connection
    private var _patchOffsets: [Int] = []
    private var _patchLengths: [Int] = []

    init(failures: [Int?] = []) { _failures = failures }

    var received: Data { lock.lock(); defer { lock.unlock() }; return _received }
    var patchOffsets: [Int] { lock.lock(); defer { lock.unlock() }; return _patchOffsets }
    var patchLengths: [Int] { lock.lock(); defer { lock.unlock() }; return _patchLengths }

    func handle(_ r: CloudflareFixtureProtocol.Recorded) throws -> CloudflareFixtureProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        switch r.method {
        case "POST":
            return .init(status: 201, headers: ["Location": Self.upload, "stream-media-id": Self.uid,
                                                "Tus-Resumable": "1.0.0"])
        case "HEAD":
            return .init(status: 200, headers: ["Upload-Offset": String(_received.count), "Tus-Resumable": "1.0.0"])
        case "PATCH":
            let offset = Int(r.header("Upload-Offset") ?? "") ?? -1
            _patchOffsets.append(offset)
            _patchLengths.append(r.body.count)
            guard offset == _received.count else {
                return .failure(409, code: 10409, message: "offset mismatch")
            }
            let plan = _failures.isEmpty ? nil : _failures.removeFirst()
            if let keep = plan {
                _received.append(r.body.prefix(keep))
                throw URLError(.networkConnectionLost)
            }
            _received.append(r.body)
            return .init(status: 204, headers: ["Upload-Offset": String(_received.count), "Tus-Resumable": "1.0.0"])
        default:
            return .failure(405, code: 1, message: "unexpected \(r.method)")
        }
    }
}

final class CloudflareStreamClientTests: XCTestCase {
    private let credentials = CloudflareCredentials(accountID: "acct123", apiToken: "tok-secret")
    private let kib = 1024
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cf-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        CloudflareFixtureProtocol.uninstall()
        try? FileManager.default.removeItem(at: directory)
    }

    private func client(chunk: Int = 256 * 1024, attempts: Int = 3) -> CloudflareStreamClient {
        CloudflareStreamClient(credentials: credentials, session: CloudflareFixtureProtocol.makeSession(),
                               chunkSize: chunk, minimumChunkSize: 256 * 1024,
                               maxResumeAttempts: attempts, retryDelay: 0)
    }
    private func writeFile(_ bytes: Int, name: String = "demo.mp4") throws -> (URL, Data) {
        let data = cloudflareTestBytes(count: bytes)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }
    private func serve(_ server: FakeTusServer) {
        CloudflareFixtureProtocol.install { try server.handle($0) }
    }

    // MARK: tus request shape

    func testCreateAndPatchRequestShapeAndUIDFromMediaIDHeader() async throws {
        let (file, data) = try writeFile(300 * kib)
        let server = FakeTusServer()
        serve(server)

        let uid = try await client().upload(fileURL: file, name: "Demo clip.mp4", requireSignedURLs: true)

        XCTAssertEqual(uid, FakeTusServer.uid)   // from stream-media-id, not the Location path
        let post = try XCTUnwrap(CloudflareFixtureProtocol.requests("POST").first)
        XCTAssertEqual(post.request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/acct123/stream")
        XCTAssertEqual(post.header("Authorization"), "Bearer tok-secret")
        XCTAssertEqual(post.header("Tus-Resumable"), "1.0.0")
        XCTAssertEqual(post.header("Upload-Length"), String(data.count))
        let expectedName = Data("Demo clip.mp4".utf8).base64EncodedString()
        XCTAssertEqual(post.header("Upload-Metadata"), "name \(expectedName),requiresignedurls")

        let patches = CloudflareFixtureProtocol.requests("PATCH")
        XCTAssertEqual(patches.count, 2)
        for patch in patches {
            XCTAssertEqual(patch.request.url?.absoluteString, FakeTusServer.upload)
            XCTAssertEqual(patch.header("Tus-Resumable"), "1.0.0")
            XCTAssertEqual(patch.header("Content-Type"), "application/offset+octet-stream")
            XCTAssertEqual(patch.header("Authorization"), "Bearer tok-secret")
        }
        XCTAssertEqual(patches.map { $0.header("Upload-Offset") }, ["0", String(256 * kib)])
        XCTAssertEqual(server.received, data)
    }

    func testMetadataOmitsSignedURLFlagByDefault() async throws {
        let (file, _) = try writeFile(10 * kib)
        serve(FakeTusServer())
        _ = try await client().upload(fileURL: file, name: "a")
        let post = try XCTUnwrap(CloudflareFixtureProtocol.requests("POST").first)
        XCTAssertEqual(post.header("Upload-Metadata"), "name \(Data("a".utf8).base64EncodedString())")
    }

    func testChunksAreMultiplesOf256KiBExceptTheLast() async throws {
        let (file, data) = try writeFile(1280 * kib + 777)
        let server = FakeTusServer()
        serve(server)
        var progress: [Double] = []
        let lock = NSLock()

        _ = try await client(chunk: 512 * kib).upload(fileURL: file, name: "x") { value in
            lock.lock(); progress.append(value); lock.unlock()
        }

        let lengths = server.patchLengths
        XCTAssertEqual(lengths, [512 * kib, 512 * kib, 256 * kib + 777])
        for length in lengths.dropLast() { XCTAssertEqual(length % (256 * kib), 0) }
        XCTAssertEqual(server.received, data)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
    }

    func testChunkSizeIsNormalizedToCloudflareRules() {
        XCTAssertEqual(CloudflareTus.normalizedChunkSize(50 * 1024 * 1024), 50 * 1024 * 1024)
        XCTAssertEqual(CloudflareTus.normalizedChunkSize(1), 5 * 1024 * 1024)
        XCTAssertEqual(CloudflareTus.normalizedChunkSize(5 * 1024 * 1024 + 300_000), 5 * 1024 * 1024 + 262_144)
        XCTAssertEqual(CloudflareTus.normalizedChunkSize(900 * 1024 * 1024), 200 * 1024 * 1024)
        XCTAssertEqual(CloudflareTus.normalizedChunkSize(700_000, minimum: 256 * 1024), 524_288)
        XCTAssertEqual(client(chunk: 10 * 1024 * 1024 + 5).chunkSize, 10 * 1024 * 1024)
    }

    // MARK: resume

    func testResumesFromHeadOffsetAfterMidPatchFailure() async throws {
        let (file, data) = try writeFile(2048 * kib)
        // Second PATCH is cut off after 512 KiB reached the server.
        let server = FakeTusServer(failures: [nil, 512 * kib])
        serve(server)

        let uid = try await client(chunk: 1024 * kib).upload(fileURL: file, name: "x")

        XCTAssertEqual(uid, FakeTusServer.uid)
        XCTAssertEqual(CloudflareFixtureProtocol.requests("HEAD").count, 1)
        let head = try XCTUnwrap(CloudflareFixtureProtocol.requests("HEAD").first)
        XCTAssertEqual(head.header("Tus-Resumable"), "1.0.0")
        XCTAssertEqual(head.request.url?.absoluteString, FakeTusServer.upload)
        XCTAssertEqual(server.patchOffsets, [0, 1024 * kib, 1536 * kib])
        XCTAssertEqual(server.patchLengths, [1024 * kib, 1024 * kib, 512 * kib])
        XCTAssertEqual(server.received, data)
    }

    func testGivesUpAfterBoundedResumeAttempts() async throws {
        let (file, _) = try writeFile(512 * kib)
        let server = FakeTusServer(failures: [0, 0, 0, 0, 0, 0])
        serve(server)

        do {
            _ = try await client(chunk: 256 * kib, attempts: 2).upload(fileURL: file, name: "x")
            XCTFail("should have failed")
        } catch let error as CloudflareError {
            guard case .network = error else { return XCTFail("expected network, got \(error)") }
        }
        XCTAssertEqual(CloudflareFixtureProtocol.requests("PATCH").count, 3)   // first try + 2 resumes
        XCTAssertEqual(CloudflareFixtureProtocol.requests("HEAD").count, 2)
    }

    func testResumeCounterResetsAfterProgress() async throws {
        let (file, data) = try writeFile(1024 * kib)
        // Each of the four chunks fails once (keeping nothing) and then succeeds; only 1 attempt allowed per run of failures.
        let server = FakeTusServer(failures: [0, nil, 0, nil, 0, nil, 0, nil])
        serve(server)
        _ = try await client(chunk: 256 * kib, attempts: 1).upload(fileURL: file, name: "x")
        XCTAssertEqual(server.received, data)
    }

    func testPermissionErrorOnPatchIsNotRetried() async throws {
        let (file, _) = try writeFile(64 * kib)
        CloudflareFixtureProtocol.install { r in
            if r.method == "POST" {
                return .init(status: 201, headers: ["Location": FakeTusServer.upload, "stream-media-id": "u"])
            }
            return .failure(403, code: 10000, message: "Authentication error")
        }
        do {
            _ = try await client().upload(fileURL: file, name: "x")
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? CloudflareError, .permissionMissing(capability: "Cloudflare Stream"))
        }
        XCTAssertEqual(CloudflareFixtureProtocol.requests("PATCH").count, 1)
        XCTAssertTrue(CloudflareFixtureProtocol.requests("HEAD").isEmpty)
    }

    // MARK: cancellation

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _task: Task<String, Error>?
        var task: Task<String, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return _task }
            set { lock.lock(); _task = newValue; lock.unlock() }
        }
    }

    func testCancellationStopsBeforeNextChunk() async throws {
        let (file, _) = try writeFile(1024 * kib)
        let server = FakeTusServer()
        serve(server)
        let box = TaskBox()
        let uploader = client(chunk: 256 * kib)

        let task = Task { [uploader] in
            try await uploader.upload(fileURL: file, name: "x") { value in
                if value >= 0.25 { box.task?.cancel() }   // after the first chunk lands
            }
        }
        box.task = task

        do {
            _ = try await task.value
            XCTFail("should have been cancelled")
        } catch {
            XCTAssertEqual(error as? CloudflareError, .cancelled)
        }
        XCTAssertEqual(CloudflareFixtureProtocol.requests("PATCH").count, 1)
    }

    // MARK: failures at creation

    func testMissingMediaIDHeaderIsAnInvalidResponse() async throws {
        let (file, _) = try writeFile(1024)
        CloudflareFixtureProtocol.install { _ in .init(status: 201, headers: ["Location": FakeTusServer.upload]) }
        do {
            _ = try await client().upload(fileURL: file, name: "x")
            XCTFail("should have failed")
        } catch {
            guard case .invalidResponse = error as? CloudflareError else { return XCTFail("\(error)") }
        }
    }

    func testEmptyAndMissingFilesAreRejectedBeforeAnyRequest() async throws {
        let empty = directory.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        serve(FakeTusServer())
        for url in [empty, directory.appendingPathComponent("missing.mp4")] {
            do {
                _ = try await client().upload(fileURL: url, name: "x")
                XCTFail("should have failed")
            } catch {
                guard case .invalidFile = error as? CloudflareError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(CloudflareFixtureProtocol.requests.isEmpty)
    }

    func testEnvelopeErrorsMapToCloudflareError() async throws {
        let cases: [(CloudflareFixtureProtocol.Reply, CloudflareError)] = [
            (.failure(400, code: 10005, message: "Bad things"), .api(code: 10005, message: "Bad things", status: 400)),
            (.failure(401, code: 1000, message: "Invalid API Token"), .authFailed),
            (.failure(403, code: 10000, message: "Authentication error"), .permissionMissing(capability: "Cloudflare Stream")),
            (.failure(403, code: 9109, message: "Invalid access token"), .authFailed),
            (.json(200, ["success": false, "errors": [["code": 7003, "message": "No route"]], "result": NSNull()]),
             .api(code: 7003, message: "No route", status: 200)),
            (.init(status: 502), .api(code: nil, message: "bad gateway", status: 502)),
        ]
        for (reply, expected) in cases {
            CloudflareFixtureProtocol.install { _ in reply }
            do {
                _ = try await client().status(uid: "abc")
                XCTFail("should have failed for \(expected)")
            } catch {
                XCTAssertEqual(error as? CloudflareError, expected)
            }
        }
    }

    func testErrorsHaveUserPresentableMessages() {
        let errors: [CloudflareError] = [.notConfigured, .authFailed, .tokenInactive(status: "expired"),
            .permissionMissing(capability: "Cloudflare Images"), .fileTooLarge(what: "a.png", limitBytes: 10_485_760),
            .api(code: 1, message: "boom", status: 500), .network("offline"), .cancelled]
        for error in errors { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertTrue(CloudflareError.fileTooLarge(what: "a.png", limitBytes: 10_485_760).localizedDescription.contains("10"))
        XCTAssertTrue(CloudflareError.api(code: 7003, message: "No route", status: 400).localizedDescription.contains("7003"))
    }

    // MARK: status / delete / captions

    func testStatusParsesStringPercentComplete() async throws {
        CloudflareFixtureProtocol.install { _ in
            .envelope(["uid": "abc", "readyToStream": false, "duration": -1,
                       "status": ["state": "inprogress", "pctComplete": "42.5"]])
        }
        let status = try await client().status(uid: "abc")
        XCTAssertEqual(status.state, .inProgress)
        XCTAssertEqual(status.percentComplete, 42.5)
        XCTAssertFalse(status.readyToStream)
        XCTAssertNil(status.durationSeconds)
        XCTAssertFalse(status.isFinished)
        let request = try XCTUnwrap(CloudflareFixtureProtocol.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/acct123/stream/abc")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok-secret")
    }

    func testStatusParsesNumericPercentCompleteAndReadyState() async throws {
        CloudflareFixtureProtocol.install { _ in
            .envelope(["uid": "abc", "readyToStream": true, "duration": 12.5,
                       "thumbnail": "https://cdn.example/t.jpg",
                       "playback": ["hls": "https://cdn.example/m.m3u8", "dash": "https://cdn.example/m.mpd"],
                       "status": ["state": "ready", "pctComplete": 100]])
        }
        let status = try await client().status(uid: "abc")
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.percentComplete, 100)
        XCTAssertTrue(status.readyToStream)
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.durationSeconds, 12.5)
        XCTAssertEqual(status.hlsURL?.absoluteString, "https://cdn.example/m.m3u8")
        XCTAssertEqual(status.dashURL?.absoluteString, "https://cdn.example/m.mpd")
        XCTAssertEqual(status.thumbnailURL?.absoluteString, "https://cdn.example/t.jpg")
    }

    func testStatusParsesErrorState() async throws {
        CloudflareFixtureProtocol.install { _ in
            .envelope(["uid": "abc", "readyToStream": false,
                       "status": ["state": "error", "errorReasonCode": "ERR_NON_VIDEO", "errorReasonText": "not a video"]])
        }
        let status = try await client().status(uid: "abc")
        XCTAssertTrue(status.isFailed)
        XCTAssertEqual(status.errorReasonCode, "ERR_NON_VIDEO")
        XCTAssertEqual(status.errorReasonText, "not a video")
    }

    func testDeleteRequestShape() async throws {
        CloudflareFixtureProtocol.install { _ in .envelope(NSNull()) }
        try await client().delete(uid: "abc")
        let request = try XCTUnwrap(CloudflareFixtureProtocol.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/client/v4/accounts/acct123/stream/abc")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok-secret")
    }

    func testDeleteAccepts204() async throws {
        CloudflareFixtureProtocol.install { _ in .init(status: 204) }
        try await client().delete(uid: "abc")
    }

    func testCaptionsPutIsMultipartWithFileField() async throws {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:02.000\nHello world\n"
        let url = directory.appendingPathComponent("en.vtt")
        try Data(vtt.utf8).write(to: url)
        CloudflareFixtureProtocol.install { _ in .envelope(["language": "en", "label": "English"]) }

        try await client().putCaptions(uid: "abc", language: "en", vttFileURL: url)

        let request = try XCTUnwrap(CloudflareFixtureProtocol.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/client/v4/accounts/acct123/stream/abc/captions/en")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok-secret")
        let contentType = try XCTUnwrap(request.header("Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"en.vtt\""))
        XCTAssertTrue(body.contains("Content-Type: text/vtt"))
        XCTAssertTrue(body.contains(vtt))
        XCTAssertTrue(body.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    func testCaptionsLanguageIsPathEscapedAndOversizeRejected() async throws {
        let url = directory.appendingPathComponent("big.vtt")
        try Data("WEBVTT".utf8).write(to: url)
        CloudflareFixtureProtocol.install { _ in .envelope([:]) }
        try await client().putCaptions(uid: "abc", language: "zh-Hant/../x", vttFileURL: url)
        XCTAssertEqual(CloudflareFixtureProtocol.requests.first?.request.url?.absoluteString,
                       "https://api.cloudflare.com/client/v4/accounts/acct123/stream/abc/captions/zh-Hant%2F..%2Fx")

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CloudflareStreamClient.captionsSizeLimit + 1))
        try handle.close()
        CloudflareFixtureProtocol.install { _ in .envelope([:]) }
        do {
            try await client().putCaptions(uid: "abc", language: "en", vttFileURL: url)
            XCTFail("should have failed")
        } catch {
            guard case .fileTooLarge = error as? CloudflareError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(CloudflareFixtureProtocol.requests.isEmpty)
    }
}
#endif
