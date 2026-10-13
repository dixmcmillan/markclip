import XCTest

/// Export presets (model, store, migration, lenient decode, resolved
/// settings) and Quick Export's pure destination/filename logic. UI (the
/// export panel) isn't covered here; see CLAUDE.md's testing notes on
/// extracting pure logic out of UI classes.
final class ExportPresetTests: XCTestCase {

    private let presetsKey = ExportPresetStore.presetsKey
    private let lastUsedKey = ExportPresetStore.lastUsedKey
    private let flagKey = ExportPresetStore.migrationFlagKey
    private let legacyKey = ExportPresetStore.legacyPresetsKey
    private let lastDirectoryKey = "lastExportDestinationDirectory"

    /// Clean slate for every key the store touches.
    private func withCleanStore(_ extra: [String: Any?] = [:], _ body: () throws -> Void) rethrows {
        var values: [String: Any?] = [presetsKey: nil, lastUsedKey: nil, flagKey: nil, legacyKey: nil, lastDirectoryKey: nil]
        for (k, v) in extra { values[k] = v }
        try withDefaults(values, body)
    }

    private func folderPath(_ preset: ExportPreset) -> String? {
        if case let .folder(_, path) = preset.destination { return path }
        return nil
    }

    // MARK: Built-ins

    func testBuiltInsSeedInOrderWithStableIDs() {
        withCleanStore {
            let all = ExportPresetStore.allPresets()
            XCTAssertEqual(all.map(\.id), [ExportPresetStore.archiveID, ExportPresetStore.streamID, ExportPresetStore.loopID])
            XCTAssertEqual(all.map(\.name), ["Archive", "Stream", "Loop"])
            XCTAssertTrue(all.allSatisfy(\.isBuiltIn))
            // Literal ids: they are referenced from persisted state in later phases.
            XCTAssertEqual(ExportPresetStore.archiveID.uuidString, "6D41C11B-0000-4000-8000-000000000001")
            XCTAssertEqual(ExportPresetStore.streamID.uuidString, "6D41C11B-0000-4000-8000-000000000002")
            XCTAssertEqual(ExportPresetStore.loopID.uuidString, "6D41C11B-0000-4000-8000-000000000003")
            // And stay the same across a second read.
            XCTAssertEqual(ExportPresetStore.allPresets().map(\.id), all.map(\.id))
        }
    }

    func testArchiveBuiltInDefinition() throws {
        try withCleanStore {
            let archive = try XCTUnwrap(ExportPresetStore.allPresets().first)
            XCTAssertEqual(archive.format, .hevc)
            XCTAssertNil(archive.longEdgeCap)
            XCTAssertNil(archive.fpsCap)
            XCTAssertEqual(archive.quality, .high)
            XCTAssertNil(archive.explicitBitrate)
            XCTAssertEqual(archive.audio, .keep)
            XCTAssertEqual(archive.captions, .burned)
            XCTAssertEqual(folderPath(archive), NSHomeDirectory() + "/Movies/Markclip Archive")
        }
    }

    func testStreamBuiltInDefinition() throws {
        try withCleanStore {
            let stream = try XCTUnwrap(ExportPresetStore.allPresets().dropFirst().first)
            XCTAssertEqual(stream.format, .h264)
            XCTAssertEqual(stream.longEdgeCap, 1920)
            XCTAssertEqual(stream.fpsCap, 30)
            XCTAssertEqual(stream.explicitBitrate, 8_000_000)
            XCTAssertEqual(stream.audio, .keep)
            XCTAssertEqual(stream.captions, .soft)
            XCTAssertEqual(stream.destination, .stream)
            XCTAssertTrue(stream.alsoSaveLocally)
            XCTAssertFalse(stream.requireSignedURLs)
        }
    }

    func testLoopBuiltInDefinition() throws {
        try withCleanStore {
            let loop = try XCTUnwrap(ExportPresetStore.allPresets().last)
            XCTAssertEqual(loop.format, .gif)
            XCTAssertEqual(loop.captions, .burned)
            XCTAssertEqual(loop.audio, .mute)
            XCTAssertEqual(loop.destination, .images)
            XCTAssertEqual(loop.gifFit.maxBytes, 10_000_000)
            XCTAssertEqual(loop.gifFit.maxTotalMegapixels, 50)
            XCTAssertEqual(loop.gifFit.minLongEdge, 640)
            XCTAssertEqual(loop.gifFit.minFPS, 8)
            XCTAssertEqual(loop.gifFit.startFPS, 15)
        }
    }

