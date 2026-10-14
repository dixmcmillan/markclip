import XCTest

/// "Save As…": a one-off export of a preset's encoding to a chosen file. It
/// must not number the name, upload, or move the preset's recorded local file.
@MainActor
final class ExportSaveAsTests: XCTestCase {
    private var root: URL!
    private var renderer: FakeRenderer!
    private var remote: FakeRemote!
    private var records: ExportRecordStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("export-saveas-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        renderer = FakeRenderer()
        remote = FakeRemote()
        records = ExportRecordStore(url: nil)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ preset: ExportPreset, to url: URL) async -> ExportRunResult {
        var overrides = ExportOverrides()
        overrides.saveAsURL = url
        let env = ExportEnvironment(projectName: "My Clip", renderer: renderer, records: records, remote: { [remote] in remote },
                                    localFolderForUploads: { [root] in root! }, coordinator: MediaExportCoordinator(),
                                    clock: InstantExportClock(), stagingRoot: root.appendingPathComponent("staging"))
        return await ExportRun(preset: preset, overrides: overrides, environment: env).run()
    }

    private var archive: ExportPreset {
        ExportPreset(id: ExportPresetStore.archiveID, name: "Archive", format: .hevc,
                     destination: .folder(bookmark: nil, path: root.appendingPathComponent("Archive").path))
    }

    func testWritesExactlyTheChosenFile() async throws {
        let target = root.appendingPathComponent("elsewhere/Chosen name.mp4")
        let result = await run(archive, to: target)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.localFile, target)
        XCTAssertEqual(try Data(contentsOf: target), renderer.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive").path),
                       "the preset's own folder isn't used")
    }

    func testReplacesAnExistingFileTheUserConfirmed() async throws {
        let target = root.appendingPathComponent("Same.mp4")
        try Data("old".utf8).write(to: target)
        let result = await run(archive, to: target)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try Data(contentsOf: target), renderer.bytes)
        XCTAssertEqual(result.localFile?.lastPathComponent, "Same.mp4", "no numbering")
    }

    func testDoesNotTouchThePresetsRecord() async {
        let before = ExportRecord(localFile: ExportFileRecord(path: "/last/Preset.mp4", size: 1, mtime: 1))
        records.update(ExportPresetStore.archiveID) { $0 = before }
        _ = await run(archive, to: root.appendingPathComponent("A.mp4"))
        XCTAssertEqual(records.record(for: ExportPresetStore.archiveID), before)
    }

    func testNeverUploadsEvenForAnUploadPreset() async {
        let stream = ExportPreset(id: ExportPresetStore.streamID, name: "Stream", format: .h264, destination: .stream, alsoSaveLocally: true)
        let target = root.appendingPathComponent("Stream copy.mp4")
        let result = await run(stream, to: target)
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.remoteID)
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertNil(records.record(for: ExportPresetStore.streamID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testExtensionFollowsTheFormat() async {
        let gif = ExportPreset(name: "Loop", format: .gif, audio: .mute, destination: .images)
        let result = await run(gif, to: root.appendingPathComponent("Loop.mp4"))
        XCTAssertEqual(result.localFile?.lastPathComponent, "Loop.gif")
        let video = await run(archive, to: root.appendingPathComponent("Video.mov"))
        XCTAssertEqual(video.localFile?.lastPathComponent, "Video.mp4")
    }

    func testSoftCaptionsWriteTheSidecarBesideTheChosenFile() async throws {
        renderer.vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n"
        var preset = archive
        preset.captions = .soft
        let target = root.appendingPathComponent("With captions.mp4")
        let result = await run(preset, to: target)
        XCTAssertEqual(result.captionsSidecar?.lastPathComponent, "With captions.vtt")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("With captions.vtt"), encoding: .utf8), renderer.vtt)
    }

    func testGIFSaveAsDoesNotRunAutoFit() async {
        let gif = ExportPreset(name: "Loop", format: .gif, audio: .mute, destination: .images)
        _ = await run(gif, to: root.appendingPathComponent("Loop.gif"))
        XCTAssertEqual(renderer.requests.first?.fitGIF, false)
    }

    func testOverridesIgnoreTheDestinationInIsEmpty() {
        var overrides = ExportOverrides()
        overrides.saveAsURL = root
        XCTAssertTrue(overrides.isEmpty, "a Save As destination isn't an adjustment")
        overrides.quality = .low
        XCTAssertFalse(overrides.isEmpty)
    }

    func testQueueTreatsDifferentDestinationsAsDifferentRequests() async {
        let env = ExportEnvironment(projectName: "My Clip", renderer: { let r = FakeRenderer(); r.stalls = true; return r }(), records: records,
                                    remote: { nil }, localFolderForUploads: { [root] in root! }, coordinator: MediaExportCoordinator(),
                                    clock: InstantExportClock(), stagingRoot: root.appendingPathComponent("staging2"))
        let queue = ExportQueue(environment: env)
        var a = ExportOverrides(); a.saveAsURL = root.appendingPathComponent("a.mp4")
        var b = ExportOverrides(); b.saveAsURL = root.appendingPathComponent("b.mp4")
        queue.enqueue(archive, overrides: a)
        let t1 = queue.enqueue(archive, overrides: b)
        let t2 = queue.enqueue(archive, overrides: b)
        XCTAssertEqual(t1, t2, "the same request waiting twice is queued once")
        XCTAssertEqual(queue.queuedCount, 1)
        queue.cancelCurrent(dropQueued: true)
        _ = await waitUntil { !queue.isBusy }
    }
}
