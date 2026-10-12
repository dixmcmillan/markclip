import AVFoundation
import Foundation

/// A backend that turns a recording's audio into timed words. Selected in
/// Settings ▸ Transcription (`CaptionTranscriptionProviderKind`) and
/// overridable per-generation from the captions inspector section.
protocol CaptionTranscriptionProvider: Sendable {
    func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                     progress: (@Sendable (Double) -> Void)?) async throws -> [CaptionTimeline.Word]
}

/// Which speech-to-text backend produces caption words.
enum CaptionTranscriptionProviderKind: String, CaseIterable, Sendable {
    /// `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+): Apple's newer
    /// on-device model, with word-level audio time ranges.
    case appleModern
    /// The original `SFSpeechRecognizer` on-device path, used automatically
    /// below macOS 26 and as a fallback if the modern stack is unavailable.
    case appleLegacy
    /// Any OpenAI-compatible `/audio/transcriptions` endpoint: OpenAI
    /// itself, Groq, or a local whisper.cpp server. Compiled out of the
    /// offline build, like every other cloud integration.
    case openAICompatible

    static let defaultsKey = "transcriptionProviderKind"

    /// The provider used until the user picks one: the best on-device
    /// option for this Mac.
    static var systemDefault: CaptionTranscriptionProviderKind {
        if #available(macOS 26.0, *) { return .appleModern }
        return .appleLegacy
    }

    /// Providers worth offering in this build, in display order.
    static var offered: [CaptionTranscriptionProviderKind] {
        var kinds: [CaptionTranscriptionProviderKind] = []
        if #available(macOS 26.0, *) { kinds.append(.appleModern) }
        kinds.append(.appleLegacy)
        #if !OFFLINE
        kinds.append(.openAICompatible)
        #endif
        return kinds
    }

    var displayName: String {
        switch self {
        case .appleModern: return L("Apple (On-Device, Enhanced)")
        case .appleLegacy: return L("Apple (On-Device, Classic)")
        case .openAICompatible: return L("OpenAI-Compatible API")
        }
    }

    /// The configured provider, falling back to `systemDefault` if unset or
    /// no longer offered in this build (e.g. an export from a macOS 26
    /// machine imported on an older one).
    static func current(defaults: UserDefaults = .standard) -> CaptionTranscriptionProviderKind {
        guard let raw = defaults.string(forKey: defaultsKey),
              let kind = CaptionTranscriptionProviderKind(rawValue: raw),
              offered.contains(kind) else { return systemDefault }
        return kind
    }

    func makeProvider() -> any CaptionTranscriptionProvider {
        switch self {
        case .appleModern:
            if #available(macOS 26.0, *) { return AppleModernCaptionProvider() }
            return AppleLegacyCaptionProvider()
        case .appleLegacy:
            return AppleLegacyCaptionProvider()
        case .openAICompatible:
            #if !OFFLINE
            return OpenAICaptionProvider()
            #else
            return AppleLegacyCaptionProvider()
            #endif
        }
    }
}

struct AppleLegacyCaptionProvider: CaptionTranscriptionProvider {
    func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                     progress: (@Sendable (Double) -> Void)?) async throws -> [CaptionTimeline.Word] {
        try await VideoCaptionTranscriber.transcribeLegacy(asset: asset, lease: lease)
    }
}

@available(macOS 26.0, *)
struct AppleModernCaptionProvider: CaptionTranscriptionProvider {
    func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                     progress: (@Sendable (Double) -> Void)?) async throws -> [CaptionTimeline.Word] {
        try await AppleSpeechAnalyzerTranscriber.transcribe(asset: asset, lease: lease, progress: progress)
    }
}

#if !OFFLINE
struct OpenAICaptionProvider: CaptionTranscriptionProvider {
    func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                     progress: (@Sendable (Double) -> Void)?) async throws -> [CaptionTimeline.Word] {
        try await OpenAICompatibleCaptionTranscriber.transcribe(asset: asset, lease: lease, progress: progress)
    }
}
#endif

/// Single entry point the video editor calls to transcribe with whichever
/// provider is configured (or an explicit override from the inspector).
enum CaptionTranscriptionService {
    static func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                            kind: CaptionTranscriptionProviderKind = .current(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CaptionTimeline.Word] {
        try await kind.makeProvider().transcribe(asset: asset, lease: lease, progress: progress)
    }
}
