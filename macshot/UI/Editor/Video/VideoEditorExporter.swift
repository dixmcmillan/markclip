import AVFoundation

/// Export preferences. Persisted across sessions (existing keys).
struct VideoExportSettings: Equatable {
    enum Format: String { case mp4, gif }
    var format: Format = .mp4
    /// Output scale relative to the native canvas, 0 < scale ≤ 1.
    var scale: CGFloat = 1
    var quality: VideoQuality = .high
    var gifFPS: Int = 15

    static let scaleKey = "lastExportScale"
    static let qualityKey = "lastExportQuality"
    static let gifFPSKey = "gifExportFPS"
    static let formatKey = "videoEditorExportFormat"
    static let lastDirectoryKey = "lastExportDestinationDirectory"

    /// The folder Quick Export (⇧⌘E) writes to without prompting: wherever
    /// the last successful Save/Save As/Quick Export actually wrote. Sandbox
    /// is disabled in this fork (see CLAUDE.md), so a plain path is enough —
    /// no security-scoped bookmark needed.
    static func lastDirectory(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: lastDirectoryKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setLastDirectory(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: lastDirectoryKey)
    }

    static func load(defaults: UserDefaults = .standard) -> VideoExportSettings {
        var settings = VideoExportSettings()
        let scale = defaults.object(forKey: scaleKey) as? Double ?? 1
        settings.scale = scale.isFinite && scale > 0 && scale <= 1 ? CGFloat(scale) : 1
        if let raw = defaults.string(forKey: qualityKey), let quality = VideoQuality(rawValue: raw) {
            settings.quality = quality
        }
        let fps = defaults.integer(forKey: gifFPSKey)
        settings.gifFPS = fps == 0 ? 15 : min(30, max(5, fps))
        if let raw = defaults.string(forKey: formatKey), let format = Format(rawValue: raw) { settings.format = format }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(Double(scale), forKey: Self.scaleKey)
        defaults.set(quality.rawValue, forKey: Self.qualityKey)
        defaults.set(gifFPS, forKey: Self.gifFPSKey)
        defaults.set(format.rawValue, forKey: Self.formatKey)
    }
}

/// Builds export jobs from an immutable copy of the project, so edits made
/// while an export runs never leak into it.
@MainActor
final class VideoEditorExporter {
    enum ExportError: LocalizedError {
        case invalidSetup
        var errorDescription: String? { "The video could not be prepared for export." }
    }

    private let document: VideoEditorDocument

    init(document: VideoEditorDocument) {
        self.document = document
    }

    /// Whether saving must render (otherwise the source file is copied as is).
    func needsRender(_ settings: VideoExportSettings) -> Bool {
        let project = document.project
        return settings.format == .gif || settings.scale < 0.999 || settings.quality != .high
            || project.hasEdits || document.cursorIsEditable || document.cameraURL != nil
            || (document.overlaysAreEditable && document.hasKeystrokes)
    }

    /// Canvas size the export will have.
    func outputSize(_ settings: VideoExportSettings) -> CGSize? {
        VideoRenderPlanner(document: document).layout(for: document.project, scale: settings.scale)?.canvasSize
    }

    /// Native canvas size at scale 1.
    var nativeCanvasSize: CGSize? {
        VideoRenderPlanner(document: document).layout(for: document.project)?.canvasSize
    }

    private struct Prepared {
        let project: VideoProject
        let planner: VideoRenderPlanner
        let processed: VideoCompositionBuilder.Result
        let composition: AVMutableVideoComposition
    }

    private func prepare(_ settings: VideoExportSettings, includeAudio: Bool, frameDuration: CMTime? = nil) throws -> Prepared {
        guard let project = document.project.copy() else { throw ExportError.invalidSetup }
        // Exports render at full quality with their own caches.
        let planner = VideoRenderPlanner(document: document)
        let processed = try planner.processed(project: project, from: project.trimStart, to: project.trimEnd,
                                              includeAudio: includeAudio)
        var options = VideoRenderPlanner.Options()
        options.scale = settings.scale
        options.exactPointer = true
        let composition = try planner.videoComposition(project: project, processed: processed, options: options,
                                                       frameDuration: frameDuration)
        return Prepared(project: project, planner: planner, processed: processed, composition: composition)
    }

    func mp4Job(_ settings: VideoExportSettings, outputURL: URL) throws -> VideoExportJob {
        let includeAudio = !document.project.muted
        let prepared = try prepare(settings, includeAudio: includeAudio)
        let lease = document.source.lease
        if settings.quality == .high {
            guard let session = AVAssetExportSession(asset: prepared.processed.composition,
                                                     presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.invalidSetup
            }
            session.metadata = VideoFrameCadence.metadata(for: document.frameDuration)
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.videoComposition = prepared.composition
            if !includeAudio { session.audioMix = nil }
            return VideoExportJob(session: session, sourceLease: lease)
        }
        let canvas = prepared.composition.renderSize
        guard let plan = encodingPlan(settings, canvas: canvas, project: prepared.project) else {
            throw ExportError.invalidSetup
        }
        var request = VideoTranscoder.Request(
            asset: prepared.processed.composition, videoTrack: prepared.processed.videoTrack,
            audioTracks: includeAudio ? prepared.processed.audioTracks : [], composition: prepared.composition,
            timeRange: CMTimeRange(start: .zero, duration: prepared.processed.composition.duration),
            outputURL: outputURL, videoSettings: plan.outputSettings, decodedSize: nil,
            outputTransform: .identity, sourceFrameDuration: document.frameDuration)
        request.additionalVideoTracks = Self.additionalVideoTracks(prepared.processed)
        return VideoExportJob(request: request, sourceLease: lease)
    }

