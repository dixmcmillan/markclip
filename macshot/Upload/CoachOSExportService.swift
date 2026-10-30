#if !OFFLINE
import AVFoundation
import Foundation

/// Adapts `CoachOSClient` to the `ExportManagedUploadService` seam.
/// Cancellation becomes `CancellationError`; a reservation Coach OS no longer
/// knows (404) is `.missing`, and a rejected one (other 4xx) is `.failed`.
nonisolated struct CoachOSExportService: ExportManagedUploadService {
    let client: CoachOSClient

    /// The service for the saved Coach OS address, or nil when none is set.
    static func make(defaults: UserDefaults = .standard) -> CoachOSExportService? {
        guard let baseURL = CoachOSSettings.baseURL(defaults: defaults) else { return nil }
        return CoachOSExportService(client: CoachOSClient(baseURL: baseURL))
    }

    func uploadVideo(fileURL: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        // Lets Coach OS reject a video over its length limit before any bytes move.
        let duration = try? await AVURLAsset(url: fileURL).load(.duration).seconds
        do {
            return try await client.upload(fileURL: fileURL, title: title,
                                           durationSeconds: duration.flatMap { $0.isFinite ? $0 : nil },
                                           progress: progress)
        } catch { throw Self.translate(error) }
    }

    func uploadStatus(reservationID: String) async throws -> ExportRemoteStatus {
        do {
            switch try await client.reconcile(reservationID: reservationID) {
            case .ready: return .ready
            case .processing(let percent): return .processing(percent: percent)
            }
        } catch let error as CoachOSError {
            if case .server(404, _) = error { return .missing }
            if case .server(let status, let message) = error, (400..<500).contains(status), !error.isTransient {
                return .failed(message)
            }
            throw Self.translate(error)
        } catch {
            throw Self.translate(error)
        }
    }

    private static func translate(_ error: Error) -> Error {
        let mapped = CoachOSError.wrap(error)
        return mapped == .cancelled ? CancellationError() : mapped
    }
}
#endif
