import AVFoundation
import Speech

/// Transcribes a recording's audio on this Mac with Apple's macOS 26
/// `SpeechAnalyzer` / `SpeechTranscriber` — a newer, more accurate on-device
/// model than the `SFSpeechRecognizer` path in `VideoCaptionTranscriber`.
/// Word timing comes from each result's `audioTimeRange` attribute rather
/// than per-chunk recognition segments, and the locale's model asset is
/// installed on demand via `AssetInventory`. Audio never leaves the device.
@available(macOS 26.0, *)
enum AppleSpeechAnalyzerTranscriber {
    enum TranscriptionError: LocalizedError {
        case noAudio
        case unsupportedLocale
        case exportFailed
        case assetInstallFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return L("This recording has no audio to transcribe.")
            case .unsupportedLocale:
                return L("On-device speech recognition isn't available for your language on this Mac.")
            case .exportFailed:
                return L("The recording's audio could not be read.")
            case .assetInstallFailed(let error):
                return String(format: L("The speech model couldn't be downloaded: %@"), error.localizedDescription)
            }
        }
    }

    static func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CaptionTimeline.Word] {
        defer { withExtendedLifetime(lease) {} }
        guard !(try await asset.load(.tracks)).filter({ $0.mediaType == .audio }).isEmpty else {
            throw TranscriptionError.noAudio
        }
        let duration = try await asset.load(.duration).seconds
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                             reportingOptions: [], attributeOptions: [.audioTimeRange])
        try await installAssetsIfNeeded(for: transcriber, progress: progress)
        try Task.checkCancellation()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macshot-captions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("audio.m4a")
        try await exportAudio(asset: asset, to: audioURL)
        let audioFile = try AVAudioFile(forReading: audioURL)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectWords(from: transcriber, duration: max(duration, 0.01), progress: progress)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collected
    }

    /// Consumes `transcriber.results` concurrently with the analyzer being
    /// driven from the audio file. Only final results carry a reliable
    /// `audioTimeRange`, so volatile/partial results are skipped.
    private static func collectWords(from transcriber: SpeechTranscriber, duration: Double,
                                      progress: (@Sendable (Double) -> Void)?) async throws -> [CaptionTimeline.Word] {
        var words: [CaptionTimeline.Word] = []
        for try await result in transcriber.results {
            guard result.isFinal else { continue }
            for run in result.text.runs {
                guard let timeRange = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(CaptionTimeline.Word(text: text, start: timeRange.start.seconds, end: timeRange.end.seconds))
            }
            // Reserve the tail of the range for model-download progress
            // already reported by `installAssetsIfNeeded`.
            progress?(0.2 + 0.8 * min(1, max(0, result.range.end.seconds / duration)))
        }
        return words
    }

    /// Downloads and installs the locale's model assets if they aren't
    /// already on disk. `AssetInventory` consolidates concurrent/duplicate
    /// requests, so this is safe to call every time.
    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber,
                                                progress: (@Sendable (Double) -> Void)?) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard status != .unsupported else { throw TranscriptionError.unsupportedLocale }
        do {
            progress?(0.02)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            try await request.downloadAndInstall()
            progress?(0.2)
        } catch {
            throw TranscriptionError.assetInstallFailed(error)
        }
    }

    private static func exportAudio(asset: AVAsset, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed
        }
        session.outputURL = url
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw session.error ?? TranscriptionError.exportFailed }
    }
}
