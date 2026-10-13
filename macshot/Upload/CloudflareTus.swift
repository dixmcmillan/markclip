#if !OFFLINE
import Foundation

/// Pure helpers for Cloudflare Stream's tus 1.0.0 resumable uploads.
nonisolated enum CloudflareTus {
    static let version = "1.0.0"

    /// Chunk bounds from the Stream docs: every chunk except the last must be a
    /// multiple of 256 KiB, between 5 MiB and 200 MiB (50 MiB recommended).
    static let chunkAlignment = 256 * 1024
    static let minimumChunkSize = 5 * 1024 * 1024
    static let recommendedChunkSize = 50 * 1024 * 1024
    static let maximumChunkSize = 200 * 1024 * 1024

    /// Rounds `requested` down to a multiple of 256 KiB inside
    /// `minimum...maximumChunkSize`. `minimum` is only lowered by tests.
    static func normalizedChunkSize(_ requested: Int, minimum: Int = minimumChunkSize) -> Int {
        let floor = max(chunkAlignment, (minimum / chunkAlignment) * chunkAlignment)
        let aligned = (min(max(requested, floor), maximumChunkSize) / chunkAlignment) * chunkAlignment
        return max(aligned, floor)
    }

    /// `Upload-Metadata`: comma-separated `key base64(value)`; a key without a
    /// value (`requiresignedurls`) means true.
    static func metadataHeader(name: String, requireSignedURLs: Bool) -> String {
        var parts = ["name \(Data(name.utf8).base64EncodedString())"]
        if requireSignedURLs { parts.append("requiresignedurls") }
        return parts.joined(separator: ",")
    }

    static func offset(in response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
#endif
