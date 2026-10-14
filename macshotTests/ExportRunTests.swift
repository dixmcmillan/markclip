import XCTest

/// `ExportRun` orchestration with fake stages. Nothing encodes and nothing
/// touches the network; the "render" writes a few bytes to a file.
@MainActor
final class ExportRunTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var staging: URL!
    private var renderer: FakeRenderer!
    private var remote: FakeRemote!
    private var records: ExportRecordStore!
    private var coordinator: MediaExportCoordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("export-run-" + UUID().uuidString)
        archive = root.appendingPathComponent("Archive")
        staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        renderer = FakeRenderer()
        remote = FakeRemote()
        records = ExportRecordStore(url: root.appendingPathComponent("Clip.exports.json"))
        coordinator = MediaExportCoordinator()
        folderPreset = ExportPreset(name: "Archive", format: .hevc, destination: .folder(bookmark: nil, path: archive.path))
        loopPreset = ExportPreset(name: "Loop", format: .gif, audio: .mute, destination: .images)
        folderPresetSoft = ExportPreset(name: "Soft", format: .hevc, captions: .soft,
                                        destination: .folder(bookmark: nil, path: archive.path))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Helpers

    private func environment(remote service: ExportRemoteService?? = nil, offline: Bool = false,
                             name: String = "My Clip") -> ExportEnvironment {
        let resolved: ExportRemoteService? = service ?? remote
        return ExportEnvironment(projectName: name, renderer: renderer, records: records, remote: { resolved },
                                 localFolderForUploads: { [archive] in archive! },
                                 coordinator: coordinator, clock: InstantExportClock(), offline: offline,
                                 stagingRoot: staging, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // Placeholders; setUp points them at the temp archive folder.
    private var folderPreset = ExportPreset(name: "Archive")
    private var loopPreset = ExportPreset(name: "Loop")
    private var folderPresetSoft = ExportPreset(name: "Soft")
    private func streamPreset(alsoSave: Bool = true, captions: ExportCaptionsMode = .soft, signed: Bool = false) -> ExportPreset {
        ExportPreset(name: "Stream", format: .h264, captions: captions, destination: .stream,
                     alsoSaveLocally: alsoSave, requireSignedURLs: signed)
    }

    private func run(_ preset: ExportPreset, overrides: ExportOverrides = ExportOverrides(),
                     env: ExportEnvironment? = nil) async -> ExportRunResult {
        await ExportRun(preset: preset, overrides: overrides, environment: env ?? environment()).run()
    }

    private func archiveFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []).sorted()
    }

    private func stagingIsEmpty() async -> Bool {
        // The staging folder is removed on a background queue.
        await waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty }
    }

    // MARK: Folder presets

    func testFolderPresetPublishesAFileNamedAfterTheProject() async throws {
        let result = await run(folderPreset)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mp4")
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("My Clip.mp4")), renderer.bytes)
        let recorded = try XCTUnwrap(records.record(for: folderPreset.id)?.localFile)
        XCTAssertEqual(recorded.size, Int64(renderer.bytes.count))
        XCTAssertNil(records.record(for: folderPreset.id)?.remoteID)
        XCTAssertTrue(remote.calls.isEmpty)
        let staged = await stagingIsEmpty()
        XCTAssertTrue(staged)
    }

    func testProjectNameIsSanitizedForTheFileName() async {
        let result = await run(folderPreset, env: environment(name: "Demo/2: final"))
        XCTAssertEqual(result.localFile?.lastPathComponent, "Demo-2- final.mp4")
    }

    func testMissingArchiveFolderIsCreated() async {
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let result = await run(folderPreset)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testRerunOverwritesTheFileThisPresetWrote() async throws {
        let preset = folderPreset
        _ = await run(preset)
        renderer.bytes = Data("second render, longer".utf8)
        let result = await run(preset)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(archiveFiles(), ["My Clip.mp4"])
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("My Clip.mp4")), renderer.bytes)
        XCTAssertEqual(records.record(for: preset.id)?.localFile?.size, Int64(renderer.bytes.count))
    }

    func testReplacedFileIsKeptAndTheNewExportIsNumbered() async throws {
        let preset = folderPreset
        _ = await run(preset)
        let original = archive.appendingPathComponent("My Clip.mp4")
        try Data("edited by the user in another app".utf8).write(to: original)
        let result = await run(preset)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip 2.mp4")
        XCTAssertEqual(archiveFiles(), ["My Clip 2.mp4", "My Clip.mp4"])
        XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), "edited by the user in another app")
        XCTAssertEqual(records.record(for: preset.id)?.localFile?.path, archive.appendingPathComponent("My Clip 2.mp4").path)
        // And the numbered copy is the one it overwrites from now on.
        let third = await run(preset)
        XCTAssertEqual(third.localFile?.lastPathComponent, "My Clip 2.mp4")
        XCTAssertEqual(archiveFiles(), ["My Clip 2.mp4", "My Clip.mp4"])
    }

    func testDifferentPresetsDoNotOverwriteEachOther() async {
        let other = ExportPreset(name: "Other", format: .h264, destination: .folder(bookmark: nil, path: archive.path))
        _ = await run(folderPreset)
        let result = await run(other)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip 2.mp4")
    }

    func testDirectSourceCopyKeepsTheSourcesExtensionAndTheSource() async throws {
        let source = root.appendingPathComponent("source.mov")
        try Data("original".utf8).write(to: source)
        renderer.directFile = source
        let result = await run(folderPreset)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "A direct copy must not consume the source")
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("My Clip.mov")), Data("original".utf8))
    }

    func testPresetSettingsReachTheRenderer() async {
        var overrides = ExportOverrides()
        overrides.format = .h264
        overrides.longEdgeCap = .value(960)
        overrides.audio = .mute
        _ = await run(folderPreset, overrides: overrides)
        let settings = renderer.requests.first?.settings
        XCTAssertEqual(settings?.codec, .h264)
        XCTAssertEqual(settings?.muted, true)
        XCTAssertEqual(Double(settings?.scale ?? 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(renderer.requests.first?.fitGIF, false)
    }

    // MARK: Failures

    func testRenderFailureIsReportedAtItsStageAndPublishesNothing() async {
        renderer.failure = FakeRemote.Failure(message: "encoder exploded")
        let result = await run(folderPreset)
        XCTAssertEqual(result.failure?.stage, .rendering)
        XCTAssertEqual(result.failure?.message, "encoder exploded")
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.localFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("My Clip.mp4").path))
        XCTAssertFalse(coordinator.hasActiveJobs)
    }

    func testFailedUploadKeepsTheLocalFileAndRecordsFailedState() async throws {
        remote.failUpload(FakeRemote.Failure(message: "network down"))
        let preset = streamPreset()
        let result = await run(preset)
        XCTAssertEqual(result.failure?.stage, .uploading)
        XCTAssertEqual(result.failure?.message, "network down")
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("My Clip.mp4").path))
        let record = try XCTUnwrap(records.record(for: preset.id))
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.errorText, "network down")
        XCTAssertNotNil(record.localFile)
        XCTAssertNil(record.remoteID)
    }

    func testFailedReuploadKeepsThePreviousVideoRecorded() async throws {
        let preset = streamPreset(alsoSave: false)
        _ = await run(preset)
        records.update(preset.id) { $0.state = .ready }
        remote.failUpload(FakeRemote.Failure(message: "boom"))
        let result = await run(preset)
        XCTAssertEqual(result.failure?.stage, .uploading)
        let record = try XCTUnwrap(records.record(for: preset.id))
        XCTAssertEqual(record.remoteID, "uid-1", "The video that is still live stays recorded")
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.pendingDeleteUIDs, [])
        XCTAssertFalse(remote.calls.contains { $0.hasPrefix("delete") })
    }

    func testCaptionFailureDoesNotFailTheUpload() async throws {
        renderer.vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n"
        remote.failCaptions(FakeRemote.Failure(message: "captions rejected"))
        let preset = streamPreset()
        let result = await run(preset)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.captionsError, "captions rejected")
        XCTAssertEqual(records.record(for: preset.id)?.state, .processing)
        XCTAssertNil(records.record(for: preset.id)?.captionsLanguage)
    }

    // MARK: Local copy on/off for uploads

    func testStreamWithAlsoSaveLocallySavesAndUploadsFromStaging() async throws {
        let preset = streamPreset(signed: true)
        let result = await run(preset)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mp4")
        XCTAssertEqual(remote.uploadNames, ["My Clip"])
        XCTAssertEqual(remote.signedFlags, [true])
        XCTAssertEqual(remote.uploadedBytes, [renderer.bytes])
        XCTAssertTrue(try XCTUnwrap(remote.uploadedPaths.first).hasPrefix(staging.resolvingSymlinksInPath().path)
                      || remote.uploadedPaths[0].hasPrefix(staging.path),
                      "Uploads read the staged render, not the user's published copy")
        let record = try XCTUnwrap(records.record(for: preset.id))
        XCTAssertEqual(record.remoteKind, .stream)
        XCTAssertEqual(record.remoteID, "uid-1")
        XCTAssertEqual(record.state, .processing)
        XCTAssertEqual(record.uploadedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(record.localFile)
        XCTAssertEqual(result.remoteID, "uid-1")
    }

    func testUploadOnlyPresetLeavesNoLocalFileAndDiscardsStaging() async throws {
        let preset = streamPreset(alsoSave: false)
        let result = await run(preset)
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.localFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "No folder is created for an upload-only preset")
        XCTAssertEqual(remote.uploadedBytes, [renderer.bytes])
        XCTAssertNil(records.record(for: preset.id)?.localFile)
        let staged = await stagingIsEmpty()
        XCTAssertTrue(staged)
    }

    func testPublishedLocalFilesAreReportedSoTheEditorCanKeepTheDestination() async throws {
        var published: [URL] = []
        var env = environment()
        env.localFilePublished = { published.append($0) }
        let folderResult = await run(folderPreset, env: env)
        XCTAssertEqual(published, [folderResult.localFile].compactMap { $0 })

        // Save As reports the chosen URL too (it may be the source's own path).
        let chosen = root.appendingPathComponent("elsewhere.mp4")
        var overrides = ExportOverrides(); overrides.saveAsURL = chosen
        published.removeAll()
        _ = await run(folderPreset, overrides: overrides, env: env)
        XCTAssertEqual(published.map(\.lastPathComponent), ["elsewhere.mp4"])

        // An upload-only preset publishes nothing locally.
        published.removeAll()
        _ = await run(streamPreset(alsoSave: false), env: env)
        XCTAssertTrue(published.isEmpty)
    }

    func testImagesUploadFitsTheGIFAndRecordsReady() async throws {
        renderer.fitSummary = "fit: 12 fps, 960 px"
        let result = await run(loopPreset)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(renderer.requests.first?.fitGIF, true)
        XCTAssertEqual(renderer.requests.first?.outputURL.pathExtension, "gif")
        XCTAssertEqual(remote.calls, ["uploadImage"])
        let record = try XCTUnwrap(records.record(for: loopPreset.id))
        XCTAssertEqual(record.remoteKind, .images)
        XCTAssertEqual(record.remoteID, "image-1")
        XCTAssertEqual(record.state, .ready)
        XCTAssertEqual(record.fitSummary, "fit: 12 fps, 960 px")
        XCTAssertEqual(result.fitSummary, "fit: 12 fps, 960 px")
    }

    func testPlainFolderGIFSkipsAutoFit() async {
        let gif = ExportPreset(name: "GIF", format: .gif, destination: .folder(bookmark: nil, path: archive.path))
        let result = await run(gif)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.gif")
        XCTAssertEqual(renderer.requests.first?.fitGIF, false)
    }

    // MARK: Captions

    func testSoftCaptionsWriteAVTTBesideTheLocalCopyAndUploadThem() async throws {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n"
        renderer.vtt = vtt
        let preset = streamPreset()
        let result = await run(preset)
        let sidecar = archive.appendingPathComponent("My Clip.vtt")
        XCTAssertEqual(result.captionsSidecar?.lastPathComponent, "My Clip.vtt")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), vtt)
        XCTAssertEqual(remote.calls, ["uploadStream", "putCaptions:uid-1:en:" + vtt])
        XCTAssertEqual(records.record(for: preset.id)?.captionsLanguage, "en")
    }

    func testNumberedVideoGetsAMatchingNumberedVTT() async throws {
        renderer.vtt = "WEBVTT\n\n"
        _ = await run(folderPresetSoft)
        try Data("user's own".utf8).write(to: archive.appendingPathComponent("My Clip.mp4"))
        let result = await run(folderPresetSoft)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip 2.mp4")
        XCTAssertEqual(result.captionsSidecar?.lastPathComponent, "My Clip 2.vtt")
    }

    func testBurnedCaptionsWriteNoSidecarAndUploadNoTrack() async {
        renderer.vtt = "WEBVTT\n\n"
        let result = await run(streamPreset(captions: .burned))
        XCTAssertNil(result.captionsSidecar)
        XCTAssertEqual(remote.calls, ["uploadStream"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("My Clip.vtt").path))
    }

    func testSoftCaptionsWithoutAnyCaptionsWriteNothing() async {
        renderer.vtt = nil
        let result = await run(streamPreset())
        XCTAssertNil(result.captionsSidecar)
        XCTAssertEqual(remote.calls, ["uploadStream"])
    }

    // MARK: Re-upload bookkeeping

    func testReuploadQueuesThePreviousUIDForDeletionButDoesNotDeleteIt() async throws {
        let preset = streamPreset(alsoSave: false)
        _ = await run(preset)
        records.update(preset.id) { $0.state = .ready }
        let result = await run(preset)
        XCTAssertEqual(result.remoteID, "uid-2")
        let record = try XCTUnwrap(records.record(for: preset.id))
        XCTAssertEqual(record.remoteID, "uid-2")
        XCTAssertEqual(record.state, .processing)
        XCTAssertEqual(record.pendingDeleteUIDs, ["uid-1"])
        XCTAssertFalse(remote.calls.contains { $0.hasPrefix("delete") }, "Deleting waits for the new video to be ready")
    }

    // MARK: Availability

    func testOfflineBuildRefusesStreamAndImagesCleanly() async {
        for preset in [streamPreset(), loopPreset] {
            let result = await run(preset, env: environment(offline: true))
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.failure?.stage, .preparing)
            XCTAssertEqual(result.failure?.message, ExportRunError.networkDestinationUnavailable.errorDescription)
            XCTAssertNil(records.record(for: preset.id))
        }
        XCTAssertTrue(renderer.requests.isEmpty, "Nothing renders for a preset that can't be delivered")
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testOfflineBuildStillRunsFolderPresets() async {
        let result = await run(folderPreset, env: environment(offline: true))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mp4")
    }

    func testUnconfiguredCloudflareFailsBeforeRendering() async {
        let result = await run(streamPreset(), env: environment(remote: .some(nil)))
        XCTAssertEqual(result.failure?.message, ExportRunError.cloudflareNotConfigured.errorDescription)
        XCTAssertTrue(renderer.requests.isEmpty)
    }

    func testFormatThatDoesNotMatchTheDestinationFailsBeforeRendering() async {
        var gifToStream = ExportOverrides()
        gifToStream.format = .gif
        let a = await run(streamPreset(), overrides: gifToStream)
        XCTAssertEqual(a.failure?.stage, .preparing)
        var videoToImages = ExportOverrides()
        videoToImages.format = .h264
        let b = await run(loopPreset, overrides: videoToImages)
        XCTAssertEqual(b.failure?.stage, .preparing)
        XCTAssertTrue(renderer.requests.isEmpty)
    }

    // MARK: Cancellation

    /// Cancels the run the moment it enters `stage`.
    private func cancelAtStage(_ stage: ExportStage, preset: ExportPreset) async -> ExportRunResult {
        let run = ExportRun(preset: preset, environment: environment())
        run.onStage = { [unowned run] entered in if entered == stage { run.cancel() } }
        return await run.run()
    }

    func testCancelWhilePreparing() async {
        let preset = streamPreset()
        let result = await cancelAtStage(.preparing, preset: preset)
        XCTAssertEqual(result.cancelledAt, .preparing)
        XCTAssertTrue(renderer.requests.isEmpty)
        XCTAssertNil(records.record(for: preset.id))
    }

    func testCancelWhileRenderingStopsTheRenderAndPublishesNothing() async {
        renderer.stalls = true
        let result = await cancelAtStage(.rendering, preset: streamPreset())
        XCTAssertEqual(result.cancelledAt, .rendering)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(result.localFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(remote.calls.isEmpty)
        XCTAssertFalse(coordinator.hasActiveJobs)
        let staged = await stagingIsEmpty()
        XCTAssertTrue(staged)
    }

    func testCancelWhilePublishingPublishesNothing() async {
        let preset = folderPreset
        let result = await cancelAtStage(.publishing, preset: preset)
        XCTAssertEqual(result.cancelledAt, .publishing)
        XCTAssertNil(result.localFile)
        XCTAssertEqual(archiveFiles(), [])
        XCTAssertNil(records.record(for: preset.id)?.localFile)
    }

    func testCancelWhileUploadingKeepsTheLocalCopyAndRestoresTheRecord() async throws {
        remote.stallUpload(true)
        let preset = streamPreset()
        // An earlier, ready upload exists.
        records.update(preset.id) { $0.remoteKind = .stream; $0.remoteID = "uid-old"; $0.state = .ready }
        let result = await cancelAtStage(.uploading, preset: preset)
        XCTAssertEqual(result.cancelledAt, .uploading)
        XCTAssertEqual(result.localFile?.lastPathComponent, "My Clip.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("My Clip.mp4").path))
        let record = try XCTUnwrap(records.record(for: preset.id))
        XCTAssertEqual(record.state, .ready, "A cancelled upload leaves the previous video as it was")
        XCTAssertEqual(record.remoteID, "uid-old")
        XCTAssertNotNil(record.localFile)
        XCTAssertFalse(coordinator.hasActiveJobs)
    }

    func testCancelWhileUploadingCaptionsKeepsTheUploadedVideo() async throws {
        renderer.vtt = "WEBVTT\n\n"
        remote.stallCaptions(true)
        let preset = streamPreset()
        let result = await cancelAtStage(.captions, preset: preset)
        XCTAssertEqual(result.cancelledAt, .captions)
        XCTAssertEqual(records.record(for: preset.id)?.remoteID, "uid-1")
        XCTAssertEqual(records.record(for: preset.id)?.state, .processing)
        XCTAssertNil(records.record(for: preset.id)?.captionsLanguage)
    }

    func testCancelBeforeRunningDoesNothing() async {
        let run = ExportRun(preset: folderPreset, environment: environment())
        run.cancel()
        let result = await run.run()
        XCTAssertEqual(result.cancelledAt, .preparing)
        XCTAssertTrue(renderer.requests.isEmpty)
    }

    // MARK: Coordinator and progress

    func testRunRegistersWithTheCoordinatorUntilItFinishes() async {
        renderer.stalls = true
        let run = ExportRun(preset: folderPreset, environment: environment())
        let finished = Task { await run.run() }
        let registered = await waitUntil { coordinator.activeCount == 1 }
        XCTAssertTrue(registered)
        renderer.release()
        let result = await finished.value
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(coordinator.hasActiveJobs)
    }

    func testProgressMovesForwardThroughTheStagesAndEndsAtOne() async {
        renderer.vtt = "WEBVTT\n\n"
        var stages: [ExportStage] = []
        var overall: [Double] = []
        let run = ExportRun(preset: streamPreset(), environment: environment())
        run.onStage = { stages.append($0) }
        run.onProgress = { overall.append($0.overall) }
        let result = await run.run()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(stages, [.preparing, .rendering, .publishing, .uploading, .captions])
        XCTAssertEqual(overall, overall.sorted(), "Overall progress never goes backwards")
        XCTAssertEqual(try XCTUnwrap(overall.last), 1, accuracy: 0.0001)
    }
}
