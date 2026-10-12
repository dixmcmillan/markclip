import XCTest

/// Pure state-machine tests for the J/K/L shuttle (Premiere/Resolve
/// conventions — ROADMAP Phase 2). No AVFoundation/UI involved: `VideoEditorPlayback`
/// maps `VideoPlaybackShuttle.rate` onto the real player separately.
final class PlaybackShuttleTests: XCTestCase {

    func testInitialStateIsPaused() {
        let shuttle = VideoPlaybackShuttle()
        XCTAssertEqual(shuttle.rate, 0)
        XCTAssertFalse(shuttle.isPlaying)
        XCTAssertFalse(shuttle.showsRateHUD)
    }

    // MARK: L ladder

    func testPressLFromPausedPlaysForwardAt1x() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressL(at: 0)
        XCTAssertEqual(shuttle.rate, 1)
        XCTAssertTrue(shuttle.isPlaying)
        XCTAssertFalse(shuttle.showsRateHUD, "1x forward is the normal rate — no HUD")
    }

    func testRepeatedLStepsUpTheLadder() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressL(at: 0)
        XCTAssertEqual(shuttle.rate, 1)
        shuttle.pressL(at: 1)
        XCTAssertEqual(shuttle.rate, 2)
        shuttle.pressL(at: 2)
        XCTAssertEqual(shuttle.rate, 4)
        shuttle.pressL(at: 3)
        XCTAssertEqual(shuttle.rate, 8)
        XCTAssertTrue(shuttle.showsRateHUD)
    }

    func testLLadderClampsAt8x() {
        var shuttle = VideoPlaybackShuttle()
        for t in 0..<8 { shuttle.pressL(at: TimeInterval(t)) }
        XCTAssertEqual(shuttle.rate, 8, "the ladder must not exceed 8x no matter how many extra presses")
    }

    func testLAfterReverseRestartsLadderAt1x() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressJ(at: 0)
        shuttle.pressJ(at: 1)
        XCTAssertEqual(shuttle.rate, -2)
        shuttle.pressL(at: 2)
        XCTAssertEqual(shuttle.rate, 1, "switching direction restarts the ladder rather than continuing it")
    }

    // MARK: J ladder (reverse)

    func testPressJFromPausedPlaysReverseAt1x() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressJ(at: 0)
        XCTAssertEqual(shuttle.rate, -1)
        XCTAssertTrue(shuttle.isPlaying)
    }

    func testRepeatedJStepsUpTheReverseLadder() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressJ(at: 0)
        shuttle.pressJ(at: 1)
        shuttle.pressJ(at: 2)
        shuttle.pressJ(at: 3)
        XCTAssertEqual(shuttle.rate, -8)
    }

    func testJLadderClampsAtMinus8x() {
        var shuttle = VideoPlaybackShuttle()
        for t in 0..<8 { shuttle.pressJ(at: TimeInterval(t)) }
        XCTAssertEqual(shuttle.rate, -8)
    }

    // MARK: K (pause) and clamps/resets

    func testKPauses() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressL(at: 0)
        shuttle.pressL(at: 1)
        XCTAssertEqual(shuttle.rate, 2)
        shuttle.pressK(at: 2)
        XCTAssertEqual(shuttle.rate, 0)
        XCTAssertFalse(shuttle.isPlaying)
    }

    func testLAfterKRestartsLadderAtOutsideChordWindow() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressL(at: 0)
        shuttle.pressL(at: 1)
        XCTAssertEqual(shuttle.rate, 2)
        shuttle.pressK(at: 2)
        // Well outside the chord window — a normal ladder restart, not slow motion.
        shuttle.pressL(at: 2 + VideoPlaybackShuttle.chordWindow + 1)
        XCTAssertEqual(shuttle.rate, 1)
    }

    // MARK: K+L / K+J slow-motion chord

    func testLWithinChordWindowOfKIsSlowForward() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressK(at: 0)
        shuttle.pressL(at: 0.05)
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.slowRate)
    }

    func testJWithinChordWindowOfKIsSlowReverse() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressK(at: 0)
        shuttle.pressJ(at: 0.05)
        XCTAssertEqual(shuttle.rate, -VideoPlaybackShuttle.slowRate)
    }

    func testKRepeatsWhileHeldKeepChordWindowArmed() {
        // AppKit delivers repeated keyDown events for a physically held key;
        // each one should re-arm the chord window so it stays "held" for as
        // long as the key actually is.
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressK(at: 0)
        shuttle.pressK(at: 0.2) // simulated auto-repeat, well under the window
        shuttle.pressL(at: 0.2 + VideoPlaybackShuttle.chordWindow - 0.01)
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.slowRate)
    }

    func testLOutsideChordWindowIsNormalLadderNotSlowMotion() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressK(at: 0)
        shuttle.pressL(at: VideoPlaybackShuttle.chordWindow + 0.5)
        XCTAssertEqual(shuttle.rate, 1)
    }

    // MARK: Space

    func testToggleSpaceStartsAndStopsForwardPlayback() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.toggleSpace()
        XCTAssertEqual(shuttle.rate, 1)
        shuttle.toggleSpace()
        XCTAssertEqual(shuttle.rate, 0)
    }

    func testToggleSpaceNormalizesFromAnyRateToPause() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.pressL(at: 0)
        shuttle.pressL(at: 1)
        shuttle.pressL(at: 2)
        XCTAssertEqual(shuttle.rate, 4)
        shuttle.toggleSpace()
        XCTAssertEqual(shuttle.rate, 0, "Space always pauses outright, regardless of shuttle rate")
    }

    // MARK: Direct rate / Playback menu

    func testSetDirectRateBypassesTheLadder() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.setDirectRate(1.5)
        XCTAssertEqual(shuttle.rate, 1.5)
        XCTAssertTrue(shuttle.showsRateHUD)
    }

    // MARK: Faster / Slower

    func testFasterFromPausedStartsAtNextStepAbove1x() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.faster()
        XCTAssertEqual(shuttle.rate, 1.5)
    }

    func testFasterStepsThroughSpeedsAndClamps() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.setDirectRate(4)
        shuttle.faster()
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.speedSteps.last)
        shuttle.faster()
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.speedSteps.last, "clamped at the fastest step")
    }

    func testSlowerStepsDownAndClamps() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.setDirectRate(0.5)
        shuttle.slower()
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.speedSteps.first)
        shuttle.slower()
        XCTAssertEqual(shuttle.rate, VideoPlaybackShuttle.speedSteps.first, "clamped at the slowest step")
    }

    func testFasterSlowerPreserveReverseDirection() {
        var shuttle = VideoPlaybackShuttle()
        shuttle.setDirectRate(-1)
        shuttle.faster()
        XCTAssertEqual(shuttle.rate, -1.5)
        shuttle.slower()
        XCTAssertEqual(shuttle.rate, -1)
    }

    // MARK: HUD

    func testShowsRateHUDOnlyWhenNotPausedOr1xForward() {
        var shuttle = VideoPlaybackShuttle()
        XCTAssertFalse(shuttle.showsRateHUD)
        shuttle.pressL(at: 0)
        XCTAssertFalse(shuttle.showsRateHUD)
        shuttle.pressJ(at: 1)
        XCTAssertTrue(shuttle.showsRateHUD, "reverse at 1x still shows the HUD (it's not plain forward playback)")
        shuttle.pressK(at: 2)
        XCTAssertFalse(shuttle.showsRateHUD)
    }
}
