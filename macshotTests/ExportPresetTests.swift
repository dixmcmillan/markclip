import XCTest

/// Export presets (persistence + lenient decode) and Quick Export's pure
/// destination/filename logic (ROADMAP Phase 2). UI (the export panel's
/// Presets popup) isn't covered here — see CLAUDE.md's testing notes on
/// extracting pure logic out of UI classes.
final class ExportPresetTests: XCTestCase {

    private let presetsKey = "videoExportCustomPresets"
    private let lastDirectoryKey = "lastExportDestinationDirectory"

    // MARK: Built-ins

    func testBuiltInsArePresentAndMarked() {
        let builtIns = VideoExportPresetStore.builtIns
        XCTAssertEqual(builtIns.count, 3)
        XCTAssertTrue(builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(builtIns.contains { $0.format == .mp4 && $0.targetLongEdge == nil && $0.quality == .high },
                      "Full Quality preset should be source resolution, high quality")
        XCTAssertTrue(builtIns.contains { $0.format == .gif })
    }

    func testResolvedSettingsScalesToTargetLongEdge() {
        let preset = VideoExportPreset(name: "Web", format: .mp4, targetLongEdge: 1920, quality: .medium)
        let settings = preset.resolvedSettings(nativeSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(settings.scale, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.format, .mp4)
        XCTAssertEqual(settings.quality, .medium)
    }

    func testResolvedSettingsNeverUpscales() {
        // A source smaller than the preset's target shouldn't be scaled up.
        let preset = VideoExportPreset(name: "Web", format: .mp4, targetLongEdge: 1920, quality: .medium)
        let settings = preset.resolvedSettings(nativeSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(settings.scale, 1, accuracy: 0.001)
    }

    func testResolvedSettingsWithNilTargetLongEdgeIsSourceResolution() {
        let preset = VideoExportPreset(name: "Full", format: .mp4, targetLongEdge: nil, quality: .high)
        XCTAssertEqual(preset.resolvedSettings(nativeSize: CGSize(width: 1920, height: 1080)).scale, 1)
        XCTAssertEqual(preset.resolvedSettings(nativeSize: nil).scale, 1, "unknown native size falls back to scale 1")
    }

    // MARK: Persistence round-trip

    func testCustomPresetRoundTripsThroughUserDefaults() {
        withDefaults([presetsKey: nil]) {
            XCTAssertTrue(VideoExportPresetStore.customPresets().isEmpty)
            let preset = VideoExportPreset(name: "My Preset", format: .gif, targetLongEdge: 480, quality: .low, gifFPS: 10)
            VideoExportPresetStore.addOrReplace(preset)
            let loaded = VideoExportPresetStore.customPresets()
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.name, "My Preset")
            XCTAssertEqual(loaded.first?.format, .gif)
            XCTAssertEqual(loaded.first?.targetLongEdge, 480)
            XCTAssertEqual(loaded.first?.quality, .low)
            XCTAssertEqual(loaded.first?.gifFPS, 10)
            XCTAssertEqual(loaded.first?.id, preset.id)
        }
    }

    func testAllIncludesBuiltInsThenCustomPresets() {
        withDefaults([presetsKey: nil]) {
            let custom = VideoExportPreset(name: "Mine", format: .mp4, targetLongEdge: nil, quality: .high)
            VideoExportPresetStore.addOrReplace(custom)
            let all = VideoExportPresetStore.all()
            XCTAssertEqual(all.count, VideoExportPresetStore.builtIns.count + 1)
            XCTAssertEqual(all.last?.name, "Mine")
        }
    }

    func testAddOrReplaceByIDUpdatesInPlaceRatherThanDuplicating() {
        withDefaults([presetsKey: nil]) {
            var preset = VideoExportPreset(name: "Mine", format: .mp4, targetLongEdge: nil, quality: .high)
            VideoExportPresetStore.addOrReplace(preset)
            preset.name = "Renamed"
            VideoExportPresetStore.addOrReplace(preset)
            let loaded = VideoExportPresetStore.customPresets()
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.name, "Renamed")
        }
    }

    func testDeleteRemovesOnlyTheMatchingCustomPreset() {
        withDefaults([presetsKey: nil]) {
            let a = VideoExportPreset(name: "A", format: .mp4, targetLongEdge: nil, quality: .high)
            let b = VideoExportPreset(name: "B", format: .mp4, targetLongEdge: nil, quality: .high)
            VideoExportPresetStore.addOrReplace(a)
            VideoExportPresetStore.addOrReplace(b)
            VideoExportPresetStore.delete(id: a.id)
            let loaded = VideoExportPresetStore.customPresets()
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.id, b.id)
        }
    }

    func testDeletingABuiltInIDIsANoOp() {
        withDefaults([presetsKey: nil]) {
            let custom = VideoExportPreset(name: "Mine", format: .mp4, targetLongEdge: nil, quality: .high)
            VideoExportPresetStore.addOrReplace(custom)
            VideoExportPresetStore.delete(id: VideoExportPresetStore.builtIns[0].id)
            XCTAssertEqual(VideoExportPresetStore.customPresets().count, 1, "built-ins aren't stored, so deleting one can't remove a custom preset")
        }
    }

    // MARK: Lenient decoding

    func testDecodingAnEmptyObjectFallsBackToDefaultsRatherThanThrowing() throws {
        let json = "[{}]".data(using: .utf8)!
        let decoded = LenientArrayDecoder.decode(VideoExportPreset.self, from: json)
        let preset = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(preset.format, .mp4)
        XCTAssertEqual(preset.quality, .high)
        XCTAssertEqual(preset.gifFPS, 15)
        XCTAssertFalse(preset.isBuiltIn)
    }

    func testDecodingUnknownFormatOrQualityFallsBackRatherThanCrashing() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Old","formatRaw":"betamax","qualityRaw":"ultra","gifFPS":9999}]
        """.data(using: .utf8)!
        let decoded = LenientArrayDecoder.decode(VideoExportPreset.self, from: json)
        let preset = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(preset.format, .mp4, "unrecognized raw value falls back to .mp4")
        XCTAssertEqual(preset.quality, .high, "unrecognized raw value falls back to .high")
        XCTAssertEqual(preset.gifFPS, 30, "out-of-range fps clamps rather than staying nonsensical")
    }

    func testOneCorruptPresetDoesNotDropTheRestOfTheArray() throws {
        let good = VideoExportPreset(name: "Good", format: .mp4, targetLongEdge: nil, quality: .high)
        let goodData = try JSONEncoder().encode([good])
        var goodArray = try JSONSerialization.jsonObject(with: goodData) as! [Any]
        goodArray.append("not an object")
        let mixed = try JSONSerialization.data(withJSONObject: goodArray)
        let decoded = LenientArrayDecoder.decode(VideoExportPreset.self, from: mixed)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.id, good.id)
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