    func testMissingBuiltInIsRestoredInPlace() {
        withCleanStore {
            let custom = ExportPreset(name: "Mine")
            ExportPresetStore.save([custom])
            let ids = ExportPresetStore.allPresets().map(\.id)
            XCTAssertEqual(ids, [ExportPresetStore.archiveID, ExportPresetStore.streamID, ExportPresetStore.loopID, custom.id])
        }
    }

    func testEditedBuiltInPersists() throws {
        try withCleanStore {
            var archive = try XCTUnwrap(ExportPresetStore.allPresets().first)
            archive.destination = .folder(bookmark: nil, path: "/tmp/elsewhere")
            ExportPresetStore.addOrReplace(archive)
            XCTAssertEqual(folderPath(try XCTUnwrap(ExportPresetStore.allPresets().first)), "/tmp/elsewhere")
            XCTAssertEqual(ExportPresetStore.allPresets().count, 3)
        }
    }

    // MARK: Store CRUD / last used

    func testCustomPresetRoundTripsThroughUserDefaults() throws {
        try withCleanStore {
            let preset = ExportPreset(name: "My Preset", format: .gif, longEdgeCap: 480, fpsCap: 10, quality: .low,
                                      audio: .mute, captions: .off, destination: .folder(bookmark: Data([1, 2, 3]), path: "/tmp/x"),
                                      alsoSaveLocally: true, requireSignedURLs: true,
                                      gifFit: { var g = GIFFitSettings(); g.maxBytes = 5; return g }())
            ExportPresetStore.addOrReplace(preset)
            let loaded = try XCTUnwrap(ExportPresetStore.allPresets().last)
            XCTAssertEqual(loaded, preset)
            XCTAssertEqual(ExportPresetStore.allPresets().count, 4)
        }
    }

    func testAddOrReplaceByIDUpdatesInPlaceRatherThanDuplicating() {
        withCleanStore {
            var preset = ExportPreset(name: "Mine")
            ExportPresetStore.addOrReplace(preset)
            preset.name = "Renamed"
            ExportPresetStore.addOrReplace(preset)
            let custom = ExportPresetStore.allPresets().filter { !$0.isBuiltIn }
            XCTAssertEqual(custom.map(\.name), ["Renamed"])
        }
    }

    func testDeleteRemovesOnlyTheMatchingCustomPreset() {
        withCleanStore {
            let a = ExportPreset(name: "A"), b = ExportPreset(name: "B")
            ExportPresetStore.addOrReplace(a)
            ExportPresetStore.addOrReplace(b)
            ExportPresetStore.delete(id: a.id)
            XCTAssertEqual(ExportPresetStore.allPresets().filter { !$0.isBuiltIn }.map(\.id), [b.id])
        }
    }

    func testDeletingABuiltInIsANoOp() {
        withCleanStore {
            ExportPresetStore.delete(id: ExportPresetStore.archiveID)
            XCTAssertEqual(ExportPresetStore.allPresets().count, 3)
            XCTAssertNotNil(ExportPresetStore.preset(id: ExportPresetStore.archiveID))
        }
    }

    func testLastUsedPresetRoundTripsAndFallsBackToFirstVisible() {
        withCleanStore {
            XCTAssertEqual(ExportPresetStore.lastUsedPreset(offline: false)?.id, ExportPresetStore.archiveID)
            ExportPresetStore.setLastUsedID(ExportPresetStore.streamID)
            XCTAssertEqual(ExportPresetStore.lastUsedID(), ExportPresetStore.streamID)
            XCTAssertEqual(ExportPresetStore.lastUsedPreset(offline: false)?.id, ExportPresetStore.streamID)
            // Hidden in OFFLINE: falls back rather than returning a preset that can't run.
            XCTAssertEqual(ExportPresetStore.lastUsedPreset(offline: true)?.id, ExportPresetStore.archiveID)
            // Stale id (deleted preset) falls back too.
            ExportPresetStore.setLastUsedID(UUID())
            XCTAssertEqual(ExportPresetStore.lastUsedPreset(offline: false)?.id, ExportPresetStore.archiveID)
        }
    }

