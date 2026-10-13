import XCTest

final class GIFFitPlannerTests: XCTestCase {
    private func plan(_ duration: Double, _ width: Int = 1280, _ height: Int = 720, fps: Int = 15,
                      budget: GIFFitBudget = .cloudflareImages) -> [GIFFitRung] {
        GIFFitPlanner.plan(duration: duration, startWidth: width, startHeight: height, startFPS: fps, budget: budget)
    }

    func testDefaultBudgetMatchesCloudflareImages() {
        let budget = GIFFitBudget.cloudflareImages
        XCTAssertEqual(budget.maxBytes, 10_000_000)
        XCTAssertEqual(budget.maxTotalPixels, 50_000_000)
        XCTAssertEqual(budget.minLongEdge, 640)
        XCTAssertEqual(budget.fpsLadder, [15, 12, 10, 8])
    }

    func testFpsLadderIsWalkedAtTheStartSizeBeforeAnySizeStep() {
        let rungs = plan(3)
        XCTAssertEqual(rungs.prefix(4).map(\.fps), [15, 12, 10, 8])
        XCTAssertTrue(rungs.prefix(4).allSatisfy { $0.width == 1280 && $0.height == 720 })
    }

    func testSizeStepsHoldTheLowestFpsAndEndExactlyAtTheFloor() {
        let rungs = plan(3)
        XCTAssertEqual(rungs.dropFirst(4).map(\.fps), [8, 8, 8, 8, 8])
        XCTAssertEqual(rungs.dropFirst(3).map(\.longEdge), [1280, 1088, 924, 786, 668, 640])
        XCTAssertEqual(rungs.last, GIFFitRung(fps: 8, width: 640, height: 360))
        XCTAssertEqual(rungs.map(\.summary).first, "15 fps, 1280 px")
    }

    func testPixelBudgetSkipsFpsRungsThatCannotPassAnalytically() {
        // 5 s at 1280x720: 15 fps = 75 frames (69 MP), 12 = 60 (55 MP) are over 50 MP.
        XCTAssertEqual(plan(5).prefix(2).map(\.fps), [10, 8])
        XCTAssertEqual(plan(5).first?.longEdge, 1280)
        // 6 s: only 8 fps (48 frames, 44 MP) fits at full size.
        XCTAssertEqual(plan(6).first, GIFFitRung(fps: 8, width: 1280, height: 720))
    }

    func testFirstSizeThatPassesIsEnteredAtItsHighestPassingFps() {
        // 1080p for 8 s fails every fps at several sizes; once a size passes, the
        // best fps for it is used rather than blindly 8, and fps never rises later.
        let rungs = plan(8, 1920, 1080)
        let first = try? XCTUnwrap(rungs.first)
        XCTAssertLessThan(first?.longEdge ?? 0, 1920)
        XCTAssertGreaterThan(first?.fps ?? 0, 8)
        assertInvariants(rungs, duration: 8)
    }

    func testEveryRungFitsThePixelBudgetAndNeverGetsMoreExpensive() {
        for (duration, w, h) in [(2.0, 1280, 720), (7.3, 1920, 1080), (12.0, 3024, 1964), (30.0, 640, 360), (4.0, 720, 1280)] {
            assertInvariants(plan(duration, w, h), duration: duration)
        }
    }

    func testCannotFitReturnsNoRungsWhenEvenTheFloorExceedsThePixelBudget() {
        // 8 fps x 640x360 x ceil(600 s) frames = far beyond 50 MP.
        XCTAssertTrue(plan(600).isEmpty)
        // Floor frame count limit: 50 MP / 230400 px = 217 frames = 27 s at 8 fps.
        XCTAssertEqual(plan(27).last, GIFFitRung(fps: 8, width: 640, height: 360))
        XCTAssertTrue(plan(28).isEmpty)
    }

    func testSizesAreEvenForOddAndPortraitInputs() {
        for rungs in [plan(2, 1281, 721), plan(2, 721, 1281), plan(2, 1366, 769)] {
            XCTAssertFalse(rungs.isEmpty)
            for rung in rungs {
                XCTAssertEqual(rung.width % 2, 0, "\(rung)")
                XCTAssertEqual(rung.height % 2, 0, "\(rung)")
            }
        }
        let portrait = plan(2, 720, 1280)
        XCTAssertEqual(portrait.last, GIFFitRung(fps: 8, width: 360, height: 640))
        XCTAssertTrue(portrait.allSatisfy { $0.height > $0.width })
    }

    func testAspectRatioIsPreservedWithinOnePixelStep() {
        for rung in plan(2, 1366, 768) {
            XCTAssertEqual(Double(rung.width) / Double(rung.height), 1366.0 / 768.0, accuracy: 0.02)
        }
    }

    func testStartBelowTheFloorIsNeverUpscaled() {
        let rungs = plan(2, 500, 300)
        XCTAssertEqual(rungs.map(\.fps), [15, 12, 10, 8])
        XCTAssertTrue(rungs.allSatisfy { $0.width == 500 && $0.height == 300 })
    }

    func testStartingFpsOutsideTheLadder() {
        XCTAssertEqual(plan(2, fps: 24).map(\.fps).prefix(5), [24, 15, 12, 10, 8])
        XCTAssertEqual(plan(2, 1280, 720, fps: 6).map(\.fps).prefix(2), [6, 6])
        XCTAssertEqual(plan(2, fps: 12).map(\.fps).prefix(3), [12, 10, 8])
    }

    func testInvalidInputsProduceNoPlan() {
        XCTAssertTrue(plan(0).isEmpty)
        XCTAssertTrue(plan(.nan).isEmpty)
        XCTAssertTrue(GIFFitPlanner.plan(duration: 2, startWidth: 0, startHeight: 10, startFPS: 15).isEmpty)
        var budget = GIFFitBudget(); budget.longEdgeStep = 1
        XCTAssertTrue(plan(2, budget: budget).isEmpty)
    }

    func testNearUnityStepStillTerminatesWithStrictlyShrinkingSizes() {
        var budget = GIFFitBudget(); budget.longEdgeStep = 0.999
        let edges = plan(1, 800, 450, budget: budget).map(\.longEdge)
        XCTAssertEqual(edges.last, 640)
        let distinct = Array(NSOrderedSet(array: edges)) as? [Int] ?? []
        XCTAssertEqual(distinct, distinct.sorted(by: >))
    }

    private func assertInvariants(_ rungs: [GIFFitRung], duration: Double, file: StaticString = #filePath, line: UInt = #line) {
        let budget = GIFFitBudget.cloudflareImages
        for rung in rungs {
            XCTAssertTrue(GIFFitPlanner.fitsPixelBudget(duration: duration, fps: rung.fps, width: rung.width,
                                                        height: rung.height, budget: budget), "\(rung)", file: file, line: line)
        }
        for (a, b) in zip(rungs, rungs.dropFirst()) {
            XCTAssertLessThanOrEqual(b.fps, a.fps, file: file, line: line)
            XCTAssertLessThanOrEqual(b.longEdge, a.longEdge, file: file, line: line)
            XCTAssertLessThan(b.fps * b.width * b.height, a.fps * a.width * a.height, "must get cheaper", file: file, line: line)
        }
    }
}
