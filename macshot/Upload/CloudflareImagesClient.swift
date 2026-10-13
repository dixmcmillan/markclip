#if !OFFLINE
import Foundation

/// What Cloudflare Images returns for an upload.
nonisolated struct ImagesResult: Sendable, Equatable {
    let id: String
    let filename: String?
    /// Delivery URLs, one per variant (the first is usually `public`).
    let variants: [URL]
    let requireSignedURLs: Bool
}

extension ImagesResult {
    fileprivate struct Wire: Decodable {
        var id: String?
        var filename: String?
        var variants: [String]?
        var requireSignedURLs: Bool?
    }
}

/// Cloudflare Images upload (`POST /images/v1`). The multipart body is built on
/// disk in 1 MiB steps and sent with `upload(fromFile:)`, so even a maximum
/// size image is never held as one `Data`.
nonisolated struct CloudflareImagesClient: Sendable {
    /// Documented per-image maximum.
    static let maximumFileSize = 10 * 1024 * 1024

    private let api: CloudflareAPI

    init(credentials: CloudflareCredentials, session: URLSession = CloudflareAPI.makeSession()) {
        api = CloudflareAPI(credentials: credentials, session: session)
    }

    /// - Parameters:
    ///   - metadata: optional string key/values stored with the image (sent as the JSON `metadata` field).
    ///   - progress: 0...1 from an arbitrary thread.
    @concurrent
    func upload(fileURL: URL, metadata: [String: String]? = nil, requireSignedURLs: Bool = false,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> ImagesResult {
        let size = try CloudflareAPI.fileSize(of: fileURL)
        guard size > 0 else { throw CloudflareError.invalidFile("\(fileURL.lastPathComponent) is empty.") }
        guard size <= Self.maximumFileSize else {
            throw CloudflareError.fileTooLarge(what: "\(fileURL.lastPathComponent)", limitBytes: Self.maximumFileSize)
        }

        var fields: [(name: String, value: String)] = []
        if let metadata, !metadata.isEmpty {
            let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            fields.append(("metadata", String(decoding: json, as: UTF8.self)))
        }
        if requireSignedURLs { fields.append(("requireSignedURLs", "true")) }

        let boundary = "markclip-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("markclip_images_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: body) }
        let bodySize: Int
        do {
            try CloudflareAPI.writeMultipartBody(to: body, boundary: boundary, fields: fields, fileField: "file",
                fileURL: fileURL, filename: fileURL.lastPathComponent, mimeType: CloudflareAPI.mimeType(for: fileURL))
            bodySize = try CloudflareAPI.fileSize(of: body)
        } catch let error as CloudflareError {
            throw error
        } catch {
            throw CloudflareError.invalidFile("\(fileURL.lastPathComponent) couldn't be prepared: \(error.localizedDescription)")
        }

        let request = api.request("POST", api.imagesURL,
                                  headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
        let delegate = progress.map { CloudflareProgressDelegate(totalBytes: Int64(bodySize), report: $0) }
        let (data, response) = try await api.send(request, bodyFile: body, delegate: delegate)
        let wire = try CloudflareAPI.decodeResult(ImagesResult.Wire.self, data, response, capability: .images,
            sizeLimit: ("\(fileURL.lastPathComponent)", Self.maximumFileSize))
        guard let id = wire.id, !id.isEmpty else { throw CloudflareError.invalidResponse("the image response had no id") }
        progress?(1)
        return ImagesResult(id: id, filename: wire.filename,
                            variants: (wire.variants ?? []).compactMap(URL.init(string:)),
                            requireSignedURLs: wire.requireSignedURLs ?? requireSignedURLs)
    }
}
#endif