    func testDeletingTheLastUsedPresetClearsIt() {
        withCleanStore {
            let mine = ExportPreset(name: "Mine")
            ExportPresetStore.addOrReplace(mine)
            ExportPresetStore.setLastUsedID(mine.id)
            ExportPresetStore.delete(id: mine.id)
            XCTAssertNil(ExportPresetStore.lastUsedID())
        }
    }

    // MARK: OFFLINE visibility

    func testOfflineHidesStreamAndImagesPresetsButKeepsThemStored() {
        withCleanStore {
            let folder = ExportPreset(name: "Local")
            ExportPresetStore.addOrReplace(folder)
            let offline = ExportPresetStore.visiblePresets(offline: true)
            XCTAssertEqual(offline.map(\.id), [ExportPresetStore.archiveID, folder.id])
            let online = ExportPresetStore.visiblePresets(offline: false)
            XCTAssertEqual(online.count, 4)
            XCTAssertEqual(ExportPresetStore.allPresets().count, 4, "hidden presets are preserved in storage")
            XCTAssertTrue(ExportPresetStore.allPresets().contains { $0.destination == .stream })
        }
    }

    func testVisiblePresetsDefaultsToTheBuildVariant() {
        withCleanStore {
            XCTAssertEqual(ExportPresetStore.visiblePresets().count, BuildVariant.isOffline ? 1 : 3)
        }
    }

    // MARK: Migration

    private let legacyJSON = """
    [{"id":"11111111-1111-4111-8111-111111111111","name":"Web 720","formatRaw":"mp4","targetLongEdge":1280.0,"qualityRaw":"medium","gifFPS":15,"isBuiltIn":false},
     {"id":"22222222-2222-4222-8222-222222222222","name":"Tiny GIF","formatRaw":"gif","targetLongEdge":480,"qualityRaw":"low","gifFPS":10,"isBuiltIn":false},
     {"id":"33333333-3333-4333-8333-333333333333","name":"Old built-in","formatRaw":"mp4","qualityRaw":"high","gifFPS":15,"isBuiltIn":true},
     "garbage"]
    """

