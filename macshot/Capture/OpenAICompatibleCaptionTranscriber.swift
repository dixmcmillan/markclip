#if !OFFLINE
import AVFoundation

/// Transcribes audio via any OpenAI-compatible `/audio/transcriptions`
/// endpoint — OpenAI itself, Groq, or a local whisper.cpp server. This is a
/// cloud integration like uploads, so it (and its Settings section) are
/// compiled out of the offline build.
///
/// Configured in Settings ▸ Transcription: base URL (`OpenAISettings`),
/// model, and an API key that lives in the Keychain via
/// `TranscriptionSecrets` — never `UserDefaults`, never logged, and (because
/// it's never in `UserDefaults`) never part of the settings export.
///
/// The audio track is re-encoded to mono AAC at a low bitrate and, if the
/// recording is long enough that a single upload would exceed the API's
/// 25 MB limit, split into time-based chunks (`OpenAITranscription.chunkPlan`)
/// that are uploaded and stitched back together in order.
enum OpenAICompatibleCaptionTranscriber {
    enum TranscriptionError: LocalizedError {
        case noAudio
        case missingAPIKey
        case invalidBaseURL
        case exportFailed
        case server(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return L("This recording has no audio to transcribe.")
            case .missingAPIKey:
                return L("Add an API key in Settings ▸ Transcription before using this provider.")
            case .invalidBaseURL:
                return L("The transcription API's base URL isn't valid.")
            case .exportFailed:
                return L("The recording's audio could not be read.")
            case .server(let message):
                return message
            case .invalidResponse:
                return L("The transcription service returned an unexpected response.")
            }
        }
    }

    /// Mono AAC at a modest bitrate: keeps chunks small (and usually keeps a
    /// whole recording under the API's upload limit in a single request)
    /// without discarding the detail speech recognition needs.
    private static let audioBitrate = 48_000
    private static let maxUploadBytes = 24 * 1024 * 1024

    static func transcribe(asset: AVAsset, lease: TemporaryMediaLease,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CaptionTimeline.Word] {
        defer { withExtendedLifetime(lease) {} }
        guard let audioTrack = (try await asset.load(.tracks)).first(where: { $0.mediaType == .audio }) else {
            throw TranscriptionError.noAudio
        }
        guard let apiKey = TranscriptionSecrets.openAIAPIKey, !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey
        }
        guard let endpoint = URL(string: "audio/transcriptions", relativeTo: OpenAISettings.baseURL) else {
            throw TranscriptionError.invalidBaseURL
        }
        let model = OpenAISettings.model

        let duration = try await asset.load(.duration).seconds
        let chunks = OpenAITranscription.chunkPlan(duration: duration, bitrate: audioBitrate, maxBytes: maxUploadBytes)
        guard !chunks.isEmpty else { return [] }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macshot-captions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var chunkWords: [[CaptionTimeline.Word]] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent("chunk-\(index).m4a")
            try await exportMonoAudio(asset: asset, track: audioTrack, start: chunk.start, duration: chunk.duration,
                                       bitrate: audioBitrate, to: url)
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            try Task.checkCancellation()
            let response = try await upload(fileData: data, filename: "chunk-\(index).m4a", endpoint: endpoint,
                                             apiKey: apiKey, model: model)
            chunkWords.append(OpenAITranscription.words(in: response, offsetBy: chunk.start))
            progress?(Double(index + 1) / Double(chunks.count))
        }
        return OpenAITranscription.stitch(chunkWords)
    }

    /// Re-encodes one time range of the source audio to mono 16 kHz AAC.
    private static func exportMonoAudio(asset: AVAsset, track: AVAssetTrack, start: Double, duration: Double,
                                         bitrate: Int, to url: URL) async throws {
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                 duration: CMTime(seconds: duration, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { throw TranscriptionError.exportFailed }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
            AVEncoderBitRateKey: bitrate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscriptionError.exportFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? TranscriptionError.exportFailed }
        writer.startWriting()
        // `range.start` becomes this chunk file's zero point, so per-chunk
        // word timestamps from the API are already relative to `start` —
        // exactly what `OpenAITranscription.words(in:offsetBy:)` expects.
        writer.startSession(atSourceTime: range.start)

        let queue = DispatchQueue(label: "com.dixmcmillan.markclip.transcription.export")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let buffer = output.copyNextSampleBuffer() {
                        input.append(buffer)
                    } else {
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: writer.error ?? TranscriptionError.exportFailed) }
                        }
                        return
                    }
                }
            }
        }
        guard writer.status == .completed else { throw writer.error ?? TranscriptionError.exportFailed }
    }

    private static func upload(fileData: Data, filename: String, endpoint: URL, apiKey: String,
                                model: String) async throws -> OpenAITranscription.Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(fileData: fileData, filename: filename, model: model, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let errorBody = try? JSONDecoder().decode(OpenAITranscription.ErrorBody.self, from: data),
               let message = errorBody.error?.message {
                throw TranscriptionError.server(message)
            }
            throw TranscriptionError.server(String(format: L("The transcription service returned an error (%d)."), http.statusCode))
        }
        do {
            return try JSONDecoder().decode(OpenAITranscription.Response.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse
        }
    }

    private static func multipartBody(fileData: Data, filename: String, model: String, boundary: String) -> Data {
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("model", model)
        addField("response_format", "verbose_json")
        addField("timestamp_granularities[]", "word")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

/// User-facing OpenAI-compatible provider settings. Not secret — the API
/// key itself lives in the Keychain via `TranscriptionSecrets`, never here.
enum OpenAISettings {
    static let baseURLDefaultsKey = "transcriptionOpenAIBaseURL"
    static let modelDefaultsKey = "transcriptionOpenAIModel"
    static let defaultBaseURLString = "https://api.openai.com/v1/"
    static let defaultModel = "whisper-1"

    static var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: baseURLDefaultsKey)?.trimmingCharacters(in: .whitespaces)
        var value = (raw?.isEmpty == false ? raw! : defaultBaseURLString)
        if !value.hasSuffix("/") { value += "/" }
        return URL(string: value) ?? URL(string: defaultBaseURLString)!
    }

    static var model: String {
        let raw = UserDefaults.standard.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespaces)
        return raw?.isEmpty == false ? raw! : defaultModel
    }
}
#endif
