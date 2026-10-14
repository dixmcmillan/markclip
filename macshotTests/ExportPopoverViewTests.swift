import XCTest

/// The export popover as a view: Auto Layout sizing and hit areas (the old
/// panel's fixed frame left controls unreachable), its controls driving the
/// model, and its reaction to queue state. Headless: no window, no encoding.
@MainActor
final class ExportPopoverViewTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() {
        suite = "export-popover-view-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("popover-view-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(configured: Bool = true) -> ExportPopoverModel {
        ExportPopoverModel(environment: .init(nativeSize: { CGSize(width: 1920, height: 1080) },
                                              outputSize: { _ in CGSize(width: 1920, height: 1080) },
                                              outputDuration: { 10 },
                                              cloudflareConfigured: { configured },
                                              cloudflareAccountID: { "acct" }),
                           defaults: defaults, offline: false)
    }

    private func makeQueue(records: ExportRecordStore, renderer: FakeRenderer? = nil) -> ExportQueue {
        let env = ExportEnvironment(projectName: "Clip", renderer: renderer ?? FakeRenderer(), records: records, remote: { nil },
                                    localFolderForUploads: { [root] in root! }, coordinator: MediaExportCoordinator(),
                                    clock: InstantExportClock(), stagingRoot: root.appendingPathComponent("staging-" + UUID().uuidString))
        return ExportQueue(environment: env)
    }

    /// The view pinned into a host the way `PopoverHelper.showAutoLayout`
    /// pins it into a popover, so frames come from Auto Layout alone.
    private struct Fixture {
        let view: ExportPopoverView
        let model: ExportPopoverModel
        let records: ExportRecordStore
        let queue: ExportQueue
        let container: NSView
        let host: NSView

        /// Sizes the host to the view's fitting height (as the popover does) and lays out.
        func relayout() {
            view.layoutSubtreeIfNeeded()
            host.setFrameSize(NSSize(width: ExportPopoverView.width, height: view.fittingSize.height))
            container.setFrameSize(host.frame.size)
            container.layoutSubtreeIfNeeded()
        }
    }

