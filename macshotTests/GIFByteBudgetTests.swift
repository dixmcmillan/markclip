import AVFoundation
import XCTest

/// Byte counting in `GIFEncoder`, the `GIFExporter` size cap, and the
/// `GIFFitExporter` retry loop on a small synthetic noisy clip.
final class GIFByteBudgetTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Last, so tearDown always has a directory to remove.
        try MediaTests.require()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
    private func fileSize(_ url: URL) throws -> Int64 {
        // attributesOfItem, not URL resource values, which cache on the URL object.
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Deterministic per-frame noise: incompressible enough that bytes scale with fps and area.
    private func noise(frame: Int, width: Int = 192, height: Int = 108) throws -> CVPixelBuffer {
        let buffer = try RecordingMediaFixture.pixels(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var state = UInt32(truncatingIfNeeded: frame &* 2_654_435_761 &+ 12_345)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                for channel in 0..<3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    base[i + channel] = UInt8(truncatingIfNeeded: state >> 24)
                }
            }
        }
        return buffer
    }

    // MARK: Encoder

    func testByteCountGrowsMonotonicallyAndMatchesTheFileAtEveryStep() throws {
        let url = directory.appendingPathComponent("count.gif")
        let encoder = try GIFEncoder(url: url)
        XCTAssertEqual(encoder.bytesWritten, 0)
        var previous: Int64 = 0
        for index in 0..<6 {
            try encoder.addFrame(noise(frame: index), at: time(Double(index) * 0.1))
            let count = encoder.bytesWritten
            XCTAssertGreaterThanOrEqual(count, previous)
            XCTAssertEqual(count, try fileSize(url), "count must equal what has reached the file")
            previous = count
        }
        XCTAssertGreaterThan(previous, 0)
        try encoder.finish(at: time(0.7))
        XCTAssertGreaterThan(encoder.bytesWritten, previous)
        XCTAssertEqual(encoder.bytesWritten, try fileSize(url))
        XCTAssertEqual(try GIFTestMedia.decode(url).delays.count, 6)
    }

    func testEncoderAbortsAndDeletesItsFileWhenOverBudget() throws {
        let url = directory.appendingPathComponent("over.gif")
        let encoder = try GIFEncoder(url: url, maxBytes: 20_000)
        var thrown: Error?
        for index in 0..<10 {
            do { try encoder.addFrame(noise(frame: index), at: time(Double(index) * 0.1)) }
            catch { thrown = error; break }
        }
        guard case GIFEncoder.EncodingError.overByteBudget(let bytes)? = thrown else {
            return XCTFail("Expected overByteBudget, got \(String(describing: thrown))")
        }
        XCTAssertGreaterThan(bytes, 20_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try encoder.addFrame(noise(frame: 99), at: time(5)))
    }

    // MARK: Exporter

    private func clip(frames: Int = 60) async throws -> VideoCompositionBuilder.Result {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 192, height: 108),
                                                                frameCount: frames, pixelsForFrame: { try self.noise(frame: $0) })
        return try VideoCompositionBuilder.build(asset: AVAsset(url: source),
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: Double(frames) / 30, compositionDuration: Double(frames) / 30)],
            includeAudio: false)
    }

    private func request(_ built: VideoCompositionBuilder.Result, rung: GIFFitRung, output: URL) throws -> GIFExporter.Request {
        let composition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
            renderSize: CGSize(width: rung.width, height: rung.height), duration: built.composition.duration,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(rung.fps)))
        return GIFExporter.Request(asset: built.composition, videoTrack: built.videoTrack, composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), outputURL: output, sourceLease: nil)
    }

    func testExporterOverByteBudgetPublishesNothingAndKeepsAnExistingFile() async throws {
        let built = try await clip()
        let rung = GIFFitRung(fps: 15, width: 192, height: 108)
        let fresh = directory.appendingPathComponent("fresh.gif")
        var tiny = try request(built, rung: rung, output: fresh)
        tiny.maxBytes = 5_000
        do { try await GIFExporter.export(tiny); XCTFail("Over-budget export succeeded") }
        catch GIFEncoder.EncodingError.overByteBudget {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))

        let existing = directory.appendingPathComponent("existing.gif")
        let original = Data("Existing user's file".utf8)
        try original.write(to: existing)
        tiny = try request(built, rung: rung, output: existing)
        tiny.maxBytes = 5_000
        do { try await GIFExporter.export(tiny); XCTFail("Over-budget export succeeded") }
        catch GIFEncoder.EncodingError.overByteBudget {}
        XCTAssertEqual(try Data(contentsOf: existing), original)

        // The same request within budget publishes.
        var roomy = try request(built, rung: rung, output: fresh)
        roomy.maxBytes = 50_000_000
        try await GIFExporter.export(roomy)
        XCTAssertGreaterThan(try fileSize(fresh), 5_000)
    }

    // MARK: Fit runner

    private func planAndMakeRequest(_ built: VideoCompositionBuilder.Result, budget: GIFFitBudget)
        -> ([GIFFitRung], @Sendable (GIFFitRung, URL) async throws -> GIFExporter.Request) {
        let plan = GIFFitPlanner.plan(duration: built.composition.duration.seconds, startWidth: 192, startHeight: 108,
                                      startFPS: 15, budget: budget)
        nonisolated(unsafe) let built = built
        return (plan, { rung, url in
            let composition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
                renderSize: CGSize(width: rung.width, height: rung.height), duration: built.composition.duration,
                frameDuration: CMTime(value: 1, timescale: CMTimeScale(rung.fps)))
            return GIFExporter.Request(asset: built.composition, videoTrack: built.videoTrack, composition: composition,
                timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), outputURL: url, sourceLease: nil)
        })
    }

    func testFitRunnerDowngradesUntilTheFileFitsAndPublishesOnlyTheWinner() async throws {
        let built = try await clip()
        var budget = GIFFitBudget(); budget.minLongEdge = 96
        let (plan, make) = planAndMakeRequest(built, budget: budget)
        XCTAssertGreaterThan(plan.count, 3)

        // Measure the top rung unconstrained, then allow 60% of it.
        let probe = directory.appendingPathComponent("probe.gif")
        try await GIFExporter.export(try request(built, rung: plan[0], output: probe))
        let topSize = try fileSize(probe)
        budget.maxBytes = topSize * 6 / 10

        let destination = directory.appendingPathComponent("fit.gif")
        let attempts = AttemptLog()
        let outcome = try await GIFFitExporter.run(plan: plan, budget: budget, destination: destination,
                                                   makeRequest: make) { attempts.record($0) }
        XCTAssertGreaterThan(outcome.attempt, 1, "the first rung is over budget")
        XCTAssertEqual(outcome.failedAttempts.count, outcome.attempt - 1)
        XCTAssertEqual(outcome.failedAttempts.map(\.rung), Array(plan.prefix(outcome.attempt - 1)))
        XCTAssertEqual(outcome.rung, plan[outcome.attempt - 1])
        XCTAssertEqual(outcome.fileURL, destination)
        XCTAssertLessThanOrEqual(outcome.fileSize, budget.maxBytes)
        XCTAssertEqual(outcome.fileSize, try fileSize(destination))
        let decoded = try GIFTestMedia.decode(destination)
        XCTAssertEqual(decoded.size, CGSize(width: outcome.rung.width, height: outcome.rung.height))
        XCTAssertEqual(decoded.delays.reduce(0, +), 2, accuracy: 0.05)
        XCTAssertEqual(attempts.indices.max(), outcome.attempt - 1)
        XCTAssertEqual(Set(attempts.counts), [plan.count])
        // Nothing else is left beside the winner (and the probe).
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".gif") }
        XCTAssertEqual(Set(leftovers), ["fit.gif", "probe.gif"])
    }

    func testFitRunnerThrowsCannotFitWithStreamAdviceAndLeavesNothing() async throws {
        let built = try await clip()
        var budget = GIFFitBudget(); budget.minLongEdge = 96; budget.maxBytes = 1_000
        let (plan, make) = planAndMakeRequest(built, budget: budget)
        let destination = directory.appendingPathComponent("never.gif")
        do {
            _ = try await GIFFitExporter.run(plan: plan, budget: budget, destination: destination, makeRequest: make)
            XCTFail("Expected cannotFit")
        } catch let error as GIFFitError {
            guard case .cannotFit(let attempts, _) = error else { return XCTFail() }
            XCTAssertEqual(attempts.map(\.rung), plan)
            XCTAssertTrue(attempts.allSatisfy { $0.bytesWritten > 1_000 })
            XCTAssertTrue(error.localizedDescription.contains("Stream"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFitRunnerWithAnEmptyPlanCannotFit() async throws {
        let destination = directory.appendingPathComponent("empty.gif")
        do {
            _ = try await GIFFitExporter.run(plan: [], destination: destination, makeRequest: { _, _ in
                XCTFail("No request should be built"); throw CancellationError()
            })
            XCTFail("Expected cannotFit")
        } catch GIFFitError.cannotFit(let attempts, _) {
            XCTAssertTrue(attempts.isEmpty)
        }
    }

    func testFitRunnerStopsWhenCancelledBetweenAttempts() async throws {
        let built = try await clip()
        var budget = GIFFitBudget(); budget.minLongEdge = 96; budget.maxBytes = 1_000
        let (plan, make) = planAndMakeRequest(built, budget: budget)
        let cancellation = MediaExportCancellation()
        let built2 = AttemptLog()
        let destination = directory.appendingPathComponent("cancelled.gif")
        do {
            _ = try await GIFFitExporter.run(plan: plan, budget: budget, destination: destination, makeRequest: { rung, url in
                built2.requestCount += 1
                if built2.requestCount == 2 { cancellation.cancel() }
                return try await make(rung, url)
            }, cancellation: cancellation)
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(built2.requestCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _indices: [Int] = [], _counts: [Int] = []
    var requestCount = 0
    var indices: [Int] { lock.lock(); defer { lock.unlock() }; return _indices }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return _counts }
    func record(_ progress: GIFFitExporter.Progress) {
        lock.lock(); defer { lock.unlock() }
        _indices.append(progress.attemptIndex); _counts.append(progress.attemptCount)
    }
}
