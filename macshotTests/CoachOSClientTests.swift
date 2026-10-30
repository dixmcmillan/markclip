#if !OFFLINE
import CryptoKit
import XCTest

/// In-memory Coach OS plus Stream's tus endpoint, following the contract in
/// trainwithdixon `src/lib/mediaStreamWorkflow.ts`: a create replays by
/// `commandKey` (200, no `uploadUrl`), each upload attempt issues a new tus
/// URL, and every reconcile with a new key checks Stream again.
private final class FakeCoachOS: @unchecked Sendable {
    static let base = "https://coachos.example.ts.net"
    static let reservationID = "media-upload-reservation:5a1e"

    private let lock = NSLock()
    private var createdKeys: [String] = []
    private var _createBodies: [[String: Any]] = []
    private var _attemptKeys: [String] = []
    private var _reconcileKeys: [String] = []
    private var _urls: [String] = []
    private var received: [String: Data] = [:]
    private var gone: Set<String> = []
    /// Per PATCH: nil = ok, n = keep n bytes then drop the connection.
    var patchFailures: [Int?] = []
    /// The first create is recorded, then its reply is lost.
    var loseFirstCreateReply = false
    /// URLs that answer 404 from their first PATCH on (expired).
    var expireURLsOnFirstPatch: Set<Int> = []
    var reconcileReplies: [CloudflareFixtureProtocol.Reply] = []

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var createBodies: [[String: Any]] { locked { _createBodies } }
    var reservationsCreated: Int { locked { createdKeys.count } }
    var attemptKeys: [String] { locked { _attemptKeys } }
    var reconcileKeys: [String] { locked { _reconcileKeys } }
    var urls: [String] { locked { _urls } }
    func bytes(at index: Int) -> Data { locked { received[_urls[index]] ?? Data() } }

    private func reservation(status: String = "awaiting-upload") -> [String: Any] {
        ["id": Self.reservationID, "stableId": "media-asset:1", "provider": "cloudflare-stream",
         "providerAssetId": "uid-\(_urls.count)", "status": status]
    }

    private func issueURL() -> String {
        let url = "https://upload.cloudflarestream.com/tus/attempt-\(_urls.count + 1)?tusv2=true"
        _urls.append(url)
        received[url] = Data()
        return url
    }

    func handle(_ r: CloudflareFixtureProtocol.Recorded) throws -> CloudflareFixtureProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        let url = r.request.url?.absoluteString ?? ""
        if url.hasPrefix(Self.base) {
            let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            let key = json["commandKey"] as? String ?? ""
            if r.path == "/api/media-stream-upload-reservations" {
                _createBodies.append(json)
                if createdKeys.contains(key) {
                    return .json(200, ["reservation": reservation(), "recordedOutcome": true, "resumeRequired": true])
                }
                createdKeys.append(key)
                let upload = issueURL()
                if loseFirstCreateReply { loseFirstCreateReply = false; throw URLError(.networkConnectionLost) }
                return .json(201, ["reservation": reservation(), "uploadUrl": upload, "recordedOutcome": false])
            }
            if r.path == "/api/media-stream-upload-reservations/\(Self.reservationID)/upload-attempts" {
                _attemptKeys.append(key)
                return .json(201, ["reservation": reservation(status: "uploading"), "uploadUrl": issueURL(), "recordedOutcome": false])
            }
            if r.path == "/api/media-stream-upload-reservations/\(Self.reservationID)/reconcile" {
                _reconcileKeys.append(key)
                return reconcileReplies.isEmpty
                    ? .json(200, ["reservation": reservation(status: "verified"), "processingState": "ready", "recordedOutcome": false])
                    : reconcileReplies.removeFirst()
            }
            return .json(404, ["error": "not found"])
        }
        guard let index = _urls.firstIndex(of: url) else { return .init(status: 404) }
        switch r.method {
        case "HEAD":
            if gone.contains(url) { return .init(status: 404) }
            return .init(status: 200, headers: ["Upload-Offset": String(received[url]!.count), "Tus-Resumable": "1.0.0"])
        case "PATCH":
            if expireURLsOnFirstPatch.contains(index) { gone.insert(url) }
            if gone.contains(url) { return .init(status: 404) }
            let offset = Int(r.header("Upload-Offset") ?? "") ?? -1
            guard offset == received[url]!.count else { return .init(status: 409) }
            let plan = patchFailures.isEmpty ? nil : patchFailures.removeFirst()
            if let keep = plan {
                received[url]!.append(r.body.prefix(keep))
                throw URLError(.networkConnectionLost)
            }
            received[url]!.append(r.body)
            return .init(status: 204, headers: ["Upload-Offset": String(received[url]!.count), "Tus-Resumable": "1.0.0"])
        default:
            return .init(status: 405)
        }
    }
}

