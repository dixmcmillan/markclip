import XCTest

/// SRT/VTT import: `CaptionImport` is deliberately format-agnostic (see its
/// doc comment), so these tests exercise the real-world edge cases both
/// formats and tools like MacWhisper actually produce.
final class CaptionImportTests: XCTestCase {

    // MARK: - SRT

    func testBasicSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello there

        2
        00:00:04,500 --> 00:00:06,250
        General Kenobi
        """
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], CaptionCue(start: 1, end: 4, text: "Hello there"))
        XCTAssertEqual(cues[1].start, 4.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].end, 6.25, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "General Kenobi")
    }

    func testSRTWithHours() {
        let srt = "1\n01:02:03,004 --> 01:02:05,006\nLong recording\n"
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 3723.004, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3725.006, accuracy: 0.001)
    }

    func testMultiLineCueTextIsJoined() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        First line
        Second line
        """
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "First line\nSecond line")
    }

    func testCRLFLineEndings() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHi\r\n"
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hi")
    }

    func testMissingCueNumbersAreTolerated() {
        // Some tools omit the index; the parser doesn't need it since it
        // anchors on the "-->" timing line.
        let srt = "00:00:01,000 --> 00:00:02,000\nNo index here\n"
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "No index here")
    }

    func testBackToBackCuesWithoutBlankSeparator() {
        let srt = """
        00:00:01,000 --> 00:00:02,000
        First
        00:00:02,000 --> 00:00:03,000
        Second
        """
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First")
        XCTAssertEqual(cues[1].text, "Second")
    }

    // MARK: - WebVTT

    func testBasicVTT() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Hello there

        00:00:04.500 --> 00:00:06.250
        General Kenobi
        """
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], CaptionCue(start: 1, end: 4, text: "Hello there"))
    }

    func testHourLessVTTTimestamps() {
        let vtt = "WEBVTT\n\n01:02.500 --> 01:05.000\nNo hour component\n"
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 62.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 65.0, accuracy: 0.001)
    }

    func testVTTCueSettingsAfterTimestampsAreIgnored() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:04.000 align:start position:0%\nStyled cue\n"
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 4, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Styled cue")
    }

    func testVTTCueIdentifierLineIsSkipped() {
        let vtt = """
        WEBVTT

        intro-cue
        00:00:01.000 --> 00:00:02.000
        Has an identifier line
        """
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Has an identifier line")
    }

    func testVTTNoteAndStyleBlocksAreIgnored() {
        let vtt = """
        WEBVTT

        NOTE This is a comment block
        spanning two lines

        STYLE
        ::cue { color: yellow; }

        00:00:01.000 --> 00:00:02.000
        Real cue
        """
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Real cue")
    }

    func testHTMLishTagsAreStripped() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<b>Bold</b> and <v Roger>voice tag</v> and <00:00:01.500>timing\n"
        let cues = CaptionImport.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Bold and voice tag and timing")
    }

    // MARK: - Encoding

    func testBOMIsStripped() {
        let withBOM = "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        let cues = CaptionImport.parse(withBOM)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello")
    }

    func testDataVariantStripsUTF8BOMBytes() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append("1\n00:00:01,000 --> 00:00:02,000\nHello\n".data(using: .utf8)!)
        let cues = CaptionImport.parse(data: bytes)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello")
    }

    // MARK: - Edge cases

    func testEmptyInputProducesNoCues() {
        XCTAssertEqual(CaptionImport.parse(""), [])
    }

    func testZeroOrNegativeDurationCuesAreDropped() {
        let srt = "1\n00:00:04,000 --> 00:00:02,000\nBackwards\n"
        XCTAssertEqual(CaptionImport.parse(srt), [])
    }

    func testEmptyTextCuesAreDropped() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n\n2\n00:00:03,000 --> 00:00:04,000\nReal\n"
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Real")
    }

    func testCuesAreSortedByStartTime() {
        let srt = """
        1
        00:00:05,000 --> 00:00:06,000
        Second

        2
        00:00:01,000 --> 00:00:02,000
        First
        """
        let cues = CaptionImport.parse(srt)
        XCTAssertEqual(cues.map(\.text), ["First", "Second"])
    }
}
