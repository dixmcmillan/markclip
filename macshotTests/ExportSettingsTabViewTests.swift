import XCTest

/// The Settings ▸ Export view wired to its model (headless: no window).
@MainActor
final class ExportSettingsTabViewTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "export-settings-view-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func makeView(offline: Bool = false) -> ExportSettingsTabView {
        let view = ExportSettingsTabView(model: ExportSettingsModel(defaults: defaults, offline: offline))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testListsThePresetsAndShowsTheSelectedOne() {
        let view = makeView()
        XCTAssertEqual(view.tableRowCount, 3)
        XCTAssertEqual(view.formControls.name.stringValue, "Archive")
        XCTAssertEqual(view.formControls.format.selectedSegment, 1, "HEVC")
        XCTAssertTrue(view.isRowVisible("folder"))
        XCTAssertFalse(view.isRowVisible("saveLocally"))
        XCTAssertFalse(view.isRowVisible("signed"))
        XCTAssertFalse(view.isRowVisible("gifHeader"))
    }

    func testVideoOnlyRowsHideForGIFAndFitRowsShowForImages() {
        let view = makeView()
        view.model.select(ExportPresetStore.loopID)
        XCTAssertFalse(view.isRowVisible("quality"))
        XCTAssertFalse(view.isRowVisible("bitrate"))
        XCTAssertFalse(view.isRowVisible("audio"))
        XCTAssertTrue(view.isRowVisible("gifHeader"))
        XCTAssertTrue(view.isRowVisible("gif.\(GIFFitField.maxMegabytes)"))
        XCTAssertFalse(view.isRowVisible("folder"))
        XCTAssertTrue(view.isRowVisible("saveLocally"))
        XCTAssertFalse(view.isRowVisible("signed"), "signed URLs are a Stream option")
    }

    func testStreamShowsSignedURLsAndTheUploadOptions() {
        let view = makeView()
        view.model.select(ExportPresetStore.streamID)
        XCTAssertTrue(view.isRowVisible("signed"))
        XCTAssertTrue(view.isRowVisible("saveLocally"))
        XCTAssertTrue(view.isRowVisible("quality"))
        XCTAssertTrue(view.isRowVisible("bitrate"))
        XCTAssertEqual(view.formControls.bitrate.stringValue, "8")
        XCTAssertFalse(view.isRowVisible("gifHeader"))
    }

    func testCloudflareNoticeAppearsOnlyWhenNotConfiguredAndUploading() {
        let view = makeView()
        view.model.select(ExportPresetStore.streamID)
        XCTAssertEqual(view.isRowVisible("cloudflare"), !ExportCloudflareSupport.isConfigured)
        view.model.select(ExportPresetStore.archiveID)
        XCTAssertFalse(view.isRowVisible("cloudflare"))
    }

    func testOfflineOffersOnlyTheFolderDestination() {
        let view = makeView(offline: true)
        XCTAssertEqual(view.tableRowCount, 1)
        XCTAssertEqual(view.formControls.destination.numberOfItems, 1)
        XCTAssertEqual(view.formControls.destination.titleOfSelectedItem, L("Folder on this Mac"))
    }

    func testNormalBuildOffersAllFourDestinations() {
        let view = makeView()
        XCTAssertEqual(view.formControls.destination.numberOfItems, 4)
        XCTAssertEqual(view.formControls.destination.itemTitles.last, L("TrainWithDixon"))
    }

    func testEditsFromTheModelRefreshTheForm() {
        let view = makeView()
        let id = view.model.addPreset().id
        view.model.update(id) { $0.explicitBitrate = 4_000_000 }
        XCTAssertEqual(view.formControls.name.stringValue, L("New Preset"))
        XCTAssertEqual(view.formControls.bitrate.stringValue, "4")
        XCTAssertEqual(view.tableRowCount, 4)
    }

    func testNotRecordingAShortcutUntilAsked() {
        XCTAssertFalse(makeView().recordingActive)
    }

    // MARK: Build variants

    func testSettingsTabsFollowTheBuildVariant() {
        let tabs = SettingsWindowController.tabIdentifiers
        XCTAssertTrue(tabs.contains(SettingsWindowController.exportTabID))
        #if OFFLINE
        XCTAssertFalse(tabs.contains(SettingsWindowController.cloudflareTabID), "no Cloudflare UI in the offline build")
        XCTAssertTrue(BuildVariant.isOffline)
        XCTAssertFalse(ExportCloudflareSupport.isAvailable)
        XCTAssertFalse(ExportCloudflareSupport.isConfigured)
        XCTAssertNil(ExportCloudflareSupport.accountID)
        #else
        XCTAssertTrue(tabs.contains(SettingsWindowController.cloudflareTabID))
        XCTAssertTrue(tabs.firstIndex(of: SettingsWindowController.exportTabID)! < tabs.firstIndex(of: SettingsWindowController.cloudflareTabID)!)
        XCTAssertFalse(BuildVariant.isOffline)
        XCTAssertTrue(ExportCloudflareSupport.isAvailable)
        #endif
    }

    func testDefaultModelFollowsTheBuildVariant() {
        let names = ExportSettingsModel(defaults: defaults).presets.map(\.name)
        let popover = ExportPopoverModel(environment: .init(), defaults: defaults).presets.map(\.name)
        #if OFFLINE
        XCTAssertEqual(names, ["Archive"])
        XCTAssertEqual(popover, ["Archive"])
        #else
        XCTAssertEqual(names, ["Archive", "Stream", "Loop"])
        XCTAssertEqual(popover, ["Archive", "Stream", "Loop"])
        #endif
    }
}