final class CoachOSClientTests: XCTestCase {
    private let kib = 1024
    private var directory: URL!
    private var server: FakeCoachOS!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("coach-os-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeCoachOS()
        CloudflareFixtureProtocol.install { [server] in try server!.handle($0) }
    }
    override func tearDownWithError() throws {
        CloudflareFixtureProtocol.uninstall()
        try? FileManager.default.removeItem(at: directory)
    }

    private func client() -> CoachOSClient {
        CoachOSClient(baseURL: URL(string: FakeCoachOS.base)!, session: CloudflareFixtureProtocol.makeSession(),
                      chunkSize: 256 * kib, minimumChunkSize: 256 * kib, retryDelay: 0)
    }

    private func writeFile(_ bytes: Int, name: String = "Ankle Taps.mp4") throws -> (URL, Data) {
        let data = cloudflareTestBytes(count: bytes)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    // MARK: Upload

    func testReservesThenUploadsWithTusAndNoCredentials() async throws {
        let (file, data) = try writeFile(600 * kib)
        let id = try await client().upload(fileURL: file, title: "Ankle Taps in Modified Hollow Position", durationSeconds: 12.5)

        XCTAssertEqual(id, FakeCoachOS.reservationID)
        XCTAssertEqual(server.reservationsCreated, 1)
        let body = try XCTUnwrap(server.createBodies.first)
        XCTAssertTrue((body["commandKey"] as? String)?.hasPrefix("command:markclip-reserve-stream:") == true)
        XCTAssertEqual(body["filename"] as? String, "Ankle Taps.mp4")
        XCTAssertEqual(body["contentType"] as? String, "video/mp4")
        XCTAssertEqual(body["sizeBytes"] as? Int, data.count)
        XCTAssertEqual(body["durationSeconds"] as? Double, 12.5)
        XCTAssertEqual(body["title"] as? String, "Ankle Taps in Modified Hollow Position")
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(body["contentFingerprint"] as? String, "sha256:" + hex)
        XCTAssertEqual(Set(body.keys), ["commandKey", "filename", "contentType", "sizeBytes", "durationSeconds",
                                        "title", "contentFingerprint"], "Coach OS rejects unknown keys")

        let post = try XCTUnwrap(CloudflareFixtureProtocol.requests("POST").first)
        XCTAssertEqual(post.header("Content-Type"), "application/json")
        XCTAssertEqual(post.header("Origin"), FakeCoachOS.base)
        let patches = CloudflareFixtureProtocol.requests("PATCH")
        XCTAssertEqual(patches.count, 3)
        for patch in patches {
            XCTAssertEqual(patch.request.url?.absoluteString, server.urls[0])
            XCTAssertEqual(patch.header("Tus-Resumable"), "1.0.0")
            XCTAssertEqual(patch.header("Content-Type"), "application/offset+octet-stream")
        }
        for request in CloudflareFixtureProtocol.requests {
            XCTAssertNil(request.header("Authorization"), "No Cloudflare or TrainWithDixon credential is ever sent")
            XCTAssertNil(request.header("CF-Access-Client-Secret"))
        }
        XCTAssertEqual(server.bytes(at: 0), data)
        XCTAssertTrue(server.attemptKeys.isEmpty)
    }

    func testDroppedConnectionResumesOnTheSameURLAndReservation() async throws {
        let (file, data) = try writeFile(600 * kib)
        server.patchFailures = [nil, 100 * kib]
        _ = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)

        XCTAssertEqual(server.bytes(at: 0), data)
        XCTAssertEqual(server.reservationsCreated, 1)
        XCTAssertEqual(server.urls.count, 1, "A resume never asks for a new upload")
        XCTAssertEqual(CloudflareFixtureProtocol.requests("HEAD").count, 1)
    }