    func testLegacyCustomPresetsMigrateOnce() throws {
        try withCleanStore([legacyKey: Data(legacyJSON.utf8)]) {
            let all = ExportPresetStore.allPresets()
            XCTAssertEqual(all.count, 5, "3 built-ins + 2 migrated customs (legacy built-in and corrupt entry dropped)")
            let web = try XCTUnwrap(all.first { $0.name == "Web 720" })
            XCTAssertEqual(web.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
            XCTAssertEqual(web.format, .h264)
            XCTAssertEqual(web.longEdgeCap, 1280)
            XCTAssertEqual(web.quality, .medium)
            XCTAssertNil(web.fpsCap, "a video preset never had a frame-rate cap")
            XCTAssertFalse(web.isBuiltIn)
            XCTAssertTrue(web.destination.isFolder)
            let gif = try XCTUnwrap(all.first { $0.name == "Tiny GIF" })
            XCTAssertEqual(gif.format, .gif)
            XCTAssertEqual(gif.longEdgeCap, 480)
            XCTAssertEqual(gif.fpsCap, 10)
            XCTAssertEqual(gif.quality, .low)
            XCTAssertTrue(gif.destination.isFolder)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))

            // Second run: a user deletion sticks, nothing is re-imported.
            ExportPresetStore.delete(id: web.id)
            XCTAssertFalse(ExportPresetStore.allPresets().contains { $0.id == web.id })
            XCTAssertEqual(ExportPresetStore.allPresets().count, 4)
        }
    }

    func testLegacyKeyIsLeftInPlace() {
        withCleanStore([legacyKey: Data(legacyJSON.utf8)]) {
            _ = ExportPresetStore.allPresets()
            XCTAssertNotNil(UserDefaults.standard.data(forKey: legacyKey), "Phase 6 removes the legacy keys, not migration")
        }
    }

    func testLegacyLastDirectorySeedsTheArchiveFolderAndMigratedPresets() throws {
        try withCleanStore([lastDirectoryKey: "/Volumes/Work/Exports", legacyKey: Data(legacyJSON.utf8)]) {
            let all = ExportPresetStore.allPresets()
            XCTAssertEqual(folderPath(try XCTUnwrap(all.first)), "/Volumes/Work/Exports")
            XCTAssertEqual(folderPath(try XCTUnwrap(all.first { $0.name == "Web 720" })), "/Volumes/Work/Exports")
        }
    }

    func testMigrationWithNoLegacyDataJustSeeds() {
        withCleanStore {
            XCTAssertEqual(ExportPresetStore.allPresets().count, 3)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
        }
    }

    func testMigrationDoesNotRunAgainOnceFlagged() {
        withCleanStore([flagKey: true, legacyKey: Data(legacyJSON.utf8)]) {
            XCTAssertEqual(ExportPresetStore.allPresets().count, 3, "flagged: legacy list is ignored")
        }
    }

    func testMigrationPreservesAlreadyStoredV2Presets() {
        let mine = ExportPreset(name: "Mine")
        let data = try! JSONEncoder().encode([mine])
        withCleanStore([presetsKey: data, legacyKey: Data(legacyJSON.utf8)]) {
            let names = ExportPresetStore.allPresets().map(\.name)
            XCTAssertEqual(names, ["Archive", "Stream", "Loop", "Mine", "Web 720", "Tiny GIF"])
        }
    }

    // MARK: Resolved settings

    func testResolvedSettingsScalesToLongEdgeCap() {
        let preset = ExportPreset(name: "Web", longEdgeCap: 1920, quality: .medium)
        let settings = preset.resolvedSettings(nativeSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(settings.scale, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.format, .mp4)
        XCTAssertEqual(settings.quality, .medium)
        // Portrait: the long edge is the height.
        XCTAssertEqual(preset.resolvedSettings(nativeSize: CGSize(width: 2160, height: 3840)).scale, 0.5, accuracy: 0.001)
    }

    func testResolvedSettingsNeverUpscales() {
        let preset = ExportPreset(name: "Web", longEdgeCap: 1920)
        XCTAssertEqual(preset.resolvedSettings(nativeSize: CGSize(width: 1280, height: 720)).scale, 1, accuracy: 0.001)
    }

    func testResolvedSettingsWithNilCapIsSourceResolution() {
        let preset = ExportPreset(name: "Full")
        XCTAssertEqual(preset.resolvedSettings(nativeSize: CGSize(width: 1920, height: 1080)).scale, 1)
        XCTAssertEqual(ExportPreset(name: "Web", longEdgeCap: 1920).resolvedSettings(nativeSize: nil).scale, 1,
                       "unknown native size falls back to scale 1")
    }

    func testResolvedSettingsCarriesEveryPresetField() throws {
        try withCleanStore {
            let stream = try XCTUnwrap(ExportPresetStore.preset(id: ExportPresetStore.streamID))
            let s = stream.resolvedSettings(nativeSize: CGSize(width: 3840, height: 2160))
            XCTAssertEqual(s.format, .mp4)
            XCTAssertEqual(s.codec, .h264)
            XCTAssertEqual(s.fpsCap, 30)
            XCTAssertEqual(s.explicitBitrate, 8_000_000)
            XCTAssertEqual(s.captions, .soft)
            XCTAssertFalse(s.muted)

            let archive = try XCTUnwrap(ExportPresetStore.preset(id: ExportPresetStore.archiveID))
            let a = archive.resolvedSettings(nativeSize: CGSize(width: 3840, height: 2160))
            XCTAssertEqual(a.codec, .hevc)
            XCTAssertEqual(a.scale, 1)
            XCTAssertEqual(a.quality, .high)
            XCTAssertNil(a.fpsCap)

            let loop = try XCTUnwrap(ExportPresetStore.preset(id: ExportPresetStore.loopID))
            let l = loop.resolvedSettings(nativeSize: CGSize(width: 1920, height: 1080))
            XCTAssertEqual(l.format, .gif)
            XCTAssertTrue(l.muted)
            XCTAssertEqual(l.gifFPS, 15, "GIF with no fps cap starts at gifFit.startFPS")
            XCTAssertEqual(l.gifFit, .default)
        }
    }

    func testResolvedGIFFPSUsesCapAndClamps() {
        XCTAssertEqual(ExportPreset(name: "g", format: .gif, fpsCap: 10).resolvedSettings(nativeSize: nil).gifFPS, 10)
        XCTAssertEqual(ExportPreset(name: "g", format: .gif, fpsCap: 120).resolvedSettings(nativeSize: nil).gifFPS, 30)
    }

    func testOverridesApplyOnTopOfThePreset() {
        let preset = ExportPreset(name: "Stream-ish", format: .h264, longEdgeCap: 1920, fpsCap: 30, quality: .medium,
                                  explicitBitrate: 8_000_000, audio: .keep, captions: .soft)
        let native = CGSize(width: 3840, height: 2160)

        var o = ExportOverrides()
        XCTAssertTrue(o.isEmpty)
        XCTAssertEqual(preset.resolvedSettings(nativeSize: native, overrides: o), preset.resolvedSettings(nativeSize: native))

        o.longEdgeCap = .value(1280)
        o.fpsCap = .removed
        o.explicitBitrate = .removed
        o.quality = .high
        o.audio = .mute
        o.captions = .off
        o.format = .hevc
        XCTAssertFalse(o.isEmpty)
        let s = preset.resolvedSettings(nativeSize: native, overrides: o)
        XCTAssertEqual(s.scale, 1280.0 / 3840.0, accuracy: 0.001)
        XCTAssertNil(s.fpsCap)
        XCTAssertNil(s.explicitBitrate)
        XCTAssertEqual(s.quality, .high)
        XCTAssertTrue(s.muted)
        XCTAssertEqual(s.captions, .off)
        XCTAssertEqual(s.codec, .hevc)
        XCTAssertEqual(preset.longEdgeCap, 1920, "overrides never mutate the stored preset")

        // Removing the size cap means source resolution.
        var source = ExportOverrides(); source.longEdgeCap = .removed
        XCTAssertEqual(preset.resolvedSettings(nativeSize: native, overrides: source).scale, 1)
    }

    func testLegacySettingsDefaultsAreUnchangedByTheNewFields() {
        let s = VideoExportSettings()
        XCTAssertEqual(s.format, .mp4)
        XCTAssertEqual(s.codec, .h264)
        XCTAssertNil(s.fpsCap)
        XCTAssertNil(s.explicitBitrate)
        XCTAssertEqual(s.captions, .burned)
        XCTAssertFalse(s.muted)
    }

    // MARK: Lenient decoding

    func testDecodingAnEmptyObjectFallsBackToDefaultsRatherThanThrowing() throws {
        let decoded = LenientArrayDecoder.decode(ExportPreset.self, from: Data("[{}]".utf8))
        let preset = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(preset.format, .h264)
        XCTAssertEqual(preset.quality, .high)
        XCTAssertEqual(preset.audio, .keep)
        XCTAssertEqual(preset.captions, .burned)
        XCTAssertEqual(preset.gifFit, .default)
        XCTAssertTrue(preset.destination.isFolder)
        XCTAssertFalse(preset.isBuiltIn)
        XCTAssertFalse(preset.alsoSaveLocally)
    }

    func testUnknownValuesAndFieldsFallBackRatherThanDropping() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Future","format":"av1","quality":"ultra","longEdgeCap":-5,"fpsCap":"fast",
          "audio":"boost","captions":"karaoke","destination":{"kind":"s3","bucket":"b"},"shortcut":"x","gifFit":{"maxBytes":"big","minFPS":6}}]
        """
        let preset = try XCTUnwrap(LenientArrayDecoder.decode(ExportPreset.self, from: Data(json.utf8))?.first)
        XCTAssertEqual(preset.name, "Future")
        XCTAssertEqual(preset.format, .h264)
        XCTAssertEqual(preset.quality, .high)
        XCTAssertNil(preset.longEdgeCap, "non-positive cap decodes as no cap")
        XCTAssertNil(preset.fpsCap, "wrong-typed value decodes as no cap")
        XCTAssertEqual(preset.audio, .keep)
        XCTAssertEqual(preset.captions, .burned)
        XCTAssertTrue(preset.destination.isFolder, "an unknown destination kind falls back to a local folder")
        XCTAssertEqual(preset.gifFit.maxBytes, 10_000_000)
        XCTAssertEqual(preset.gifFit.minFPS, 6)
    }

    func testDestinationRoundTrips() throws {
        let cases: [ExportDestination] = [.stream, .images, .folder(bookmark: nil, path: "/a"), .folder(bookmark: Data([9, 8]), path: "/b")]
        for destination in cases {
            let data = try JSONEncoder().encode([destination])
            XCTAssertEqual(try JSONDecoder().decode([ExportDestination].self, from: data), [destination])
        }
    }

    func testOneCorruptPresetDoesNotDropTheRestOfTheArray() throws {
        let good = ExportPreset(name: "Good")
        let goodData = try JSONEncoder().encode([good])
        var goodArray = try XCTUnwrap(JSONSerialization.jsonObject(with: goodData) as? [Any])
        goodArray.append("not an object")
        let mixed = try JSONSerialization.data(withJSONObject: goodArray)
        let decoded = LenientArrayDecoder.decode(ExportPreset.self, from: mixed)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.id, good.id)
    }

    func testCorruptStoredArrayEntryStillLeavesBuiltInsAndTheGoodPresets() {
        let good = ExportPreset(name: "Good")
        let goodJSON = String(data: try! JSONEncoder().encode(good), encoding: .utf8)!
        let data = Data("[\(goodJSON), 42]".utf8)
        withCleanStore([presetsKey: data, flagKey: true]) {
            XCTAssertEqual(ExportPresetStore.allPresets().map(\.name), ["Archive", "Stream", "Loop", "Good"])
        }
    }

    // MARK: Quick Export destination fallback

    func testQuickExportResolvesToLastUsedDirectoryWhenWritable() {
        let directory = URL(fileURLWithPath: "/tmp/fake-export-dir")
        let resolved = QuickExportDestination.resolve(lastUsedDirectory: directory) { $0 == directory }
        XCTAssertEqual(resolved, directory)
    }

    func testQuickExportFallsBackToDialogWhenNoLastUsedDirectory() {
        let resolved = QuickExportDestination.resolve(lastUsedDirectory: nil) { _ in true }
        XCTAssertNil(resolved)
    }

    func testQuickExportFallsBackToDialogWhenLastUsedDirectoryIsNotWritable() {
        // e.g. the destination was on an external drive that's since been ejected.
        let directory = URL(fileURLWithPath: "/tmp/ejected-volume")
        let resolved = QuickExportDestination.resolve(lastUsedDirectory: directory) { _ in false }
        XCTAssertNil(resolved)
    }

    func testLastDirectoryPersistsThroughUserDefaults() {
        withDefaults([lastDirectoryKey: nil]) {
            XCTAssertNil(VideoExportSettings.lastDirectory())
            let directory = URL(fileURLWithPath: "/tmp/my-exports", isDirectory: true)
            VideoExportSettings.setLastDirectory(directory)
            XCTAssertEqual(VideoExportSettings.lastDirectory()?.path, directory.path)
        }
    }

    // MARK: Quick Export filename

    func testQuickExportFilenameFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 14
        components.hour = 9; components.minute = 5; components.second = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!
        let formatter = QuickExportFilename.dateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let name = QuickExportFilename.build(sourceName: "My Recording", date: date, formatter: formatter)
        XCTAssertEqual(name, "My Recording 2026-03-14 09.05.02")
    }

    func testQuickExportFilenameHasNoColons() {
        // Colons render as "/" in Finder (classic Mac OS path-separator legacy).
        let name = QuickExportFilename.build(sourceName: "Clip", date: Date())
        XCTAssertFalse(name.contains(":"))
    }

    // MARK: Free destination picker (overwrite avoidance)

    func testFreeDestinationPickerReturnsBaseNameWhenFree() {
        let directory = URL(fileURLWithPath: "/tmp/out")
        let picked = FreeDestinationPicker.pick(directory: directory, base: "clip", ext: "mp4") { _ in false }
        XCTAssertEqual(picked, directory.appendingPathComponent("clip.mp4"))
    }

    func testFreeDestinationPickerAppendsIncrementingSuffixToAvoidOverwrite() {
        let directory = URL(fileURLWithPath: "/tmp/out")
        let taken: Set<String> = [
            directory.appendingPathComponent("clip.mp4").path,
            directory.appendingPathComponent("clip 2.mp4").path,
        ]
        let picked = FreeDestinationPicker.pick(directory: directory, base: "clip", ext: "mp4") { taken.contains($0.path) }
        XCTAssertEqual(picked, directory.appendingPathComponent("clip 3.mp4"))
    }

    func testFreeDestinationPickerAllowsOverwritingTheKeptURL() {
        // Re-saving to the file you already saved to shouldn't get renamed
        // out from under you.
        let directory = URL(fileURLWithPath: "/tmp/out")
        let existing = directory.appendingPathComponent("clip.mp4")
        let picked = FreeDestinationPicker.pick(directory: directory, base: "clip", ext: "mp4", keep: existing) { $0 == existing }
        XCTAssertEqual(picked, existing)
    }
}
