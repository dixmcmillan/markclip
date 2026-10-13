import AVFoundation

/// Resolved export settings for one run. The legacy fields (format, scale,
/// quality, gifFPS) still persist through the loose keys below until Phase 6;
/// the preset-derived fields are per-run only.
struct VideoExportSettings: Equatable {
    enum Format: String { case mp4, gif }
    var format: Format = .mp4
    /// Output scale relative to the native canvas, 0 < scale ≤ 1.
    var scale: CGFloat = 1
    var quality: VideoQuality = .high
    var gifFPS: Int = 15

    // Resolved per-run fields, built from an `ExportPreset` (+ overrides) by
    // `ExportPreset.resolvedSettings`. Not persisted. `VideoEditorExporter`
    // reads codec/fpsCap/explicitBitrate/captions/muted for MP4 output;
    // Phase 2 wires gifFit.
    /// Video codec for MP4 output. A source that already matches it is
    /// copied untouched when nothing else is edited.
    var codec: VideoCodec = .h264
    /// Frame-rate cap for video; nil keeps the source rate. Only ever lowers
    /// the rate, never upsamples. Forces a re-encode when it takes effect.
    var fpsCap: Int?
    /// Bits per second; overrides `quality` for the encoder and forces a
    /// re-encode through `VideoTranscoder`.
    var explicitBitrate: Int?
    /// `.burned` renders captions into the pixels; `.soft` and `.off` leave
    /// them out (`captionsVTT()` / `captionsSRT()` supply a soft sidecar).
    var captions: ExportCaptionsMode = .burned
    /// Drop the audio tracks from the output.
    var muted: Bool = false
    var gifFit: GIFFitSettings = .default

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
    /// Soft/off captions are not burned, so captions alone leave the video
    /// pixels unedited; the codec, size and frame rate must also already be
    /// what the settings ask for.
    func needsRender(_ settings: VideoExportSettings) -> Bool {
        let project = document.project
        if settings.format == .gif { return true }
        return settings.scale < 0.999 || settings.quality != .high
            || settings.explicitBitrate != nil
            || !sourceMatches(codec: settings.codec)
            || fpsCapLowersRate(settings.fpsCap)
            || (settings.muted && document.audioTrackCount > 0)
            || project.hasEdits(burningCaptions: settings.captions == .burned)
            || document.cursorIsEditable || document.cameraURL != nil
            || (document.overlaysAreEditable && document.hasKeystrokes)
    }

    /// Whether the source stream can be delivered as the requested codec
    /// without re-encoding. An unknown source codec only matches H.264, the
    /// recorder's native format.
    private func sourceMatches(codec: VideoCodec) -> Bool {
        guard let sourceCodec = document.encodingSource?.codec else { return codec == .h264 }
        switch codec {
        case .h264: return sourceCodec == kCMVideoCodecType_H264
        case .hevc: return sourceCodec == kCMVideoCodecType_HEVC
        }
    }

    /// A cap at or above the source cadence changes nothing.
    private func fpsCapLowersRate(_ cap: Int?) -> Bool {
        guard let cap, cap > 0 else { return false }
        return Double(cap) < 1 / max(document.frameDuration.seconds, 0.001) * 0.995
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
        let includeAudio: Bool
    }

    /// Everything per-run (mute, caption mode) is applied to the project
    /// copy, so the one shared render path produces every variant.
    private func prepare(_ settings: VideoExportSettings, includeAudio: Bool, frameDuration: CMTime? = nil) throws -> Prepared {
        guard let project = document.project.copy() else { throw ExportError.invalidSetup }
        if settings.muted { project.muted = true }
        if settings.captions != .burned { project.look.captions.show = false }
        let includeAudio = includeAudio && !project.muted
        // Exports render at full quality with their own caches.
        let planner = VideoRenderPlanner(document: document)
        let processed = try planner.processed(project: project, from: project.trimStart, to: project.trimEnd,
                                              includeAudio: includeAudio)
        var options = VideoRenderPlanner.Options()
        options.scale = settings.scale
        options.exactPointer = true
        let composition = try planner.videoComposition(project: project, processed: processed, options: options,
                                                       frameDuration: frameDuration)
        return Prepared(project: project, planner: planner, processed: processed, composition: composition,
                        includeAudio: includeAudio)
    }