    func testALongOutageKeepsResumingTheSameReservation() async throws {
        let (file, data) = try writeFile(600 * kib)
        server.patchFailures = [nil, 0, 0, 0, 0, 0, 0, 0]   // seven drops in a row on one chunk
        _ = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)

        XCTAssertEqual(server.bytes(at: 0), data)
        XCTAssertEqual(server.reservationsCreated, 1)
        XCTAssertEqual(server.urls.count, 1)
    }

    func testExpiredURLRestartsThroughUploadAttemptsOnTheSameReservation() async throws {
        let (file, data) = try writeFile(600 * kib)
        server.expireURLsOnFirstPatch = [0]
        let id = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)

        XCTAssertEqual(id, FakeCoachOS.reservationID)
        XCTAssertEqual(server.reservationsCreated, 1)
        XCTAssertEqual(server.attemptKeys.count, 1)
        XCTAssertTrue(server.attemptKeys[0].hasPrefix("command:markclip-resume-stream:"))
        let attempt = try XCTUnwrap(CloudflareFixtureProtocol.requests("POST").first { $0.path.hasSuffix("/upload-attempts") })
        XCTAssertTrue(attempt.request.url?.absoluteString.contains("media-upload-reservation%3A5a1e") == true,
                      "The id is encoded like encodeURIComponent")
        XCTAssertEqual(server.bytes(at: 1), data, "The new attempt uploads the whole file from 0")
    }

    func testRepeatedlyExpiringURLsGiveUpAfterTheAttemptLimit() async throws {
        let (file, _) = try writeFile(300 * kib)
        server.expireURLsOnFirstPatch = [0, 1, 2, 3]
        do {
            _ = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)
            XCTFail("expected a failure")
        } catch let error as CoachOSError {
            XCTAssertEqual(error, .server(status: 404, message: HTTPURLResponse.localizedString(forStatusCode: 404)))
        }
        XCTAssertEqual(server.attemptKeys.count, 2)
        XCTAssertEqual(server.reservationsCreated, 1)
    }

    func testLostCreateReplyIsRetriedWithTheSameKeyAndNeverMakesASecondReservation() async throws {
        let (file, data) = try writeFile(300 * kib)
        server.loseFirstCreateReply = true
        let id = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)

        XCTAssertEqual(id, FakeCoachOS.reservationID)
        let keys = server.createBodies.compactMap { $0["commandKey"] as? String }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1], "A retry of the same intent reuses its command key")
        XCTAssertEqual(server.reservationsCreated, 1)
        XCTAssertEqual(server.attemptKeys.count, 1, "The replay has no URL, so a fresh attempt supplies one")
        XCTAssertEqual(server.bytes(at: 1), data)
    }

    func testRejectedReservationSurfacesCoachOSMessageWithoutRetrying() async throws {
        let (file, _) = try writeFile(10 * kib)
        CloudflareFixtureProtocol.install { _ in .json(413, ["error": "Videos must be 2 GB or smaller", "recordedOutcome": true]) }
        do {
            _ = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)
            XCTFail("expected a failure")
        } catch let error as CoachOSError {
            XCTAssertEqual(error, .server(status: 413, message: "Videos must be 2 GB or smaller"))
            XCTAssertEqual(error.localizedDescription, "Coach OS error 413: Videos must be 2 GB or smaller")
        }
        XCTAssertEqual(CloudflareFixtureProtocol.requests.count, 1)
    }

    func testUnsupportedExtensionIsRefusedLocally() async throws {
        let (file, _) = try writeFile(10 * kib, name: "loop.gif")
        do {
            _ = try await client().upload(fileURL: file, title: "Clip", durationSeconds: nil)
            XCTFail("expected a failure")
        } catch CoachOSError.invalidFile {}
        XCTAssertTrue(CloudflareFixtureProtocol.requests.isEmpty)
    }

    // MARK: Reconcile

    func testEachReconcileIsANewCommand() async throws {
        server.reconcileReplies = [
            .json(200, ["reservation": ["id": FakeCoachOS.reservationID, "status": "processing"],
                        "processingState": "processing", "progressPercent": 40, "recordedOutcome": false]),
        ]
        let first = try await client().reconcile(reservationID: FakeCoachOS.reservationID)
        let second = try await client().reconcile(reservationID: FakeCoachOS.reservationID)
        XCTAssertEqual(first, .processing(percent: 40))
        XCTAssertEqual(second, .ready)
        XCTAssertEqual(Set(server.reconcileKeys).count, 2)
    }

    func testExportServiceMapsReconcileOutcomes() async throws {
        let service = CoachOSExportService(client: client())
        server.reconcileReplies = [
            .json(422, ["error": "Stream could not process the video", "recordedOutcome": true]),
            .json(404, ["error": "Stream Upload Reservation not found", "recordedOutcome": false]),
            .json(503, ["error": "Production Media Catalogue is unavailable"]),
        ]
        let failed = try await service.uploadStatus(reservationID: FakeCoachOS.reservationID)
        XCTAssertEqual(failed, .failed("Stream could not process the video"))
        let missing = try await service.uploadStatus(reservationID: FakeCoachOS.reservationID)
        XCTAssertEqual(missing, .missing)
        do {
            _ = try await service.uploadStatus(reservationID: FakeCoachOS.reservationID)
            XCTFail("a 503 is retried by the next poll, not recorded as a failure")
        } catch {}
    }

    // MARK: Settings

    func testBaseURLMustBeABareHTTPOrigin() {
        XCTAssertEqual(CoachOSSettings.normalized(" https://coachos.example.ts.net/ ")?.absoluteString,
                       "https://coachos.example.ts.net")
        XCTAssertEqual(CoachOSSettings.normalized("HTTP://localhost:4322")?.absoluteString, "http://localhost:4322")
        XCTAssertNil(CoachOSSettings.normalized("coachos.example.ts.net"))
        XCTAssertNil(CoachOSSettings.normalized("ftp://coachos.example.ts.net"))
        XCTAssertNil(CoachOSSettings.normalized("https://coachos.example.ts.net/media"))
        XCTAssertNil(CoachOSSettings.normalized("https://user:pw@coachos.example.ts.net"))
        XCTAssertNil(CoachOSSettings.normalized("https://coachos.example.ts.net?x=1"))
    }

    func testSavingKeepsOnlyTheAddress() throws {
        let suite = "coach-os-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            XCTAssertNil(CoachOSExportService.make(defaults: defaults), "No address, no destination")
            XCTAssertFalse(CoachOSSettings.save("not a url", defaults: defaults))
            XCTAssertNil(CoachOSSettings.baseURL(defaults: defaults))
            XCTAssertTrue(CoachOSSettings.save("https://coachos.example.ts.net/", defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: CoachOSSettings.baseURLKey), "https://coachos.example.ts.net")
            XCTAssertEqual(CoachOSSettings.mediaPageURL(defaults: defaults)?.absoluteString,
                           "https://coachos.example.ts.net/media")
            XCTAssertNotNil(CoachOSExportService.make(defaults: defaults))
            XCTAssertTrue(CoachOSSettings.save("", defaults: defaults))
            XCTAssertNil(CoachOSSettings.baseURL(defaults: defaults))
        }
    }
}
#endif
