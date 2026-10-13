#if !OFFLINE
import XCTest

final class CloudflareImagesClientTests: XCTestCase {
    private let credentials = CloudflareCredentials(accountID: "acct123", apiToken: "tok-secret")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cf-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        CloudflareFixtureProtocol.uninstall()
        try? FileManager.default.removeItem(at: directory)
    }

    private func client() -> CloudflareImagesClient {
        CloudflareImagesClient(credentials: credentials, session: CloudflareFixtureProtocol.makeSession())
    }
    private func writeImage(_ bytes: Int, name: String = "shot one.png") throws -> (URL, Data) {
        let data = cloudflareTestBytes(count: bytes)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    func testMultipartBodyHasFileBytesFilenameMetadataAndAuth() async throws {
        let (file, data) = try writeImage(200_000)
        CloudflareFixtureProtocol.install { _ in
            .envelope(["id": "img-1", "filename": "shot one.png", "requireSignedURLs": false,
                       "variants": ["https://imagedelivery.net/h/img-1/public", "https://imagedelivery.net/h/img-1/thumb"]])
        }

        let result = try await client().upload(fileURL: file, metadata: ["project": "demo", "kind": "frame"])

        XCTAssertEqual(result.id, "img-1")
        XCTAssertEqual(result.variants.map(\.absoluteString),
                       ["https://imagedelivery.net/h/img-1/public", "https://imagedelivery.net/h/img-1/thumb"])
        let request = try XCTUnwrap(CloudflareFixtureProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/acct123/images/v1")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok-secret")
        let contentType = try XCTUnwrap(request.header("Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

        let body = request.body
        XCTAssertNotNil(body.range(of: data), "file bytes must be in the body verbatim")
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"shot one.png\""))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
        XCTAssertTrue(text.contains("name=\"metadata\"\r\n\r\n{\"kind\":\"frame\",\"project\":\"demo\"}"))
        XCTAssertFalse(text.contains("requireSignedURLs"))
        XCTAssertTrue(body.suffix(boundary.utf8.count + 8).elementsEqual(Data("\r\n--\(boundary)--\r\n".utf8).suffix(boundary.utf8.count + 8)))
    }

    func testRequireSignedURLsField() async throws {
        let (file, _) = try writeImage(100)
        CloudflareFixtureProtocol.install { _ in .envelope(["id": "i", "variants": [String]()]) }
        let result = try await client().upload(fileURL: file, requireSignedURLs: true)
        let body = String(decoding: try XCTUnwrap(CloudflareFixtureProtocol.requests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"requireSignedURLs\"\r\n\r\ntrue"))
        XCTAssertTrue(result.requireSignedURLs)
        XCTAssertTrue(result.variants.isEmpty)
    }

    func testOversizeFileIsRejectedLocallyWithoutARequest() async throws {
        let (file, _) = try writeImage(10)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CloudflareImagesClient.maximumFileSize + 1))
        try handle.close()
        CloudflareFixtureProtocol.install { _ in .envelope([:]) }
        do {
            _ = try await client().upload(fileURL: file)
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? CloudflareError,
                           .fileTooLarge(what: "shot one.png", limitBytes: CloudflareImagesClient.maximumFileSize))
        }
        XCTAssertTrue(CloudflareFixtureProtocol.requests.isEmpty)
    }

    func testServer413MapsToFileTooLarge() async throws {
        let (file, _) = try writeImage(100)
        CloudflareFixtureProtocol.install { _ in .failure(413, code: 5455, message: "Image too large") }
        do {
            _ = try await client().upload(fileURL: file)
            XCTFail("should have failed")
        } catch {
            guard case .fileTooLarge = error as? CloudflareError else { return XCTFail("\(error)") }
        }
    }

    func testAuthAndPermissionErrors() async throws {
        let (file, _) = try writeImage(100)
        CloudflareFixtureProtocol.install { _ in .failure(401, code: 1000, message: "Invalid API Token") }
        do { _ = try await client().upload(fileURL: file); XCTFail() }
        catch { XCTAssertEqual(error as? CloudflareError, .authFailed) }

        CloudflareFixtureProtocol.install { _ in .failure(403, code: 10000, message: "Authentication error") }
        do { _ = try await client().upload(fileURL: file); XCTFail() }
        catch { XCTAssertEqual(error as? CloudflareError, .permissionMissing(capability: "Cloudflare Images")) }
    }

    func testTemporaryBodyIsRemovedAfterUpload() async throws {
        let (file, _) = try writeImage(100)
        CloudflareFixtureProtocol.install { _ in .envelope(["id": "i"]) }
        let before = leftovers()
        _ = try await client().upload(fileURL: file)
        XCTAssertEqual(leftovers(), before)
    }
    private func leftovers() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("markclip_images_") })
    }
}
#endif
