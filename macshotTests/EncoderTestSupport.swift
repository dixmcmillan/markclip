import AVFoundation
import XCTest

/// Test classes that encode video or build movie fixtures run only on CI
/// (`MACSHOT_MEDIA_TESTS=1`, set by .github/workflows/tests.yml). On the
/// development Mac the Apple Video Encoder kernel-panicked twice, the second
/// time right after a software-encoder run (docs/feedback/2026-10-13-ave-dart-panic.md).
/// Every such class calls `try MediaTests.require()` at the end of
/// `setUpWithError()`; `EncoderSessionTracker` stops the run if one is missed.
enum MediaTests {
    static let environmentKey = EncoderSessionTracker.mediaTestsEnvironmentKey
    static let isEnabled = EncoderSessionTracker.mediaTestsEnabled

    static func require(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(isEnabled,
            "Media test: runs on CI only (set \(environmentKey)=1; see the Video encoder tests section of CLAUDE.md)",
            file: file, line: line)
    }
}

/// Tests that need the hardware encoder: those that encode through
/// `AVAssetExportSession` (no encoder-specification hook) and those asserting
/// hardware-specific encoder behavior. They run only with
/// `MACSHOT_HARDWARE_ENCODER_TESTS=1`, which also turns off the software
/// override: rapid hardware sessions from this suite triggered a kernel panic
/// (docs/feedback/2026-10-13-ave-dart-panic.md). Run them serially, on their own
/// (`-only-testing:`), never in a loop. Everything else encodes in software.
enum HardwareEncoderTests {
    static let environmentKey = VideoEncoderPolicy.hardwareTestsEnvironmentKey
    static let isEnabled = ProcessInfo.processInfo.environment[environmentKey] == "1"

    /// Skips the rest of the test unless hardware encoder tests were requested.
    static func require(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(isEnabled,
            "Hardware encoder test: set \(environmentKey)=1 to run (see docs/feedback/2026-10-13-ave-dart-panic.md)",
            file: file, line: line)
    }
}

/// The test bundle's principal class (`NSPrincipalClass`). Every test gets a
/// teardown check that it left no encoder session mid-encode, and fails at
/// start if an earlier test did, so one export never overlaps another.
@objc(EncoderTestObserver)
final class EncoderTestObserver: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let leftover = EncoderSessionTracker.inFlight()
        if !leftover.isEmpty {
            testCase.record(XCTIssue(type: .assertionFailure,
                compactDescription: "An earlier test left encoder sessions running: \(leftover.joined(separator: "; "))"))
        }
        testCase.addTeardownBlock {
            let running = EncoderSessionTracker.inFlight()
            XCTAssertTrue(running.isEmpty,
                "Test returned while encoding; await finishWriting/export first: \(running.joined(separator: "; "))")
        }
    }
}
