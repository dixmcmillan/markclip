#if !OFFLINE
import Foundation

/// Adapts the Cloudflare clients to the `ExportRemoteService` seam that
/// `ExportRun` and `ExportRemoteSync` use. Cancellation becomes
/// `CancellationError`; a 404 on delete is success and a 404 on status means
/// the video is gone.
nonisolated struct CloudflareExportService: ExportRemoteService {
    let stream: CloudflareStreamClient
    let images: CloudflareImagesClient

    init(stream: CloudflareStreamClient, images: CloudflareImagesClient) {
        self.stream = stream
        self.images = images
    }

    /// The service for the saved account, or nil when none is configured.
    @MainActor
    static func make(account: CloudflareAccount = .shared) -> CloudflareExportService? {
        guard let stream = try? account.streamClient(), let images = try? account.imagesClient() else { return nil }
        return CloudflareExportService(stream: stream, images: images)
    }

    func uploadStream(fileURL: URL, name: String, requireSignedURLs: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        do { return try await stream.upload(fileURL: fileURL, name: name, requireSignedURLs: requireSignedURLs, progress: progress) }
        catch { throw Self.translate(error) }
    }

    func uploadImage(fileURL: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        do { return try await images.upload(fileURL: fileURL, metadata: ["name": name], progress: progress).id }
        catch { throw Self.translate(error) }
    }

    func putCaptions(uid: String, language: String, vttFileURL: URL) async throws {
        do { try await stream.putCaptions(uid: uid, language: language, vttFileURL: vttFileURL) }
        catch { throw Self.translate(error) }
    }

    func streamStatus(uid: String) async throws -> ExportRemoteStatus {
        do {
            let status = try await stream.status(uid: uid)
            if status.isFailed {
                return .failed(status.errorReasonText ?? status.errorReasonCode ?? "")
            }
            if status.readyToStream || status.state == .ready { return .ready }
            return .processing(percent: status.percentComplete)
        } catch CloudflareError.api(_, _, let httpStatus?) where httpStatus == 404 {
            return .missing
        } catch {
            throw Self.translate(error)
        }
    }

    func deleteStream(uid: String) async throws {
        do { try await stream.delete(uid: uid) }
        catch CloudflareError.api(_, _, let httpStatus?) where httpStatus == 404 { return }
        catch { throw Self.translate(error) }
    }

    private static func translate(_ error: Error) -> Error {
        let mapped = CloudflareError.wrap(error)
        return mapped == .cancelled ? CancellationError() : mapped
    }
}
#endif
