#if !OFFLINE
import Cocoa
import CryptoKit
import XCTest

/// Provider-neutral upload plumbing: the on-disk prepared body and the
/// transport's progress delegate. (Provider-specific request tests went with
/// the Drive/S3/imgbb uploaders in Phase 7; Cloudflare adds its own.)
final class UploadRequestTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = URLSession(configuration: .ephemeral)
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
    }

    func testPreparedBodyOutlivesChangedOrDeletedSourceAndCleansUp() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let bytes = Data(repeating: 0xAB, count: 3 * UploadPayload.chunkSize + 19)
        try bytes.write(to: source)
        var prepared: PreparedUploadBody? = try await MediaExportIO.perform {
            XCTAssertFalse(Thread.isMainThread)
            return try PreparedUploadBody(payload: .file(source))
        }
        let bodyURL = try XCTUnwrap(prepared?.url)
        try Data("different".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: bodyURL), bytes)
        XCTAssertEqual(prepared?.byteCount, bytes.count)
        XCTAssertEqual(prepared?.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))
    }

    func testEachProgressDelegateRetainsItsOwnCallback() async {
        let first = expectation(description: "first progress")
        let second = expectation(description: "second progress")
        let a = UploadTransport.ProgressDelegate { value in XCTAssertEqual(value, 0.25); first.fulfill() }
        let b = UploadTransport.ProgressDelegate { value in XCTAssertEqual(value, 0.75); second.fulfill() }
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        a.urlSession(session, task: task, didSendBodyData: 25, totalBytesSent: 25, totalBytesExpectedToSend: 100)
        b.urlSession(session, task: task, didSendBodyData: 75, totalBytesSent: 75, totalBytesExpectedToSend: 100)
        await fulfillment(of: [first, second], timeout: 5)
    }

    func testFinishedProgressCannotOverwriteACompletedStatus() async {
        var delivered = false
        let delegate = UploadTransport.ProgressDelegate { _ in delivered = true }
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        delegate.urlSession(session, task: task, didSendBodyData: 10, totalBytesSent: 10, totalBytesExpectedToSend: 10)
        delegate.finish()
        // A FIFO main-queue barrier proves the queued callback was considered;
        // yielding alone could assert before the callback had a chance to run.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(delivered)
    }
}
#endif