    /// Routing:
    /// - An explicit bitrate, an fps cap, or HEVC always goes through
    ///   `VideoTranscoder` (the only path that controls them), whatever the
    ///   quality tier.
    /// - Only H.264 at High with neither uses the `AVAssetExportSession`
    ///   `HighestQuality` preset.
    ///
    /// Archive (HEVC, High, no bitrate) deliberately does NOT use
    /// `AVAssetExportPresetHEVCHighestQuality`. A session has no encoder
    /// specification hook, so it ignores `VideoEncoderPolicy` and can only be
    /// exercised on the hardware encoder, which the test suite must not drive
    /// (docs/feedback/2026-10-13-ave-dart-panic.md). The transcoder HEVC path
    /// honors the policy, has an explicit High bits-per-pixel budget, and is
    /// covered by software-encoder tests that decode the output.
    func mp4Job(_ settings: VideoExportSettings, outputURL: URL) throws -> VideoExportJob {
        let lease = document.source.lease
        let controlsRate = settings.explicitBitrate != nil || settings.fpsCap != nil
        if !controlsRate && settings.quality == .high && settings.codec == .h264 {
            let prepared = try prepare(settings, includeAudio: true)
            guard let session = AVAssetExportSession(asset: prepared.processed.composition,
                                                     presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.invalidSetup
            }
            session.metadata = VideoFrameCadence.metadata(for: document.frameDuration)
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.videoComposition = prepared.composition
            if !prepared.includeAudio { session.audioMix = nil }
            return VideoExportJob(session: session, sourceLease: lease)
        }
        // The cap decides the composition cadence, so plan before preparing.
        guard let canvas = outputSize(settings),
              let early = encodingPlan(settings, canvas: canvas, project: document.project) else {
            throw ExportError.invalidSetup
        }
        let prepared = try prepare(settings, includeAudio: true, frameDuration: early.frameDuration)
        return try transcodeJob(settings, prepared: prepared, outputURL: outputURL, lease: lease)
    }

    private func transcodeJob(_ settings: VideoExportSettings, prepared: Prepared, outputURL: URL,
                              lease: TemporaryMediaLease?) throws -> VideoExportJob {
        let canvas = prepared.composition.renderSize
        guard let plan = encodingPlan(settings, canvas: canvas, project: prepared.project) else {
            throw ExportError.invalidSetup
        }
        var request = VideoTranscoder.Request(
            asset: prepared.processed.composition, videoTrack: prepared.processed.videoTrack,
            audioTracks: prepared.includeAudio ? prepared.processed.audioTracks : [], composition: prepared.composition,
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

    /// GIF export at an explicit cadence and canvas long edge (in pixels), for
    /// GIF auto-fit rungs. Independent of the persisted `VideoExportSettings`;
    /// the long edge is clamped to the native canvas (never upscaled).
    func gifRequest(fps: Int, longEdge: Int, outputURL: URL) throws -> GIFExporter.Request {
        guard let native = nativeCanvasSize, native.width > 0, native.height > 0 else { throw ExportError.invalidSetup }
        var settings = VideoExportSettings()
        settings.format = .gif
        settings.scale = min(1, max(0.01, CGFloat(longEdge) / max(native.width, native.height)))
        settings.gifFPS = fps
        return try gifRequest(settings, outputURL: outputURL)
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
        // The document's cached cadence (not the shortest sample) drives fps.
        source = VideoExportEncodingPlan.Source(size: canvas, averageBitrate: source.averageBitrate, codec: source.codec,
            nominalFPS: source.nominalFPS, minimumFrameDuration: source.minimumFrameDuration,
            frameDuration: document.frameDuration)
        return VideoExportEncodingPlan.make(source: source, scale: 1, quality: settings.quality, codec: settings.codec,
                                            fpsCap: settings.fpsCap, explicitBitrate: settings.explicitBitrate,
                                            sourceDuration: consumed, outputDuration: max(0.001, outputDuration))
    }

    /// Estimated MP4 size, when a meaningful estimate exists.
    func estimatedBytes(_ settings: VideoExportSettings) -> Int64? {
        guard settings.format == .mp4,
              let canvas = outputSize(settings),
              let plan = encodingPlan(settings, canvas: canvas, project: document.project) else { return nil }
        let duration = VideoRenderPlanner.outputDuration(project: document.project)
        return plan.estimatedBytes(duration: duration, audioTrackCount: document.project.muted || settings.muted ? 0 : document.audioTrackCount,
                                   audioBitrate: VideoTranscoder.audioBitrate)
    }

    /// Source time -> edited-clock time, shared by the SRT and VTT sidecars.
    private func editedClock() -> (Double) -> Double {
        let project = document.project
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        return { t in
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

    /// SubRip captions on the edited clock.
    func captionsSRT() -> String {
        CaptionTimeline.srt(document.project.captions, mapTime: editedClock())
    }

    /// WebVTT captions on the edited clock, or nil when there are none to
    /// write. This is the soft-captions sidecar: write it beside the video
    /// as `<name>.vtt` (UTF-8).
    func captionsVTT() -> String? {
        CaptionTimeline.vtt(document.project.captions, mapTime: editedClock())
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
