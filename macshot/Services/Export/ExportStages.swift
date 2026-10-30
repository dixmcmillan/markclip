import CoreGraphics
import Foundation

// The seams of an export run. `ExportRun` orchestrates; everything that
// encodes, uploads or waits sits behind one of these so the orchestration is
// unit-tested with fakes that write a few bytes (no video encoder runs in the
// local suite; see "Video encoder tests" in CLAUDE.md).

// MARK: - Stages and results

/// Where a run is. `Equatable`/`Sendable` so UI state can carry it.
nonisolated enum ExportStage: String, Sendable, Equatable {
    case preparing, rendering, publishing, uploading, captions

    /// Short user-facing label; the UI localizes with `L(...)`.
    var title: String {
        switch self {
        case .preparing: return "Preparing"
        case .rendering: return "Rendering"
        case .publishing: return "Saving"
        case .uploading: return "Uploading"
        case .captions: return "Adding captions"
        }
    }
}

/// Why a run failed, and at which stage.
nonisolated struct ExportRunFailure: Sendable, Equatable {
    let stage: ExportStage
    let message: String
}

nonisolated enum ExportRunError: LocalizedError, Equatable {
    /// A Stream/Images preset in the OFFLINE build.
    case networkDestinationUnavailable
    /// Stream/Images selected but no Cloudflare account is configured.
    case cloudflareNotConfigured
    /// TrainWithDixon selected but no Coach OS address is saved.
    case coachOSNotConfigured
    /// Images only takes GIFs; Stream only takes video.
    case formatMismatch(String)
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .networkDestinationUnavailable: return "Cloudflare uploads aren't available in the offline build."
        case .cloudflareNotConfigured: return "Cloudflare isn't set up yet. Add your account ID and API token in Settings."
        case .coachOSNotConfigured: return "TrainWithDixon isn't set up yet. Add the Coach OS address in Settings."
        case .formatMismatch(let detail): return detail
        case .folderUnavailable(let path): return "The export folder \(path) couldn't be created."
        }
    }
}

/// The result of one run, whatever happened. A failure after the local file was
/// published still reports `localFile`.
nonisolated struct ExportRunResult: Sendable, Equatable {
    let presetID: UUID
    let presetName: String
    /// The published local copy, when the preset saved one.
    var localFile: URL?
    /// The `.vtt` written beside it for soft captions.
    var captionsSidecar: URL?
    var remoteKind: ExportRemoteKind?
    /// Stream UID or Images id.
    var remoteID: String?
    /// What GIF auto-fit changed ("fit: 12 fps, 960 px"), when it changed anything.
    var fitSummary: String?
    /// Set when the run failed; earlier stages may still have succeeded.
    var failure: ExportRunFailure?
    /// The stage that was running when the user cancelled.
    var cancelledAt: ExportStage?
    /// Captions upload failed but the video upload succeeded.
    var captionsError: String?

    var succeeded: Bool { failure == nil && cancelledAt == nil }
    var wasCancelled: Bool { cancelledAt != nil }
}

// MARK: - Render stage

/// What a render produced.
nonisolated struct ExportRenderOutput: @unchecked Sendable {
    /// The finished file. Its extension names the published file.
    var fileURL: URL
    /// What GIF auto-fit changed, if anything.
    var fitSummary: String?
    /// Keeps the input alive until the run is done (source lease for a direct copy).
    var retain: AnyObject?
}

nonisolated struct ExportRenderRequest: Sendable {
    var settings: VideoExportSettings
    /// Where the render writes. The file does not exist yet.
    var outputURL: URL
    /// Run GIF auto-fit against the preset's `gifFit` limits (Images).
    var fitGIF: Bool
}

