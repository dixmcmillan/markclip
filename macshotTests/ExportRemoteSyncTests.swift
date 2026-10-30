import XCTest

/// Post-upload bookkeeping: polling Stream until ready, and deleting the video
/// a re-upload replaced only after the new one is ready.
@MainActor
final class ExportRemoteSyncTests: XCTestCase {
    private var records: ExportRecordStore!
    private var remote: FakeRemote!
    private var clock: InstantExportClock!
    private let presetID = UUID()

    override func setUp() {
        records = ExportRecordStore(url: nil)
        remote = FakeRemote()
        clock = InstantExportClock()
    }

    private func makeSync(remoteAvailable: Bool = true) -> ExportRemoteSync {
        let service: ExportRemoteService? = remoteAvailable ? remote : nil
        return ExportRemoteSync(records: records, remote: { service }, clock: clock, interval: 5)
    }

    /// A re-upload in progress: `uid-new` is processing and `uid-old` waits to be deleted.
    private func seedReupload() {
        records.update(presetID) {
            $0.remoteKind = .stream
            $0.remoteID = "uid-new"
            $0.state = .processing
            $0.pendingDeleteUIDs = ["uid-old"]
        }
    }

    func testOldVideoIsDeletedOnlyAfterTheNewOneIsReady() async {
        seedReupload()
        remote.script(statuses: [.processing(percent: 10), .processing(percent: 80), .ready], for: "uid-new")
        let sync = makeSync()
        sync.startPollingIfNeeded()
        XCTAssertTrue(sync.isPolling)
        await sync.waitForPolling()

        XCTAssertEqual(remote.calls, ["status:uid-new", "status:uid-new", "status:uid-new", "delete:uid-old"])
        let record = records.record(for: presetID)
        XCTAssertEqual(record?.state, .ready)
        XCTAssertEqual(record?.pendingDeleteUIDs, [])
        XCTAssertFalse(sync.isPolling)
    }

    func testPollingWaitsTheConfiguredIntervalBetweenChecks() async {
        seedReupload()
        remote.script(statuses: [.processing(percent: nil), .processing(percent: nil), .ready], for: "uid-new")
        let sync = makeSync()
        sync.startPollingIfNeeded()
        await sync.waitForPolling()
        XCTAssertEqual(clock.sleeps, [5, 5])
    }

    func testProgressIsExposedWhileProcessing() async {
        seedReupload()
        remote.script(statuses: [.processing(percent: 42), .ready], for: "uid-new")
        let sync = makeSync()
        await sync.refreshAll()
        // refreshAll did one pass (processing 42%) and started polling, which finished.
        await sync.waitForPolling()
        XCTAssertNil(sync.processingPercent[presetID.uuidString], "Cleared once the video is ready")
    }

