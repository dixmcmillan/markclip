import Foundation

/// Pure, network-free pieces of the OpenAI-compatible transcription path:
/// the response schema, chunk planning, and timestamp stitching. Kept apart
/// from `OpenAICompatibleCaptionTranscriber` (which is compiled out of the
/// offline build) so this logic — the part worth unit testing — compiles
/// and runs in every build configuration.
enum OpenAITranscription {
    /// The `verbose_json` response body requested with
    /// `timestamp_granularities[]=word`. See the OpenAI/Groq/whisper.cpp
    /// `/audio/transcriptions` endpoint: `words` is `[{word, start, end}]`
    /// with `start`/`end` in seconds relative to the uploaded file.
    struct Response: Decodable {
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
        }
        let text: String?
        let words: [Word]?
    }

    /// `{"error": {"message": "..."}}` — the error shape OpenAI, Groq and
    /// whisper.cpp servers all use for non-2xx responses.
    struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    /// Maps a decoded response's words onto the recording's timeline,
    /// offset by where this chunk started in the source audio.
    static func words(in response: Response, offsetBy offset: Double) -> [CaptionTimeline.Word] {
        (response.words ?? []).compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.end > word.start else { return nil }
            return CaptionTimeline.Word(text: text, start: word.start + offset, end: word.end + offset)
        }
    }

    /// One audio chunk to upload: where it starts in the source and how
    /// long it runs.
    struct Chunk: Equatable {
        let start: Double
        let duration: Double
    }

    /// Splits `duration` seconds of audio into chunks that fit under
    /// `maxBytes` at `bitrate` bits/sec, leaving `safetyFactor` headroom for
    /// container overhead and bitrate variance. Never splits mid-chunk
    /// unnecessarily: a recording that already fits comes back as one chunk.
    static func chunkPlan(duration: Double, bitrate: Int, maxBytes: Int, safetyFactor: Double = 0.9) -> [Chunk] {
        guard duration > 0 else { return [] }
        let maxSeconds = max(1, Double(maxBytes) * 8 * safetyFactor / Double(max(bitrate, 1)))
        guard duration > maxSeconds else { return [Chunk(start: 0, duration: duration)] }
        var chunks: [Chunk] = []
        var start = 0.0
        while start < duration - 0.001 {
            let length = min(maxSeconds, duration - start)
            chunks.append(Chunk(start: start, duration: length))
            start += length
        }
        return chunks
    }

    /// Concatenates already-offset per-chunk word lists into one timeline,
    /// sorted by start time — the final step of stitching chunked responses
    /// back together.
    static func stitch(_ chunkWords: [[CaptionTimeline.Word]]) -> [CaptionTimeline.Word] {
        chunkWords.flatMap { $0 }.sorted { $0.start < $1.start }
    }
}