/// Turns the editor's project into a file. The real implementation drives
/// `VideoEditorExporter`; tests write a few bytes.
@MainActor
protocol ExportRenderer: AnyObject {
    /// Native canvas size, for resolving a preset's size cap.
    var nativeSize: CGSize? { get }
    /// The render. Must honor task cancellation.
    func render(_ request: ExportRenderRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput
    /// WebVTT for the soft caption track on the edited clock; nil when the
    /// project has no captions.
    func captionsVTT() -> String?
}

// MARK: - Remote stage

/// Stream's processing state as the run and the poller see it.
nonisolated enum ExportRemoteStatus: Sendable, Equatable {
    case processing(percent: Double?)
    case ready
    case failed(String)
    /// The video no longer exists (deleted in the dashboard).
    case missing
}

/// Cloudflare as the run sees it. `CloudflareExportService` (below the
/// `#if !OFFLINE` fence) is the only production implementation.
nonisolated protocol ExportRemoteService: Sendable {
    /// Uploads a video; returns the Stream UID.
    func uploadStream(fileURL: URL, name: String, requireSignedURLs: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// Uploads a GIF; returns the Images id.
    func uploadImage(fileURL: URL, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    func putCaptions(uid: String, language: String, vttFileURL: URL) async throws
    func streamStatus(uid: String) async throws -> ExportRemoteStatus
    /// Deleting a video that is already gone succeeds.
    func deleteStream(uid: String) async throws
}

/// TrainWithDixon's managed upload (through Coach OS) as the run sees it.
/// `CoachOSExportService` (below the `#if !OFFLINE` fence) is the only
/// production implementation.
nonisolated protocol ExportManagedUploadService: Sendable {
    /// Uploads a video; returns the Coach OS reservation id.
    func uploadVideo(fileURL: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// Where the upload is: processing until Coach OS has a ready, managed asset.
    func uploadStatus(reservationID: String) async throws -> ExportRemoteStatus
}

// MARK: - Clock

/// Injectable sleep, so polling tests don't wait five real seconds.
protocol ExportClock: Sendable {
    func sleep(seconds: Double) async throws
}

struct SystemExportClock: ExportClock {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Environment

/// Everything an `ExportRun` needs from the outside, in one value so the queue
/// can build runs and tests can fake the lot.
@MainActor
struct ExportEnvironment {
    /// Display name of the project (the source file's name without extension).
    /// Local files use its sanitized form; Stream gets it as the video name.
    var projectName: String
    var renderer: ExportRenderer
    var records: ExportRecordStore
    /// Nil when Cloudflare isn't usable (OFFLINE, or no account). Looked up
    /// per run so credentials entered later are picked up.
    var remote: () -> ExportRemoteService?
    /// Nil when TrainWithDixon isn't usable (OFFLINE, or no Coach OS address).
    var trainWithDixon: () -> ExportManagedUploadService? = { nil }
    /// Folder for the local copy of a Stream/Images preset with "also save
    /// locally". Defaults to the Archive preset's folder.
    var localFolderForUploads: () -> URL
    /// Called once a local copy has been published (Save As, a folder preset,
    /// or "also save locally"). The editor uses it to hand ownership of a
    /// disposable source file to the user when the copy replaced it.
    var localFilePublished: (URL) -> Void = { _ in }
    var coordinator: MediaExportCoordinator = .shared
    var clock: ExportClock = SystemExportClock()
    var offline: Bool = BuildVariant.isOffline
    var stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("markclip-export", isDirectory: true)
    var now: () -> Date = { Date() }
    var captionsLanguage: String = "en"
    /// Status polling cadence.
    var pollInterval: Double = 5
}

extension ExportEnvironment {
    /// The Archive built-in's folder (the user may have re-pointed it), else
    /// `~/Movies/Markclip Archive`.
    static func defaultLocalFolderForUploads(defaults: UserDefaults = .standard) -> URL {
        if let archive = ExportPresetStore.preset(id: ExportPresetStore.archiveID, defaults: defaults),
           let url = archive.destination.resolvedFolderURL() {
            return url
        }
        return URL(fileURLWithPath: ExportDestination.defaultArchivePath, isDirectory: true)
    }
}
