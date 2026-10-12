import XCTest

/// The network-free half of the OpenAI-compatible transcription path:
/// decoding a `verbose_json` response, chunk planning, and stitching. No
/// live network involved — `OpenAICompatibleCaptionTranscriber` (the actual
/// uploader) is compiled out of the offline build, but this mapping logic
/// lives in `OpenAITranscriptionMapping.swift` precisely so it can be tested
/// in every build configuration.
final class OpenAITranscriptionMappingTests: XCTestCase {

    // MARK: - Response decoding + word mapping

    /// A representative `verbose_json` fixture with `timestamp_granularities:
    /// ["word"]`, matching the documented OpenAI/Groq/whisper.cpp shape.
    private static let fixtureJSON = """
    {
      "task": "transcribe",
      "language": "english",
      "duration": 3.24,
      "text": "Hello there general",
      "words": [
        { "word": "Hello", "start": 0.0, "end": 0.42 },
        { "word": "there", "start": 0.45, "end": 0.81 },
        { "word": "general", "start": 0.90, "end": 1.50 }
      ],
      "segments": []
    }
    """.data(using: .utf8)!

    func testDecodesVerboseJSONFixture() throws {
        let response = try JSONDecoder().decode(OpenAITranscription.Response.self, from: Self.fixtureJSON)
        XCTAssertEqual(response.text, "Hello there general")
        XCTAssertEqual(response.words?.count, 3)
        XCTAssertEqual(response.words?.first?.word, "Hello")
    }

    func testWordsMapsWithNoOffset() throws {
        let response = try JSONDecoder().decode(OpenAITranscription.Response.self, from: Self.fixtureJSON)
        let words = OpenAITranscription.words(in: response, offsetBy: 0)
        XCTAssertEqual(words, [
            CaptionTimeline.Word(text: "Hello", start: 0.0, end: 0.42),
            CaptionTimeline.Word(text: "there", start: 0.45, end: 0.81),
            CaptionTimeline.Word(text: "general", start: 0.90, end: 1.50),
        ])
    }

    func testWordsAppliesChunkOffset() throws {
        let response = try JSONDecoder().decode(OpenAITranscription.Response.self, from: Self.fixtureJSON)
        let words = OpenAITranscription.words(in: response, offsetBy: 100)
        XCTAssertEqual(words.map(\.start), [100.0, 100.45, 100.90])
        XCTAssertEqual(words.map(\.end), [100.42, 100.81, 101.50])
    }

    func testWordsDropsBlankOrZeroDurationEntries() {
        let response = OpenAITranscription.Response(text: nil, words: [
            .init(word: "  ", start: 0, end: 1),
            .init(word: "ok", start: 1, end: 1),  // zero duration
            .init(word: "kept", start: 2, end: 2.5),
        ])
        let words = OpenAITranscription.words(in: response, offsetBy: 0)
        XCTAssertEqual(words.map(\.text), ["kept"])
    }

    func testWordsHandlesMissingWordsArray() {
        let response = OpenAITranscription.Response(text: "no words field", words: nil)
        XCTAssertEqual(OpenAITranscription.words(in: response, offsetBy: 0), [])
    }

    func testErrorBodyDecodes() throws {
        let json = #"{"error": {"message": "Invalid API key"}}"#.data(using: .utf8)!
        let body = try JSONDecoder().decode(OpenAITranscription.ErrorBody.self, from: json)
        XCTAssertEqual(body.error?.message, "Invalid API key")
    }

    // MARK: - Chunk planning

    func testChunkPlanReturnsOneChunkWhenItAlreadyFits() {
        // 60s at 48kbps ≈ 360,000 bytes — comfortably under a 24 MB cap.
        let chunks = OpenAITranscription.chunkPlan(duration: 60, bitrate: 48_000, maxBytes: 24 * 1024 * 1024)
        XCTAssertEqual(chunks, [.init(start: 0, duration: 60)])
    }

    func testChunkPlanSplitsLongDurations() {
        // Force small limits so a 100s recording needs multiple chunks.
        let chunks = OpenAITranscription.chunkPlan(duration: 100, bitrate: 8_000, maxBytes: 10_000, safetyFactor: 1.0)
        // maxSeconds = 10,000 * 8 / 8,000 = 10s per chunk.
        XCTAssertEqual(chunks.count, 10)
        XCTAssertEqual(chunks.first, .init(start: 0, duration: 10))
        XCTAssertEqual(chunks.last?.start ?? -1, 90, accuracy: 0.001)
    }

    func testChunkPlanCoversTheWholeDurationWithNoGapsOrOverlap() {
        let chunks = OpenAITranscription.chunkPlan(duration: 97, bitrate: 8_000, maxBytes: 10_000, safetyFactor: 1.0)
        var cursor = 0.0
        for chunk in chunks {
            XCTAssertEqual(chunk.start, cursor, accuracy: 0.001)
            cursor += chunk.duration
        }
        XCTAssertEqual(cursor, 97, accuracy: 0.001)
    }

    func testChunkPlanReturnsEmptyForNonPositiveDuration() {
        XCTAssertEqual(OpenAITranscription.chunkPlan(duration: 0, bitrate: 48_000, maxBytes: 1000), [])
        XCTAssertEqual(OpenAITranscription.chunkPlan(duration: -5, bitrate: 48_000, maxBytes: 1000), [])
    }

    // MARK: - Stitching

    func testStitchConcatenatesAndSortsChunks() {
        let chunkA = [CaptionTimeline.Word(text: "third", start: 20, end: 21)]
        let chunkB = [
            CaptionTimeline.Word(text: "first", start: 0, end: 1),
            CaptionTimeline.Word(text: "second", start: 10, end: 11),
        ]
        let stitched = OpenAITranscription.stitch([chunkA, chunkB])
        XCTAssertEqual(stitched.map(\.text), ["first", "second", "third"])
    }

    func testStitchOfEmptyChunksIsEmpty() {
        XCTAssertEqual(OpenAITranscription.stitch([[], []]), [])
    }

    /// End-to-end: plan chunks, decode a response per chunk, stitch —
    /// exercising the same offset/order logic the real uploader relies on,
    /// without any network I/O.
    func testChunkedTranscriptStitchesInOrder() throws {
        let chunkPlan = OpenAITranscription.chunkPlan(duration: 20, bitrate: 8_000, maxBytes: 10_000, safetyFactor: 1.0)
        XCTAssertEqual(chunkPlan.count, 2)  // 10s per chunk at this bitrate/limit
        let perChunkResponse = try JSONDecoder().decode(OpenAITranscription.Response.self, from: """
        { "text": "hi", "words": [{ "word": "hi", "start": 0.5, "end": 0.9 }] }
        """.data(using: .utf8)!)
        let chunkWords = chunkPlan.map { chunk in OpenAITranscription.words(in: perChunkResponse, offsetBy: chunk.start) }
        let stitched = OpenAITranscription.stitch(chunkWords)
        XCTAssertEqual(stitched.map(\.start), [0.5, 10.5])
    }
}