    func gifRequest(_ settings: VideoExportSettings, outputURL: URL) throws -> GIFExporter.Request {
        let cadence = CMTime(value: 1, timescale: CMTimeScale(min(30, max(5, settings.gifFPS))))
        let prepared = try prepare(settings, includeAudio: false, frameDuration: cadence)
        var request = GIFExporter.Request(asset: prepared.processed.composition, videoTrack: prepared.processed.videoTrack,
            composition: prepared.composition,
            timeRange: CMTimeRange(start: .zero, duration: prepared.processed.composition.duration),
            outputURL: outputURL, sourceLease: document.source.lease)
        request.additionalVideoTracks = Self.additionalVideoTracks(prepared.processed)
        return request
    }

    /// Every track beyond the main video track the custom compositor may
    /// fetch a source frame from (`request.sourceFrame(byTrackID:)`): the
    /// webcam and any placed video overlay. The manual reader path (medium/
    /// low MP4, GIF) must open all of them or those frames come back nil;
    /// `AVAssetExportSession`'s own pipeline (high-quality MP4) does this
    /// itself from `requiredSourceTrackIDs` and needs no help.
    private static func additionalVideoTracks(_ processed: VideoCompositionBuilder.Result) -> [AVAssetTrack] {
        var tracks: [AVAssetTrack] = []
        if let cameraTrack = processed.cameraTrack { tracks.append(cameraTrack) }
        for placement in processed.overlayPlacements.values {
            if let track = processed.composition.track(withTrackID: placement.trackID) { tracks.append(track) }
        }
        return tracks
    }

    private func encodingPlan(_ settings: VideoExportSettings, canvas: CGSize, project: VideoProject) -> VideoExportEncodingPlan? {
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        let outputDuration = pieces.reduce(0) { $0 + $1.compositionDuration }
        let consumed = max(0.001, pieces.reduce(0) { $0 + $1.sourceDuration })
        var source = document.encodingSource ?? VideoExportEncodingPlan.Source(
            size: canvas, averageBitrate: 0, codec: nil, nominalFPS: 1 / document.frameDuration.seconds,
            minimumFrameDuration: document.frameDuration.seconds)
        // The plan sizes output from its source; the canvas is the source here.
        source = VideoExportEncodingPlan.Source(size: canvas, averageBitrate: source.averageBitrate, codec: source.codec,
            nominalFPS: source.nominalFPS, minimumFrameDuration: source.minimumFrameDuration,
            frameDuration: source.frameDuration)
        return VideoExportEncodingPlan.make(source: source, scale: 1, quality: settings.quality,
                                            sourceDuration: consumed, outputDuration: max(0.001, outputDuration))
    }

    /// Estimated MP4 size, when a meaningful estimate exists.
    func estimatedBytes(_ settings: VideoExportSettings) -> Int64? {
        guard settings.format == .mp4, settings.quality != .high,
              let canvas = outputSize(settings),
              let plan = encodingPlan(settings, canvas: canvas, project: document.project) else { return nil }
        let duration = VideoRenderPlanner.outputDuration(project: document.project)
        return plan.estimatedBytes(duration: duration, audioTrackCount: document.project.muted ? 0 : document.audioTrackCount,
                                   audioBitrate: VideoTranscoder.audioBitrate)
    }

    /// SubRip captions on the edited clock.
    func captionsSRT() -> String {
        let project = document.project
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        return CaptionTimeline.srt(project.captions) { t in
            var elapsed = 0.0
            for piece in pieces {
                if piece.kind == .freeze { if t > piece.srcStart { elapsed += piece.compositionDuration }; continue }
                if t >= piece.srcEnd { elapsed += piece.compositionDuration; continue }
                if t > piece.srcStart { elapsed += (t - piece.srcStart) / max(piece.factor, 0.0001) }
                break
            }
            return elapsed
        }
    }

    /// Maps SRT/VTT cues authored against the exported (edited) video back
    /// onto the source clock — the inverse of `captionsSRT()`'s mapping —
    /// so imported captions land in sync however the project has been cut,
    /// sped up, or frozen since the export the cues were transcribed from.
    func importedCaptions(from cues: [CaptionCue]) -> [VideoCaptionSegment] {
        let project = document.project
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        func sourceTime(forOutputTime t: Double) -> Double {
            guard let lastPiece = pieces.last else { return t + project.trimStart }
            var elapsed = 0.0
            for piece in pieces {
                let pieceDuration = piece.compositionDuration
                let isLast = piece.srcStart == lastPiece.srcStart && piece.srcEnd == lastPiece.srcEnd
                if t <= elapsed + pieceDuration || isLast {
                    if piece.kind == .freeze { return piece.srcStart }
                    let into = max(0, t - elapsed)
                    return piece.srcStart + into * max(piece.factor, 0.0001)
                }
                elapsed += pieceDuration
            }
            return lastPiece.srcEnd
        }
        return cues.compactMap { cue in
            let start = sourceTime(forOutputTime: cue.start)
            let end = sourceTime(forOutputTime: cue.end)
            guard end > start else { return nil }
            return VideoCaptionSegment(startTime: start, endTime: end, text: cue.text)
        }
    }
}
