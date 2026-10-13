import XCTest

/// WebVTT output mirrors the SRT tests in `CursorTelemetryTests`: same cues,
/// same edited-clock mapping, different framing.
final class CaptionVTTTests: XCTestCase {
    private func cue(_ start: Double, _ end: Double, _ text: String) -> VideoCaptionSegment {
        VideoCaptionSegment(startTime: start, endTime: end, text: text)
    }

    func testGoldenOutputHasHeaderDotMillisecondsAndBlankLineSeparators() {
        let vtt = CaptionTimeline.vtt([cue(0, 0.7, "Hello there."), cue(1.25, 3_725.5, "General Kenobi.")]) { $0 }
        XCTAssertEqual(vtt, """
        WEBVTT

        00:00:00.000 --> 00:00:00.700
        Hello there.

        00:00:01.250 --> 01:02:05.500
        General Kenobi.

        """)
    }

    func testCuesAreSortedAndMappedOntoTheEditedClock() {
        let vtt = CaptionTimeline.vtt([cue(10, 12, "late"), cue(2, 4, "early")]) { ($0 - 1) / 2 }
        XCTAssertEqual(vtt, """
        WEBVTT

        00:00:00.500 --> 00:00:01.500
        early

        00:00:04.500 --> 00:00:05.500
        late

        """)
        let srt = CaptionTimeline.srt([cue(10, 12, "late"), cue(2, 4, "early")]) { ($0 - 1) / 2 }
        XCTAssertTrue(srt.contains("00:00:00,500 --> 00:00:01,500"), "same mapping as SRT")
    }

    func testCuesThatCollapseOrFallBeforeZeroAreDroppedAndNegativeTimesClamp() {
        let vtt = CaptionTimeline.vtt([cue(1, 2, "gone"), cue(3, 4, "kept")]) { $0 < 2.5 ? 0 : $0 - 3 }
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nkept\n")
        XCTAssertNil(CaptionTimeline.vtt([cue(0, 1, "x")]) { $0 - 5 }, "a cue entirely before zero has no duration")
        XCTAssertEqual(CaptionTimeline.vtt([cue(0, 2, "x")]) { $0 - 1 }, "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nx\n")
    }

    func testNoCaptionsOrOnlyBlankOnesReturnNil() {
        XCTAssertNil(CaptionTimeline.vtt([]) { $0 })
        XCTAssertNil(CaptionTimeline.vtt([cue(0, 1, ""), cue(1, 2, "  \n \n")]) { $0 })
    }

    func testCueTextIsEscapedForWebVTT() {
        let vtt = CaptionTimeline.vtt([cue(0, 1, "a --> b & <i>c</i>"), cue(1, 2, "one\n\ntwo\r\nthree")]) { $0 }
        XCTAssertEqual(vtt, """
        WEBVTT

        00:00:00.000 --> 00:00:01.000
        a --&gt; b &amp; &lt;i>c&lt;/i>

        00:00:01.000 --> 00:00:02.000
        one
        two
        three

        """)
        // The only arrow left in the file is the timing arrow of each cue.
        XCTAssertEqual(vtt?.components(separatedBy: "-->").count, 3)
    }
}