    func testFailedProcessingKeepsTheOldVideo() async {
        seedReupload()
        remote.script(statuses: [.failed("bad codec")], for: "uid-new")
        let sync = makeSync()
        sync.startPollingIfNeeded()
        await sync.waitForPolling()
        let record = records.record(for: presetID)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.errorText, "bad codec")
        XCTAssertEqual(record?.pendingDeleteUIDs, ["uid-old"])
        XCTAssertFalse(remote.calls.contains { $0.hasPrefix("delete") })
    }

    func testVideoRemovedFromTheDashboardIsReportedFailed() async {
        seedReupload()
        remote.script(statuses: [.missing], for: "uid-new")
        let sync = makeSync()
        await sync.refreshAll()
        XCTAssertEqual(records.record(for: presetID)?.state, .failed)
        XCTAssertFalse(remote.calls.contains { $0.hasPrefix("delete") })
    }

    func testFailedDeleteStaysPendingAndIsRetriedOnTheNextRefresh() async {
        seedReupload()
        remote.script(statuses: [.ready], for: "uid-new")
        remote.failNextDeletes(1)
        let sync = makeSync()
        await sync.refreshAll()
        XCTAssertEqual(records.record(for: presetID)?.state, .ready)
        XCTAssertEqual(records.record(for: presetID)?.pendingDeleteUIDs, ["uid-old"], "A failed delete is kept for the retry")

        await sync.refreshAll()   // the popover opens again
        XCTAssertEqual(records.record(for: presetID)?.pendingDeleteUIDs, [])
        XCTAssertEqual(remote.calls.filter { $0 == "delete:uid-old" }.count, 2)
    }

    func testEveryReplacedVideoIsDeleted() async {
        records.update(presetID) {
            $0.remoteKind = .stream; $0.remoteID = "uid-3"; $0.state = .processing
            $0.pendingDeleteUIDs = ["uid-1", "uid-2"]
        }
        remote.script(statuses: [.ready], for: "uid-3")
        await makeSync().refreshAll()
        XCTAssertEqual(remote.calls.filter { $0.hasPrefix("delete") }, ["delete:uid-1", "delete:uid-2"])
        XCTAssertEqual(records.record(for: presetID)?.pendingDeleteUIDs, [])
    }

    func testReadyRecordWithoutPendingDeletesMakesNoCalls() async {
        records.update(presetID) { $0.remoteKind = .stream; $0.remoteID = "uid-1"; $0.state = .ready }
        await makeSync().refreshAll()
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testNetworkErrorsKeepTheStateAndPollingGivesUpAfterTwelvePasses() async {
        seedReupload()
        remote.failStatus(FakeRemote.Failure(message: "offline"))
        let sync = makeSync()
        sync.startPollingIfNeeded()
        await sync.waitForPolling()
        XCTAssertEqual(remote.statusCallCount, 12)
        XCTAssertEqual(records.record(for: presetID)?.state, .processing, "A network error is not a failed video")
        XCTAssertEqual(records.record(for: presetID)?.pendingDeleteUIDs, ["uid-old"])
        XCTAssertFalse(sync.isPolling)
    }

    func testAnUploadCutOffByQuitIsMarkedFailedUnlessARunIsActive() async {
        let other = UUID()
        records.update(presetID) { $0.state = .uploading }
        records.update(other) { $0.state = .uploading }
        let sync = makeSync()
        sync.activePresetIDs = { [other] in [other] }
        await sync.refreshAll()
        XCTAssertEqual(records.record(for: presetID)?.state, .failed)
        XCTAssertNotNil(records.record(for: presetID)?.errorText)
        XCTAssertEqual(records.record(for: other)?.state, .uploading)
    }

    func testNothingRunsWithoutAnAccount() async {
        seedReupload()
        let sync = makeSync(remoteAvailable: false)
        sync.startPollingIfNeeded()
        XCTAssertFalse(sync.isPolling)
        await sync.refreshAll()
        XCTAssertEqual(records.record(for: presetID)?.state, .processing)
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testReplacementDuringACheckIsNotOverwrittenByTheStaleResult() async {
        seedReupload()
        remote.script(statuses: [.ready], for: "uid-new")
        remote.script(statuses: [.processing(percent: nil)], for: "uid-newer")
        let sync = makeSync()
        remote.holdStatus(true)
        let refresh = Task { await sync.refreshAll() }
        let called = await waitUntil { remote.statusCallCount == 1 }
        XCTAssertTrue(called)
        // A newer upload lands while the status call for uid-new is in flight.
        records.update(presetID) { $0.remoteID = "uid-newer"; $0.state = .processing }
        remote.holdStatus(false)
        await refresh.value
        sync.stopPolling()
        XCTAssertEqual(records.record(for: presetID)?.remoteID, "uid-newer")
        XCTAssertEqual(records.record(for: presetID)?.state, .processing)
        XCTAssertFalse(remote.calls.contains { $0.hasPrefix("delete") })
    }

    // MARK: TrainWithDixon

    func testTrainWithDixonUploadsArePolledThroughCoachOSEvenWithoutCloudflare() async {
        let managed = FakeManagedRemote(remote: remote)
        records.update(presetID) {
            $0.remoteKind = .trainWithDixon
            $0.remoteID = "media-upload-reservation:1"
            $0.state = .processing
        }
        remote.script(statuses: [.processing(percent: 30), .ready], for: "media-upload-reservation:1")
        let sync = ExportRemoteSync(records: records, remote: { nil }, trainWithDixon: { managed },
                                    clock: clock, interval: 5)
        sync.startPollingIfNeeded()
        XCTAssertTrue(sync.isPolling)
        await sync.waitForPolling()

        XCTAssertEqual(remote.calls, ["status:media-upload-reservation:1", "status:media-upload-reservation:1"])
        XCTAssertEqual(records.record(for: presetID)?.state, .ready)
    }

    func testTrainWithDixonUploadsAreNotPolledWithoutACoachOSAddress() async {
        records.update(presetID) {
            $0.remoteKind = .trainWithDixon
            $0.remoteID = "media-upload-reservation:1"
            $0.state = .processing
        }
        let sync = makeSync()
        sync.startPollingIfNeeded()
        XCTAssertFalse(sync.isPolling, "The Cloudflare service never checks a Coach OS reservation")
        XCTAssertTrue(remote.calls.isEmpty)
    }

    func testMissingTrainWithDixonUploadSaysCoachOSLostIt() async {
        let managed = FakeManagedRemote(remote: remote)
        records.update(presetID) {
            $0.remoteKind = .trainWithDixon
            $0.remoteID = "media-upload-reservation:1"
            $0.state = .processing
        }
        remote.script(statuses: [.missing], for: "media-upload-reservation:1")
        let sync = ExportRemoteSync(records: records, remote: { nil }, trainWithDixon: { managed },
                                    clock: clock, interval: 5)
        await sync.refreshAll()
        XCTAssertEqual(records.record(for: presetID)?.state, .failed)
        XCTAssertEqual(records.record(for: presetID)?.errorText, "Coach OS no longer has this upload.")
    }
}
