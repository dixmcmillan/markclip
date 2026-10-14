import XCTest

/// Settings ▸ Export editing rules: the preset list, every field's validation
/// and coupling, and shortcut assignment. Each edit must persist, so most tests
/// re-read through a second model on the same defaults.
@MainActor
final class ExportSettingsModelTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let control: NSEvent.ModifierFlags = [.control, .command]

    override func setUp() {
        suite = "export-settings-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func model(offline: Bool = false) -> ExportSettingsModel { ExportSettingsModel(defaults: defaults, offline: offline) }
    private func reread(_ id: UUID) -> ExportPreset? { ExportPresetStore.preset(id: id, defaults: defaults) }

    // MARK: List

    func testStartsWithTheBuiltInsAndSelectsTheFirst() {
        let model = model()
        XCTAssertEqual(model.presets.map(\.name), ["Archive", "Stream", "Loop"])
        XCTAssertEqual(model.selected?.name, "Archive")
    }

    func testAddingAPresetSelectsAndPersistsIt() {
        let model = model()
        let added = model.addPreset()
        XCTAssertEqual(added.name, L("New Preset"))
        XCTAssertFalse(added.isBuiltIn)
        XCTAssertEqual(model.selectedID, added.id)
        XCTAssertEqual(self.model().presets.last?.id, added.id)
        XCTAssertEqual(model.addPreset().name, L("New Preset") + " 2")
    }

    func testDuplicateCopiesEveryFieldButNotTheIdentity() {
        let model = model()
        let copy = model.duplicate(ExportPresetStore.streamID)
        let stream = ExportPresetStore.builtIns()[1]
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, stream.id)
        XCTAssertEqual(copy?.isBuiltIn, false)
        XCTAssertEqual(copy?.name, String(format: L("%@ copy"), "Stream"))
        XCTAssertEqual(copy?.destination, .stream)
        XCTAssertEqual(copy?.explicitBitrate, 8_000_000)
        XCTAssertEqual(copy?.longEdgeCap, 1920)
        XCTAssertNil(model.duplicate(UUID()))
    }

    func testBuiltInsCannotBeDeleted() {
        let model = model()
        XCTAssertFalse(model.delete(ExportPresetStore.archiveID))
        XCTAssertEqual(model.presets.count, 3)
    }

    func testDeletingACustomPresetRemovesItsShortcutAndSelectsANeighbor() {
        let model = model()
        let first = model.addPreset()
        let second = model.addPreset()
        XCTAssertEqual(model.assignShortcut(.init(character: "7", modifiers: control), to: first.id), .assigned(tookFrom: nil))
        model.select(first.id)
        XCTAssertTrue(model.delete(first.id))
        XCTAssertNil(reread(first.id))
        XCTAssertNil(ExportPresetShortcutStore.shortcut(for: first.id, defaults: defaults))
        XCTAssertEqual(model.selectedID, second.id, "selection moves to the preset that took its place")
        XCTAssertTrue(model.delete(second.id))
        XCTAssertEqual(model.selectedID, ExportPresetStore.loopID)
    }

    func testDeletingTheLastUsedPresetClearsItFromTheStore() {
        let model = model()
        let preset = model.addPreset()
        ExportPresetStore.setLastUsedID(preset.id, defaults: defaults)
        _ = model.delete(preset.id)
        XCTAssertNil(ExportPresetStore.lastUsedID(defaults: defaults))
    }

    func testRenameTrimsKeepsNamesUniqueAndIgnoresEmpty() {
        let model = model()
        let preset = model.addPreset()
        model.rename(preset.id, to: "  Review cut ")
        XCTAssertEqual(reread(preset.id)?.name, "Review cut")
        model.rename(preset.id, to: "archive")
        XCTAssertEqual(reread(preset.id)?.name, "archive 2")
        model.rename(preset.id, to: "   ")
        XCTAssertEqual(reread(preset.id)?.name, "archive 2")
        model.rename(preset.id, to: "archive 2")
        XCTAssertEqual(reread(preset.id)?.name, "archive 2", "keeping its own name is not a conflict")
    }

    func testBuiltInsCanBeRenamed() {
        let model = model()
        model.rename(ExportPresetStore.archiveID, to: "Master")
        XCTAssertEqual(self.model().presets.first?.name, "Master")
        XCTAssertTrue(self.model().presets.first?.isBuiltIn == true)
    }

    // MARK: Fields round-trip

    func testEveryFieldRoundTripsThroughStorage() {
        let model = model()
        let id = model.addPreset().id
        model.setFormat(id, .hevc)
        model.update(id) {
            $0.longEdgeCap = 1280
            $0.fpsCap = 24
            $0.quality = .low
            $0.audio = .mute
            $0.captions = .soft
            $0.requireSignedURLs = true
            $0.alsoSaveLocally = true
        }
        XCTAssertEqual(model.setBitrate(id, text: "6.5"), .bitsPerSecond(6_500_000))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-settings-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.setFolder(id, to: folder)

        let saved = self.model().presets.first { $0.id == id }
        XCTAssertEqual(saved?.format, .hevc)
        XCTAssertEqual(saved?.longEdgeCap, 1280)
        XCTAssertEqual(saved?.fpsCap, 24)
        XCTAssertEqual(saved?.quality, .low)
        XCTAssertEqual(saved?.explicitBitrate, 6_500_000)
        XCTAssertEqual(saved?.audio, .mute)
        XCTAssertEqual(saved?.captions, .soft)
        XCTAssertTrue(saved?.requireSignedURLs == true)
        XCTAssertTrue(saved?.alsoSaveLocally == true)
        guard case let .folder(bookmark, path)? = saved?.destination else { return XCTFail("expected a folder") }
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertNotNil(bookmark, "choosing a folder keeps a bookmark")
        XCTAssertEqual(saved?.destination.resolvedFolderURL()?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }

    func testBitrateValidation() {
        let model = model()
        let id = model.addPreset().id
        XCTAssertEqual(model.setBitrate(id, text: "8"), .bitsPerSecond(8_000_000))
        XCTAssertEqual(model.setBitrate(id, text: "0"), .invalid)
        XCTAssertEqual(reread(id)?.explicitBitrate, 8_000_000, "an invalid entry leaves the stored value")
        XCTAssertEqual(model.setBitrate(id, text: "-1"), .invalid)
        XCTAssertEqual(model.setBitrate(id, text: "fast"), .invalid)
        XCTAssertEqual(reread(id)?.explicitBitrate, 8_000_000)
        XCTAssertEqual(model.setBitrate(id, text: ""), .none)
        XCTAssertNil(reread(id)?.explicitBitrate)
    }

    // MARK: Coupling of format and destination

    func testGIFFormatMovesStreamToImagesAndMutesAudio() {
        let model = model()
        model.setFormat(ExportPresetStore.streamID, .gif)
        let preset = reread(ExportPresetStore.streamID)
        XCTAssertEqual(preset?.destination, .images)
        XCTAssertEqual(preset?.audio, .mute)
    }

    func testVideoFormatMovesImagesToStream() {
        let model = model()
        model.setFormat(ExportPresetStore.loopID, .h264)
        XCTAssertEqual(reread(ExportPresetStore.loopID)?.destination, .stream)
    }

    func testChoosingStreamOrImagesFixesTheFormat() {
        let model = model()
        let id = model.addPreset().id     // H.264 folder
        model.setDestination(id, .images)
        XCTAssertEqual(reread(id)?.destination, .images)
        XCTAssertEqual(reread(id)?.format, .gif)
        XCTAssertEqual(reread(id)?.audio, .mute)
        model.setDestination(id, .stream)
        XCTAssertEqual(reread(id)?.destination, .stream)
        XCTAssertEqual(reread(id)?.format, .h264)
        XCTAssertEqual(reread(id)?.audio, .keep)
        model.update(id) { $0.alsoSaveLocally = true }
        model.setDestination(id, .folder)
        XCTAssertTrue(reread(id)?.destination.isFolder == true)
        XCTAssertEqual(reread(id)?.alsoSaveLocally, false, "'also save locally' only means something for uploads")
    }

    func testChoosingFolderAgainKeepsTheChosenFolder() {
        let model = model()
        let id = model.addPreset().id
        let url = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)
        model.setFolder(id, to: url)
        model.setDestination(id, .folder)
        XCTAssertEqual(reread(id)?.destination.resolvedFolderURL()?.lastPathComponent, "somewhere")
    }

    func testIncompatibleCombinationsAreFlagged() {
        let model = model()
        var preset = ExportPreset(name: "x", format: .gif, destination: .stream)
        XCTAssertNotNil(model.compatibilityNote(for: preset))
        preset = ExportPreset(name: "x", format: .hevc, destination: .images)
        XCTAssertNotNil(model.compatibilityNote(for: preset))
        XCTAssertNil(model.compatibilityNote(for: ExportPresetStore.builtIns()[1]))
        XCTAssertNil(model.compatibilityNote(for: ExportPresetStore.builtIns()[2]))
    }

    func testOfflineOffersOnlyFolders() {
        let model = model(offline: true)
        XCTAssertEqual(model.availableDestinations, [.folder])
        XCTAssertEqual(model.presets.map(\.name), ["Archive"])
        let id = model.addPreset().id
        model.setDestination(id, .stream)
        XCTAssertTrue(ExportPresetStore.preset(id: id, defaults: defaults)?.destination.isFolder == true, "stream is refused under OFFLINE")
        XCTAssertEqual(self.model().availableDestinations, [.folder, .stream, .images])
    }

    // MARK: GIF fit budget

    func testGIFFitFieldsApplyWithinBounds() {
        let model = model()
        let id = ExportPresetStore.loopID
        XCTAssertNil(model.setGIFFit(id, field: .maxMegabytes, text: "8.5"))
        XCTAssertNil(model.setGIFFit(id, field: .maxMegapixels, text: "40"))
        XCTAssertNil(model.setGIFFit(id, field: .minLongEdge, text: "720"))
        XCTAssertNil(model.setGIFFit(id, field: .minFPS, text: "6"))
        XCTAssertNil(model.setGIFFit(id, field: .startFPS, text: "12"))
        let fit = reread(id)?.gifFit
        XCTAssertEqual(fit?.maxBytes, 8_500_000)
        XCTAssertEqual(fit?.maxTotalMegapixels, 40)
        XCTAssertEqual(fit?.minLongEdge, 720)
        XCTAssertEqual(fit?.minFPS, 6)
        XCTAssertEqual(fit?.startFPS, 12)
    }

    func testGIFFitRejectsOutOfRangeAndNonNumbers() {
        let model = model()
        let id = ExportPresetStore.loopID
        let before = reread(id)?.gifFit
        for (field, text) in [(GIFFitField.maxMegabytes, "0"), (.maxMegabytes, "-5"), (.maxMegabytes, "1000"), (.maxMegapixels, "nan"),
                              (.minLongEdge, "10"), (.minLongEdge, "700.5"), (.minFPS, "0"), (.startFPS, "31"), (.startFPS, "abc")] {
            XCTAssertNotNil(model.setGIFFit(id, field: field, text: text), "\(field) \(text)")
        }
        XCTAssertEqual(reread(id)?.gifFit, before)
    }

    func testStartRateCannotBeBelowTheFloor() {
        let model = model()
        let id = ExportPresetStore.loopID
        XCTAssertNotNil(model.setGIFFit(id, field: .minFPS, text: "20"), "start is 15")
        XCTAssertNotNil(model.setGIFFit(id, field: .startFPS, text: "5"), "floor is 8")
        XCTAssertNil(model.setGIFFit(id, field: .startFPS, text: "8"))
    }

    // MARK: Shortcuts

    func testAssignReportsWhoLostTheChordAndPersists() {
        let model = model()
        let custom = model.addPreset()
        let outcome = model.assignShortcut(.init(character: "1", modifiers: control), to: custom.id)
        XCTAssertEqual(outcome, .assigned(tookFrom: "Archive"))
        XCTAssertEqual(model.shortcutText(for: custom.id), "⌃⌘1")
        XCTAssertNil(model.shortcutText(for: ExportPresetStore.archiveID))
        XCTAssertEqual(self.model().shortcutText(for: custom.id), "⌃⌘1")
    }

    func testAssignRejectsBareKeysAndEditorCommands() {
        let model = model()
        XCTAssertEqual(model.assignShortcut(.init(character: "q", modifiers: []), to: ExportPresetStore.archiveID),
                       .rejected(L("Use ⌘ or ⌃ in the shortcut.")))
        XCTAssertEqual(model.assignShortcut(.init(character: "e", modifiers: [.command]), to: ExportPresetStore.archiveID),
                       .rejected(L("That shortcut is used by another editor command.")))
        XCTAssertEqual(model.shortcutText(for: ExportPresetStore.archiveID), "⌃⌘1", "a rejected chord changes nothing")
    }

    func testClearAndResetShortcut() {
        let model = model()
        model.clearShortcut(ExportPresetStore.streamID)
        XCTAssertNil(model.shortcutText(for: ExportPresetStore.streamID))
        model.resetShortcut(ExportPresetStore.streamID)
        XCTAssertEqual(model.shortcutText(for: ExportPresetStore.streamID), "⌃⌘2")
    }

    func testOnChangeFiresForEdits() {
        let model = model()
        var count = 0
        model.onChange = { count += 1 }
        let id = model.addPreset().id
        model.update(id) { $0.quality = .low }
        model.select(ExportPresetStore.archiveID)
        XCTAssertEqual(count, 3)
    }
}
