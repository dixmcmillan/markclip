import XCTest

/// The serial queue, driven through real `ExportRun`s with fake stages.
@MainActor
final class ExportQueueTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var renderer: FakeRenderer!
    private var remote: FakeRemote!
    private var records: ExportRecordStore!
    private var coordinator: MediaExportCoordinator!
    private var results: [ExportRunResult] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("export-queue-" + UUID().uuidString)
        archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        renderer = FakeRenderer()
        remote = FakeRemote()
        records = ExportRecordStore(url: nil)
        coordinator = MediaExportCoordinator()
        results = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeQueue() -> ExportQueue {
        let env = ExportEnvironment(projectName: "My Clip", renderer: renderer, records: records, remote: { [remote] in remote },
                                    localFolderForUploads: { [archive] in archive! }, coordinator: coordinator,
                                    clock: InstantExportClock(), offline: false,
                                    stagingRoot: root.appendingPathComponent("staging"))
        let queue = ExportQueue(environment: env)
        queue.onResult = { [unowned self] in results.append($0) }
        return queue
    }

    private func folder(_ name: String) -> ExportPreset {
        ExportPreset(name: name, format: .h264, destination: .folder(bookmark: nil, path: archive.path))
    }
    private func stream(_ name: String = "Stream") -> ExportPreset {
        ExportPreset(name: name, format: .h264, captions: .off, destination: .stream, alsoSaveLocally: false)
    }

    // MARK: Ordering

    func testRunsStartImmediatelyAndInOrderWhileBusy() async {
        renderer.stalls = true
        let queue = makeQueue()
        let a = folder("A"), b = folder("B"), c = folder("C")
        queue.enqueue(a)
        XCTAssertTrue(queue.isBusy)
        XCTAssertEqual(queue.state.current?.presetID, a.id)
        queue.enqueue(b)
        queue.enqueue(c)
        XCTAssertEqual(queue.state.waiting.map(\.presetName), ["B", "C"])
        XCTAssertEqual(queue.queuedCount, 2)

        renderer.release()
        let done = await waitUntil { results.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(results.map(\.presetName), ["A", "B", "C"])
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertFalse(queue.isBusy)
        XCTAssertEqual(queue.state.lastResult?.presetName, "C")
        XCTAssertEqual(queue.state.waiting, [])
    }

    func testOnlyOneRunExecutesAtATime() async {
        renderer.stalls = true
        let queue = makeQueue()
        queue.enqueue(folder("A"))
        queue.enqueue(folder("B"))
        let started = await waitUntil { renderer.requests.count == 1 }
        XCTAssertTrue(started)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(renderer.requests.count, 1, "B waits for A")
        XCTAssertEqual(coordinator.activeCount, 1)
        renderer.release()
        let done = await waitUntil { results.count == 2 }
        XCTAssertTrue(done)
    }

    func testIdenticalWaitingRequestIsNotQueuedTwice() async {
        renderer.stalls = true
        let queue = makeQueue()
        let a = folder("A"), b = folder("B")
        queue.enqueue(a)
        let first = queue.enqueue(b)
        let second = queue.enqueue(b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(queue.queuedCount, 1)
        var overrides = ExportOverrides()
        overrides.audio = .mute
        queue.enqueue(b, overrides: overrides)
        XCTAssertEqual(queue.queuedCount, 2, "Different Adjust overrides are a different request")
        queue.cancelCurrent(dropQueued: true)
        let done = await waitUntil { !queue.isBusy }
        XCTAssertTrue(done)
    }

    func testCancelQueuedRemovesOnlyThatEntry() async {
        renderer.stalls = true
        let queue = makeQueue()
        queue.enqueue(folder("A"))
        let b = queue.enqueue(folder("B"))
        queue.enqueue(folder("C"))
        queue.cancelQueued(ticket: b)
        XCTAssertEqual(queue.state.waiting.map(\.presetName), ["C"])
        renderer.release()
        let done = await waitUntil { results.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(results.map(\.presetName), ["A", "C"])
    }

    // MARK: Cancel

    func testCancelCurrentStopsItAndTheNextOneStarts() async {
        renderer.stalls = true
        let queue = makeQueue()
        queue.enqueue(folder("A"))
        queue.enqueue(folder("B"))
        let started = await waitUntil { renderer.requests.count == 1 }
        XCTAssertTrue(started)
        queue.cancelCurrent()
        XCTAssertEqual(queue.state.current?.isCancelling, true)
        renderer.stalls = false
        let done = await waitUntil { results.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(results[0].presetName, "A")
        XCTAssertTrue(results[0].wasCancelled)
        XCTAssertEqual(results[0].cancelledAt, .rendering)
        XCTAssertEqual(results[1].presetName, "B")
        XCTAssertTrue(results[1].succeeded)
    }

    func testCancelCurrentCanDropEverythingQueued() async {
        renderer.stalls = true
        let queue = makeQueue()
        queue.enqueue(folder("A"))
        queue.enqueue(folder("B"))
        queue.enqueue(folder("C"))
        let started = await waitUntil { renderer.requests.count == 1 }
        XCTAssertTrue(started)
        queue.cancelCurrent(dropQueued: true)
        XCTAssertEqual(queue.queuedCount, 0)
        let done = await waitUntil { !queue.isBusy }
        XCTAssertTrue(done)
        XCTAssertEqual(results.map(\.presetName), ["A"])
        XCTAssertTrue(results[0].wasCancelled)
        XCTAssertEqual(renderer.requests.count, 1)
    }

    func testCancelWhileUploadingStopsTheUpload() async {
        remote.stallUpload(true)
        let queue = makeQueue()
        queue.enqueue(stream())
        let uploading = await waitUntil { queue.state.current?.stage == .uploading }
        XCTAssertTrue(uploading)
        queue.cancelCurrent()
        let done = await waitUntil { results.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(results[0].cancelledAt, .uploading)
        XCTAssertNil(records.record(for: results[0].presetID)?.remoteID)
    }

    func testCancelWithNothingRunningIsHarmless() {
        let queue = makeQueue()
        queue.cancelCurrent(dropQueued: true)
        XCTAssertFalse(queue.isBusy)
    }

    // MARK: Observable state

    func testObserversSeeTheStagesProgressAndTheResult() async {
        var seen: [ExportQueueState] = []
        let queue = makeQueue()
        queue.observe { seen.append($0) }
        queue.enqueue(stream())
        let done = await waitUntil { results.count == 1 }
        XCTAssertTrue(done)
        let stages = seen.compactMap(\.current?.stage)
        XCTAssertEqual(stages.first, .preparing)
        XCTAssertTrue(stages.contains(.rendering))
        XCTAssertTrue(stages.contains(.uploading))
        XCTAssertEqual(seen.compactMap(\.current?.presetName).first, "Stream")
        let fractions = seen.compactMap(\.current?.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertNil(seen.last?.current)
        XCTAssertEqual(seen.last?.lastResult?.presetName, "Stream")
        XCTAssertEqual(seen.last?.lastResult?.succeeded, true)
    }

    func testFailureIsReportedAsTheLastResult() async {
        renderer.failure = FakeRemote.Failure(message: "no disk space")
        let queue = makeQueue()
        queue.enqueue(folder("A"))
        let done = await waitUntil { results.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(queue.state.lastResult?.failure?.message, "no disk space")
        XCTAssertFalse(queue.isBusy)
    }

    // MARK: Lifetime and polling

    func testQueueKeepsRunningAfterItsOwnerLetsGo() async {
        renderer.stalls = true
        var queue: ExportQueue? = makeQueue()
        queue?.enqueue(folder("A"))
        queue?.enqueue(folder("B"))
        queue = nil   // the editor window closed
        renderer.release()
        let done = await waitUntil { results.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(results.map(\.presetName), ["A", "B"])
    }

    func testStreamUploadStartsStatusPollingAfterTheRun() async {
        remote.script(statuses: [.processing(percent: 5), .ready], for: "uid-1")
        let queue = makeQueue()
        queue.enqueue(stream())
        let done = await waitUntil { results.count == 1 }
        XCTAssertTrue(done)
        await queue.sync.waitForPolling()
        let preset = results[0].presetID
        XCTAssertEqual(records.record(for: preset)?.state, .ready)
    }

    func testPopoverRefreshHookResolvesProcessingRecordsAndPendingDeletes() async {
        let preset = UUID()
        records.update(preset) {
            $0.remoteKind = .stream; $0.remoteID = "uid-new"; $0.state = .processing; $0.pendingDeleteUIDs = ["uid-old"]
        }
        remote.script(statuses: [.ready], for: "uid-new")
        let queue = makeQueue()
        await queue.refreshRemoteState()
        XCTAssertEqual(records.record(for: preset)?.state, .ready)
        XCTAssertEqual(records.record(for: preset)?.pendingDeleteUIDs, [])
        XCTAssertEqual(remote.calls, ["status:uid-new", "delete:uid-old"])
    }

    func testOldVideoSurvivesUntilTheReuploadIsReady() async {
        let queue = makeQueue()
        let preset = stream()
        queue.enqueue(preset)
        var done = await waitUntil { results.count == 1 }
        XCTAssertTrue(done)
        await queue.sync.waitForPolling()
        XCTAssertEqual(records.record(for: preset.id)?.state, .ready)

        remote.script(statuses: [.processing(percent: 50), .ready], for: "uid-2")
        queue.enqueue(preset)
        done = await waitUntil { results.count == 2 }
        XCTAssertTrue(done)
        await queue.sync.waitForPolling()

        let calls = remote.calls
        let deleteIndex = try? XCTUnwrap(calls.firstIndex(of: "delete:uid-1"))
        let statusIndexes = calls.indices.filter { calls[$0] == "status:uid-2" }
        XCTAssertEqual(statusIndexes.count, 2, "One processing check, then the ready one")
        XCTAssertTrue(statusIndexes.allSatisfy { $0 < (deleteIndex ?? 0) }, "uid-1 is deleted after uid-2 reports ready")
        XCTAssertEqual(records.record(for: preset.id)?.remoteID, "uid-2")
        XCTAssertEqual(records.record(for: preset.id)?.pendingDeleteUIDs, [])
    }
}
