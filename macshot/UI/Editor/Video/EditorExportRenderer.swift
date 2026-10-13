import AVFoundation
import Foundation

/// The production `ExportRenderer`: drives `VideoEditorExporter` for MP4 and
/// GIF. Everything that actually encodes lives behind it, so `ExportRun`'s
/// orchestration is tested without ever starting an encoder.
@MainActor
final class EditorExportRenderer: ExportRenderer {
    private let exporter: VideoEditorExporter
    private let document: VideoEditorDocument

    init(exporter: VideoEditorExporter, document: VideoEditorDocument) {
        self.exporter = exporter
        self.document = document
    }

    var nativeSize: CGSize? { exporter.nativeCanvasSize }

    func captionsVTT() -> String? { exporter.captionsVTT() }

    func render(_ request: ExportRenderRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput {
        let settings = request.settings
        if settings.format == .gif {
            return request.fitGIF
                ? try await renderFittedGIF(settings, outputURL: request.outputURL, progress: progress)
                : try await renderGIF(settings, outputURL: request.outputURL, progress: progress)
        }
        // Nothing edited and the codec already matches: the source file is the
        // output. The lease keeps its working copy alive for the whole run.
        guard exporter.needsRender(settings) else {
            return ExportRenderOutput(fileURL: document.source.mediaURL, fitSummary: nil, retain: document.source.lease)
        }
        let job = try exporter.mp4Job(settings, outputURL: request.outputURL)
        try await job.export(to: request.outputURL) { progress($0) }
        return ExportRenderOutput(fileURL: request.outputURL, fitSummary: nil, retain: nil)
    }

    private func renderGIF(_ settings: VideoExportSettings, outputURL: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput {
        let request = try exporter.gifRequest(settings, outputURL: outputURL)
        // A private cancellation: `GIFExporter` ends it with `beginPublication`
        // when it commits, which must not freeze the run's own cancellation.
        // Task cancellation still reaches it.
        try await GIFExporter.export(request, cancellation: MediaExportCancellation(), progress: progress)
        return ExportRenderOutput(fileURL: outputURL, fitSummary: nil, retain: nil)
    }

    private func renderFittedGIF(_ settings: VideoExportSettings, outputURL: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput {
        guard let start = exporter.outputSize(settings), let native = exporter.nativeCanvasSize,
              native.width > 0, native.height > 0 else { throw VideoEditorExporter.ExportError.invalidSetup }
        let budget = GIFFitBudget(settings.gifFit)
        let plan = GIFFitPlanner.plan(duration: VideoRenderPlanner.outputDuration(project: document.project),
                                      startWidth: Int(start.width.rounded()), startHeight: Int(start.height.rounded()),
                                      startFPS: settings.gifFPS, budget: budget)
        guard !plan.isEmpty else { throw GIFFitError.cannotFit(attempts: [], budget: budget) }
        let longEdge = max(native.width, native.height)
        let exporter = exporter
        let outcome = try await GIFFitExporter.run(
            plan: plan, budget: budget, destination: outputURL,
            makeRequest: { rung, url in
                try await MainActor.run {
                    var rungSettings = settings
                    rungSettings.gifFPS = rung.fps
                    rungSettings.scale = min(1, max(0.01, CGFloat(rung.longEdge) / longEdge))
                    return try exporter.gifRequest(rungSettings, outputURL: url)
                }
            },
            cancellation: MediaExportCancellation(),
            progress: { attempt in
                progress((Double(attempt.attemptIndex) + attempt.fraction) / Double(max(1, attempt.attemptCount)))
            })
        // Only report a fit when it changed something.
        let summary = outcome.attempt > 1 ? "fit: " + outcome.rung.summary : nil
        return ExportRenderOutput(fileURL: outputURL, fitSummary: summary, retain: nil)
    }
}

extension GIFFitBudget {
    /// The planner budget for a preset's persisted GIF limits. The fps ladder
    /// is the spec's 15 / 12 / 10 / 8, cut at the preset's floor.
    init(_ settings: GIFFitSettings) {
        self.init()
        maxBytes = Int64(settings.maxBytes)
        maxTotalPixels = Int64((settings.maxTotalMegapixels * 1_000_000).rounded())
        minLongEdge = settings.minLongEdge
        let ladder = [15, 12, 10, 8].filter { $0 >= settings.minFPS }
        fpsLadder = ladder.isEmpty ? [settings.minFPS] : ladder
    }
}