    private func fixture(configured: Bool = true, handlers: ExportPopoverView.Handlers = .init(),
                         renderer: FakeRenderer? = nil) -> Fixture {
        let model = makeModel(configured: configured)
        let records = ExportRecordStore(url: nil)
        let queue = makeQueue(records: records, renderer: renderer)
        let view = ExportPopoverView(model: model, queue: queue, records: records, handlers: handlers)
        view.layoutSubtreeIfNeeded()
        let host = NSView(frame: NSRect(origin: .zero, size: view.fittingSize))
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let bottom = view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor), view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor), bottom,
        ])
        let f = Fixture(view: view, model: model, records: records, queue: queue, container: container, host: host)
        f.relayout()
        return f
    }

    /// What a click at the center of `control` would reach.
    private func hit(_ control: NSView, in f: Fixture) -> NSView? {
        f.relayout()
        let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: f.container)
        return f.container.hitTest(center)
    }

    private func reaches(_ control: NSView, _ f: Fixture) -> Bool {
        let found = hit(control, in: f)
        return found === control || found?.isDescendant(of: control) == true
    }

    // MARK: Layout

    func testViewHasAFixedWidthAndAHeightFromItsContent() {
        let f = fixture()
        let size = f.view.fittingSize
        XCTAssertEqual(size.width, ExportPopoverView.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 600)
    }

    func testPrimaryControlsHaveRealAreaAndReceiveClicks() {
        let f = fixture()
        for control in [f.view.exportActionButton, f.view.saveAsActionButton, f.view.adjustToggleButton] as [NSView] {
            XCTAssertGreaterThan(control.frame.width, 20, "\(control)")
            XCTAssertGreaterThan(control.frame.height, 10, "\(control)")
            XCTAssertTrue(reaches(control, f), "click should land on \(control), not \(String(describing: hit(control, in: f)))")
        }
    }

    func testEveryPresetRowIsClickable() throws {
        let f = fixture()
        f.relayout()
        let radios = allSubviews(of: f.view).compactMap { $0 as? NSButton }.filter { $0.title.isEmpty == false || $0.attributedTitle.length > 0 }
            .filter { ["Archive", "Stream", "Loop"].contains($0.attributedTitle.string) }
        XCTAssertEqual(radios.count, 3)
        for radio in radios {
            XCTAssertGreaterThan(radio.frame.width, 100)
            XCTAssertTrue(reaches(radio, f), "\(radio.attributedTitle.string): \(String(describing: hit(radio, in: f)))")
        }
    }

    func testOpeningAdjustGrowsTheViewAndShowsTheFields() {
        let f = fixture()
        let closed = f.view.fittingSize.height
        f.view.adjustToggleButton.performClick(nil)
        f.relayout()
        XCTAssertTrue(f.view.isAdjustExpanded)
        let open = f.view.fittingSize.height
        XCTAssertGreaterThan(open, closed + 120, "the Adjust fields add height")
        f.view.adjustToggleButton.performClick(nil)
        f.relayout()
        XCTAssertEqual(f.view.fittingSize.height, closed, accuracy: 1)
    }

    func testAdjustControlsReceiveClicksWhenOpen() throws {
        let f = fixture()
        f.view.adjustToggleButton.performClick(nil)
        f.relayout()
        let segments = allSubviews(of: f.view).compactMap { $0 as? NSSegmentedControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertGreaterThanOrEqual(segments.count, 3, "format, quality, audio, captions")
        for segment in segments {
            XCTAssertGreaterThan(segment.frame.width, 80)
            XCTAssertTrue(reaches(segment, f))
        }
        let popups = allSubviews(of: f.view).compactMap { $0 as? NSPopUpButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(popups.count, 2, "size and frame rate")
        for popup in popups {
            XCTAssertGreaterThan(popup.frame.width, 40)
            XCTAssertTrue(reaches(popup, f))
        }
    }

    func testSelectingAnotherPresetUpdatesTheSummary() {
        let f = fixture()
        f.model.select(ExportPresetStore.streamID)
        f.relayout()
        XCTAssertTrue(labels(in: f.view).contains { $0.contains("H.264") })
    }

    func testGIFHidesVideoOnlyAdjustRows() {
        let f = fixture()
        f.view.adjustToggleButton.performClick(nil)
        f.relayout()
        let video = f.view.fittingSize.height
        f.model.updateAdjust { $0.format = .gif }
        f.relayout()
        XCTAssertLessThan(f.view.fittingSize.height, video, "quality, bitrate and audio rows collapse for GIF")
    }

    // MARK: Behavior

    func testExportRunsTheSelectedPresetWithTheAdjustOverrides() {
        var ran: [(String, ExportOverrides)] = []
        var handlers = ExportPopoverView.Handlers()
        handlers.run = { preset, overrides in ran.append((preset.name, overrides)) }
        let f = fixture(handlers: handlers)
        f.model.select(ExportPresetStore.streamID)
        f.model.updateAdjust { $0.quality = .high }
        f.view.exportActionButton.performClick(nil)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(ran.first?.0, "Stream")
        XCTAssertEqual(ran.first?.1.quality, .high)
    }

    func testSaveAsHandsOverThePresetAndOverrides() {
        var saved: [String] = []
        var handlers = ExportPopoverView.Handlers()
        handlers.saveAs = { preset, _ in saved.append(preset.name) }
        let f = fixture(handlers: handlers)
        f.view.saveAsActionButton.performClick(nil)
        XCTAssertEqual(saved, ["Archive"])
    }

    func testExportIsBlockedUntilCloudflareIsSetUp() {
        var ran = 0
        var handlers = ExportPopoverView.Handlers()
        handlers.run = { _, _ in ran += 1 }
        let f = fixture(configured: false, handlers: handlers)
        f.model.select(ExportPresetStore.streamID)
        f.relayout()
        XCTAssertFalse(f.view.exportActionButton.isEnabled)
        XCTAssertTrue(f.view.saveAsActionButton.isEnabled)
        XCTAssertTrue(labels(in: f.view).contains(L("Set up Cloudflare in Settings")))
        f.view.exportActionButton.performClick(nil)
        XCTAssertEqual(ran, 0)
        f.model.select(ExportPresetStore.archiveID)
        XCTAssertTrue(f.view.exportActionButton.isEnabled)
    }

    func testInvalidBitrateDisablesExportAndShowsTheMessage() {
        let f = fixture()
        f.view.adjustToggleButton.performClick(nil)
        f.model.updateAdjust { $0.bitrateText = "0" }
        f.relayout()
        XCTAssertFalse(f.view.exportActionButton.isEnabled)
        XCTAssertTrue(labels(in: f.view).contains(L("Enter a bitrate above 0 and up to 500 Mbps, or leave it empty.")))
    }

    func testStatusLineAppearsForAnUploadPreset() {
        let f = fixture()
        f.model.select(ExportPresetStore.streamID)
        XCTAssertFalse(labels(in: f.view).contains { $0.contains(L("Ready")) })
        f.records.update(ExportPresetStore.streamID) {
            $0.remoteKind = .stream; $0.remoteID = "uid"; $0.uploadedAt = Date().addingTimeInterval(-3600); $0.state = .ready
        }
        f.model.select(ExportPresetStore.loopID)
        f.model.select(ExportPresetStore.streamID)
        XCTAssertTrue(labels(in: f.view).contains { $0.contains(L("Ready")) && $0.contains(String(format: L("%dh ago"), 1)) })
    }

    func testOpeningTheDashboardUsesTheRecordedVideo() {
        var opened: [URL] = []
        var handlers = ExportPopoverView.Handlers()
        handlers.open = { opened.append($0) }
        let f = fixture(handlers: handlers)
        f.records.update(ExportPresetStore.streamID) {
            $0.remoteKind = .stream; $0.remoteID = "uid7"; $0.uploadedAt = Date(); $0.state = .ready
        }
        f.model.select(ExportPresetStore.streamID)
        let link = allSubviews(of: f.view).compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == L("Open in dashboard") }
        XCTAssertNotNil(link)
        link?.performClick(nil)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://dash.cloudflare.com/acct/stream/videos/uid7"])
    }

    func testRetryRunsThePresetAgainAfterAFailedUpload() {
        var ran: [String] = []
        var handlers = ExportPopoverView.Handlers()
        handlers.run = { preset, _ in ran.append(preset.name) }
        let f = fixture(handlers: handlers)
        f.records.update(ExportPresetStore.streamID) { $0.remoteKind = .stream; $0.state = .failed; $0.errorText = "network" }
        f.model.select(ExportPresetStore.streamID)
        let retry = allSubviews(of: f.view).compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == L("Retry") }
        XCTAssertEqual(retry?.isHidden, false)
        retry?.performClick(nil)
        XCTAssertEqual(ran, ["Stream"])
    }

    // MARK: Queue state

    func testProgressAndCancelShowWhileExporting() async {
        var cancelled = 0
        var handlers = ExportPopoverView.Handlers()
        handlers.cancelCurrent = { cancelled += 1 }
        let renderer = FakeRenderer()
        renderer.stalls = true
        let f = fixture(handlers: handlers, renderer: renderer)
        let idleHeight = f.view.fittingSize.height
        XCTAssertTrue(f.view.cancelActionButton.isHiddenOrHasHiddenAncestor)
        let out = ExportDestination.folder(bookmark: nil, path: root.appendingPathComponent("out").path)
        f.queue.enqueue(ExportPreset(name: "First", destination: out))
        f.queue.enqueue(ExportPreset(name: "Second", destination: out))
        let busy = await waitUntil { f.queue.isBusy && f.queue.queuedCount == 1 }
        XCTAssertTrue(busy)
        f.relayout()
        XCTAssertFalse(f.view.cancelActionButton.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(f.view.fittingSize.height, idleHeight, "progress and the queue add rows")
        XCTAssertEqual(f.view.exportActionButton.title, L("Add to Queue"))
        XCTAssertTrue(labels(in: f.view).contains(String(format: L("Queued: %@"), "Second")))
        XCTAssertTrue(reaches(f.view.cancelActionButton, f), "Cancel must be clickable")
        f.view.cancelActionButton.performClick(nil)
        XCTAssertEqual(cancelled, 1)
        f.queue.cancelCurrent(dropQueued: true)
        let idle = await waitUntil { !f.queue.isBusy }
        XCTAssertTrue(idle)
        f.relayout()
        XCTAssertEqual(f.view.exportActionButton.title, L("Export"))
        XCTAssertTrue(f.view.cancelActionButton.isHiddenOrHasHiddenAncestor)
    }

    func testFailureOfTheSelectedPresetIsShown() async {
        let renderer = FakeRenderer()
        renderer.failure = FakeRemote.Failure(message: "disk full")
        let f = fixture(renderer: renderer)
        f.queue.enqueue(ExportPreset(id: ExportPresetStore.archiveID, name: "Archive",
                                     destination: .folder(bookmark: nil, path: root.appendingPathComponent("out").path)))
        let failed = await waitUntil { f.queue.state.lastResult?.failure != nil }
        XCTAssertTrue(failed)
        XCTAssertTrue(labels(in: f.view).contains(String(format: L("Export failed: %@"), "disk full")))
    }

    // MARK: Helpers

    private func allSubviews(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews(of:)) }

    private func labels(in view: NSView) -> [String] {
        allSubviews(of: view).compactMap { ($0 as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue } }
            + allSubviews(of: view).compactMap { ($0 as? NSButton).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.attributedTitle.string } }
    }
}
