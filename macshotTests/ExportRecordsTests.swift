import XCTest

/// The `<take>.exports.json` sidecar: round trip, lenient decode, the overwrite
/// guard's file comparison, and where the file lives.
@MainActor
final class ExportRecordsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-records-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Round trip

    func testRoundTripKeepsEveryField() throws {
        var records = ExportRecords()
        let id = UUID().uuidString
        records.presets[id] = ExportRecord(
            localFile: ExportFileRecord(path: "/tmp/a.mp4", size: 1234, mtime: 1_700_000_000.5),
            remoteKind: .stream, remoteID: "uid-9", uploadedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .processing, errorText: "boom", pendingDeleteUIDs: ["old-1", "old-2"],
            captionsLanguage: "en", fitSummary: "fit: 12 fps, 960 px")
        let decoded = try XCTUnwrap(ExportRecords.decode(try XCTUnwrap(records.encoded())))
        XCTAssertEqual(decoded, records)
    }

    func testStoreWritesAndReloadsFromDisk() throws {
        let url = directory.appendingPathComponent("Clip.exports.json")
        let store = ExportRecordStore(url: url)
        let id = UUID()
        store.update(id) { $0.remoteID = "uid-1"; $0.remoteKind = .stream; $0.state = .ready }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = ExportRecordStore(url: url)
        XCTAssertEqual(reloaded.record(for: id)?.remoteID, "uid-1")
        XCTAssertEqual(reloaded.record(for: id)?.state, .ready)
    }

    func testInMemoryStoreNeverWrites() {
        let store = ExportRecordStore(url: nil)
        let id = UUID()
        store.update(id) { $0.state = .failed }
        XCTAssertEqual(store.record(for: id)?.state, .failed)
    }

    func testStoreForSameFileIsSharedBetweenEditors() {
        let url = directory.appendingPathComponent("Shared.exports.json")
        XCTAssertTrue(ExportRecordStore.store(for: url) === ExportRecordStore.store(for: url))
    }

    func testObserversSeeUpdates() {
        let store = ExportRecordStore(url: nil)
        var calls = 0
        let token = store.observe { calls += 1 }
        store.update(UUID()) { $0.state = .ready }
        store.removeObserver(token)
        store.update(UUID()) { $0.state = .ready }
        XCTAssertEqual(calls, 1)
    }

    // MARK: Lenient decode

    func testMissingAndUnknownFieldsDecode() throws {
        let id = UUID().uuidString
        let data = json("""
        {"version": 7, "future": true, "presets": {"\(id)": {"remoteID": "abc", "state": "ready", "somethingNew": [1, 2]}}}
        """)
        let decoded = try XCTUnwrap(ExportRecords.decode(data))
        XCTAssertEqual(decoded.presets[id]?.remoteID, "abc")
        XCTAssertEqual(decoded.presets[id]?.state, .ready)
        XCTAssertNil(decoded.presets[id]?.localFile)
        XCTAssertEqual(decoded.presets[id]?.pendingDeleteUIDs, [])
    }

    func testWrongTypesFallBackToDefaultsInsteadOfDroppingTheRecord() throws {
        let id = UUID().uuidString
        let data = json("""
        {"presets": {"\(id)": {"remoteID": 5, "state": "banana", "uploadedAt": "not a date",
                               "localFile": {"path": "/x.mp4", "size": "big"}}}}
        """)
        let record = try XCTUnwrap(ExportRecords.decode(data)?.presets[id])
        XCTAssertNil(record.remoteID)
        XCTAssertNil(record.state)
        XCTAssertNil(record.uploadedAt)
        XCTAssertEqual(record.localFile?.path, "/x.mp4")
        XCTAssertEqual(record.localFile?.size, 0)
    }

    func testOneUnreadableRecordDoesNotLoseTheRest() throws {
        let good = UUID().uuidString, bad = UUID().uuidString
        let data = json("""
        {"presets": {"\(bad)": "not an object", "\(good)": {"remoteID": "kept"}}}
        """)
        let decoded = try XCTUnwrap(ExportRecords.decode(data))
        XCTAssertEqual(decoded.presets[good]?.remoteID, "kept")
        XCTAssertNil(decoded.presets[bad])
    }

    func testLegacySingularPendingDeleteUIDIsRead() throws {
        let id = UUID().uuidString
        let data = json(#"{"presets": {"\#(id)": {"remoteID": "new", "pendingDeleteUID": "old"}}}"#)
        XCTAssertEqual(ExportRecords.decode(data)?.presets[id]?.pendingDeleteUIDs, ["old"])
    }

    func testGarbageFileLoadsAsEmptyStore() throws {
        let url = directory.appendingPathComponent("Bad.exports.json")
        try Data("{{{ nope".utf8).write(to: url)
        XCTAssertTrue(ExportRecordStore(url: url).records.presets.isEmpty)
        XCTAssertNil(ExportRecords.decode(Data("[]".utf8))?.presets.first)
    }

    func testStateNeedingPollingIsOnlyProcessingStream() {
        XCTAssertTrue(ExportRecord(remoteKind: .stream, remoteID: "u", state: .processing).needsStatusPolling)
        XCTAssertFalse(ExportRecord(remoteKind: .stream, remoteID: "u", state: .ready).needsStatusPolling)
        XCTAssertFalse(ExportRecord(remoteKind: .images, remoteID: "u", state: .processing).needsStatusPolling)
        XCTAssertFalse(ExportRecord(remoteKind: .stream, remoteID: nil, state: .processing).needsStatusPolling)
    }

    // MARK: Location

    func testSidecarSitsBesideTheProjectFile() {
        let project = URL(fileURLWithPath: "/Recordings/Take 1/Take 1.project.json")
        XCTAssertEqual(ExportRecordStore.sidecarURL(forProjectURL: project).path, "/Recordings/Take 1/Take 1.exports.json")
        let odd = URL(fileURLWithPath: "/x/clip.json")
        XCTAssertEqual(ExportRecordStore.sidecarURL(forProjectURL: odd).lastPathComponent, "clip.exports.json")
    }

    // MARK: File comparison

    func testFileRecordMatchesUntilTheFileChanges() throws {
        let file = directory.appendingPathComponent("a.mp4")
        try Data("one".utf8).write(to: file)
        let record = try XCTUnwrap(ExportFileRecord.describing(file))
        XCTAssertEqual(record.size, 3)
        XCTAssertTrue(record.matchesDisk())
        try Data("three".utf8).write(to: file)          // size changes
        XCTAssertFalse(record.matchesDisk())
    }

    func testFileRecordDetectsSameSizeReplacementByMtime() throws {
        let file = directory.appendingPathComponent("a.mp4")
        try Data("abc".utf8).write(to: file)
        let record = try XCTUnwrap(ExportFileRecord.describing(file))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        XCTAssertFalse(record.matchesDisk())
    }

    func testMissingFileNeverMatches() {
        XCTAssertFalse(ExportFileRecord(path: directory.appendingPathComponent("gone.mp4").path, size: 1, mtime: 1).matchesDisk())
        XCTAssertFalse(ExportFileRecord(path: "", size: 0, mtime: 0).matchesDisk())
    }

    // MARK: Overwrite guard

    private func write(_ name: String, _ text: String = "x") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testFreshFolderUsesTheProjectName() {
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4", recorded: nil)
        XCTAssertEqual(choice.url.lastPathComponent, "Clip.mp4")
        XCTAssertFalse(choice.overwrites)
    }

    func testMatchingRecordedFileIsOverwritten() throws {
        let file = try write("Clip.mp4")
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4",
                                                   recorded: ExportFileRecord.describing(file))
        XCTAssertEqual(choice.url.lastPathComponent, "Clip.mp4")
        XCTAssertTrue(choice.overwrites)
    }

    func testReplacedFileFallsBackToNumbering() throws {
        let file = try write("Clip.mp4", "ours")
        let recorded = ExportFileRecord.describing(file)
        try Data("someone else's, longer".utf8).write(to: file)
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4", recorded: recorded)
        XCTAssertEqual(choice.url.lastPathComponent, "Clip 2.mp4")
        XCTAssertFalse(choice.overwrites)
    }

    func testUnrecordedExistingFileIsNeverOverwritten() throws {
        _ = try write("Clip.mp4")
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4", recorded: nil)
        XCTAssertEqual(choice.url.lastPathComponent, "Clip 2.mp4")
        XCTAssertFalse(choice.overwrites)
    }

    func testNumberedFileFromAnEarlierRunIsReused() throws {
        _ = try write("Clip.mp4", "unrelated")
        let ours = try write("Clip 2.mp4", "ours")
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4",
                                                   recorded: ExportFileRecord.describing(ours))
        XCTAssertEqual(choice.url.lastPathComponent, "Clip 2.mp4")
        XCTAssertTrue(choice.overwrites)
    }

    func testRecordedFileInAnotherFolderIsNotTouched() throws {
        let other = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let theirs = other.appendingPathComponent("Clip.mp4")
        try Data("x".utf8).write(to: theirs)
        _ = try write("Clip.mp4", "occupant")
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4",
                                                   recorded: ExportFileRecord.describing(theirs))
        XCTAssertEqual(choice.url.lastPathComponent, "Clip 2.mp4")
        XCTAssertFalse(choice.overwrites)
    }

    func testRecordedFileWithAnotherExtensionIsNotReused() throws {
        let gif = try write("Clip.gif")
        let choice = ExportLocalDestination.choose(folder: directory, base: "Clip", ext: "mp4",
                                                   recorded: ExportFileRecord.describing(gif))
        XCTAssertEqual(choice.url.lastPathComponent, "Clip.mp4")
        XCTAssertFalse(choice.overwrites)
    }

    func testEnsureFolderCreatesMissingFolders() throws {
        let nested = directory.appendingPathComponent("a/b/Markclip Archive")
        try ExportLocalDestination.ensureFolder(nested)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        try ExportLocalDestination.ensureFolder(nested)   // existing: no error
    }

    // MARK: Budget mapping

    func testFitBudgetFollowsThePresetsLimits() {
        var settings = GIFFitSettings()
        settings.maxBytes = 5_000_000
        settings.maxTotalMegapixels = 20
        settings.minLongEdge = 480
        settings.minFPS = 10
        let budget = GIFFitBudget(settings)
        XCTAssertEqual(budget.maxBytes, 5_000_000)
        XCTAssertEqual(budget.maxTotalPixels, 20_000_000)
        XCTAssertEqual(budget.minLongEdge, 480)
        XCTAssertEqual(budget.fpsLadder, [15, 12, 10])
        XCTAssertEqual(GIFFitBudget(GIFFitSettings()), GIFFitBudget.cloudflareImages)
    }
}
