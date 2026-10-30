import XCTest

/// The export popover's logic: selection, Adjust -> `ExportOverrides`,
/// summaries, validation and the upload status line. No view, no encoding.
@MainActor
final class ExportPopoverModelTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "export-popover-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func model(configured: Bool = true, offline: Bool = false, size: CGSize? = CGSize(width: 3840, height: 2160),
                       bytes: Int64? = nil, accountID: String? = "acct1") -> ExportPopoverModel {
        let environment = ExportPopoverModel.Environment(
            nativeSize: { size },
            outputSize: { settings in
                guard let size else { return nil }
                return CGSize(width: size.width * settings.scale, height: size.height * settings.scale)
            },
            estimatedBytes: { _ in bytes },
            outputDuration: { 32 },
            cloudflareConfigured: { configured },
            cloudflareAccountID: { accountID },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return ExportPopoverModel(environment: environment, defaults: defaults, offline: offline)
    }

    // MARK: Selection

    func testStartsOnTheLastUsedPresetElseArchive() {
        XCTAssertEqual(model().selectedID, ExportPresetStore.archiveID)
        ExportPresetStore.setLastUsedID(ExportPresetStore.streamID, defaults: defaults)
        XCTAssertEqual(model().selectedID, ExportPresetStore.streamID)
    }

    func testSelectingAPresetResetsAdjustToItsValues() {
        let model = model()
        model.updateAdjust { $0.quality = .low }
        XCTAssertTrue(model.hasAdjustments)
        model.select(ExportPresetStore.streamID)
        XCTAssertEqual(model.selectedPreset.name, "Stream")
        XCTAssertFalse(model.hasAdjustments)
        XCTAssertEqual(model.adjust.bitrateText, "8")
        XCTAssertEqual(model.adjust.longEdgeCap, 1920)
    }

    func testSelectingAnUnknownPresetIsIgnored() {
        let model = model()
        model.select(UUID())
        XCTAssertEqual(model.selectedID, ExportPresetStore.archiveID)
    }

    func testChangesNotifyTheView() {
        let model = model()
        var count = 0
        model.onChange = { count += 1 }
        model.select(ExportPresetStore.loopID)
        model.updateAdjust { $0.fpsCap = 12 }
        model.updateAdjust { $0.fpsCap = 12 }   // unchanged: no notification
        XCTAssertEqual(count, 2)
    }

    func testOfflineHidesStreamAndImagesPresets() {
        let model = model(offline: true)
        XCTAssertEqual(model.presets.map(\.name), ["Archive"])
        XCTAssertFalse(model.needsUploadSetup)
    }

    func testCustomPresetsAppearAfterTheBuiltIns() {
        ExportPresetStore.addOrReplace(ExportPreset(name: "Review"), defaults: defaults)
        XCTAssertEqual(model().presets.map(\.name), ["Archive", "Stream", "Loop", "Review"])
    }

    // MARK: Overrides

    func testUntouchedAdjustProducesNoOverrides() {
        for preset in ExportPresetStore.builtIns() {
            let model = model()
            model.select(preset.id)
            XCTAssertEqual(model.overrides, ExportOverrides(), preset.name)
        }
    }

    func testAdjustFieldsMapToOverrides() {
        let model = model()
        model.select(ExportPresetStore.streamID)   // H.264, 1920, 30 fps, medium, 8 Mbps, soft captions
        model.updateAdjust {
            $0.format = .hevc
            $0.longEdgeCap = 1280
            $0.fpsCap = nil
            $0.quality = .high
            $0.bitrateText = "5.5"
            $0.audio = .mute
            $0.captions = .off
        }
        XCTAssertEqual(model.overrides, ExportOverrides(format: .hevc, longEdgeCap: .value(1280), fpsCap: .removed,
                                                        quality: .high, explicitBitrate: .value(5_500_000),
                                                        audio: .mute, captions: .off))
        let effective = model.effectivePreset
        XCTAssertEqual(effective.format, .hevc)
        XCTAssertEqual(effective.longEdgeCap, 1280)
        XCTAssertNil(effective.fpsCap)
        XCTAssertEqual(effective.explicitBitrate, 5_500_000)
        XCTAssertEqual(effective.destination, .stream, "overrides never change the destination")
    }

    func testClearingTheBitrateRemovesThePresetsExplicitBitrate() {
        let model = model()
        model.select(ExportPresetStore.streamID)
        model.updateAdjust { $0.bitrateText = "" }
        XCTAssertEqual(model.overrides.explicitBitrate, .removed)
        XCTAssertNil(model.effectivePreset.explicitBitrate)
    }

    func testChangingAValueBackLeavesNoOverride() {
        let model = model()
        model.updateAdjust { $0.quality = .low }
        XCTAssertEqual(model.overrides.quality, .low)
        model.updateAdjust { $0.quality = .high }
        XCTAssertTrue(model.overrides.isEmpty)
        XCTAssertFalse(model.hasAdjustments)
    }

    func testResetAdjustRestoresThePreset() {
        let model = model()
        model.updateAdjust { $0.captions = .off; $0.format = .gif }
        model.resetAdjust()
        XCTAssertEqual(model.adjust, ExportAdjustState(preset: model.selectedPreset))
    }

    func testOverridesFeedTheResolvedSettings() {
        let model = model()
        model.updateAdjust { $0.format = .h264; $0.longEdgeCap = 1920; $0.fpsCap = 24 }
        let settings = model.effectivePreset.resolvedSettings(nativeSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(settings.codec, .h264)
        XCTAssertEqual(settings.scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.fpsCap, 24)
    }

    // MARK: Validation

    func testBitrateParsing() {
        XCTAssertEqual(ExportBitrateInput.parse(""), .none)
        XCTAssertEqual(ExportBitrateInput.parse("  "), .none)
        XCTAssertEqual(ExportBitrateInput.parse("8"), .bitsPerSecond(8_000_000))
        XCTAssertEqual(ExportBitrateInput.parse("2,5"), .bitsPerSecond(2_500_000))
        XCTAssertEqual(ExportBitrateInput.parse("0"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("-3"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("abc"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("nan"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("inf"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("501"), .invalid)
        XCTAssertEqual(ExportBitrateInput.parse("500"), .bitsPerSecond(500_000_000))
    }

    func testInvalidBitrateBlocksExportAndIsLeftOutOfOverrides() {
        let model = model()
        model.updateAdjust { $0.bitrateText = "0" }
        XCTAssertNotNil(model.bitrateError)
        XCTAssertFalse(model.canExport)
        XCTAssertFalse(model.canSaveAs)
        XCTAssertNil(model.overrides.explicitBitrate)
        model.updateAdjust { $0.bitrateText = "6" }
        XCTAssertNil(model.bitrateError)
        XCTAssertTrue(model.canExport)
    }

    func testUploadPresetsNeedACloudflareAccountToExportButNotToSaveAs() {
        let unconfigured = model(configured: false)
        unconfigured.select(ExportPresetStore.streamID)
        XCTAssertTrue(unconfigured.needsUploadSetup)
        XCTAssertFalse(unconfigured.canExport)
        XCTAssertTrue(unconfigured.canSaveAs, "Save As writes a local file")
        unconfigured.select(ExportPresetStore.loopID)
        XCTAssertTrue(unconfigured.needsUploadSetup)
        unconfigured.select(ExportPresetStore.archiveID)
        XCTAssertFalse(unconfigured.needsUploadSetup)
        XCTAssertTrue(unconfigured.canExport)

        let configured = model(configured: true)
        configured.select(ExportPresetStore.streamID)
        XCTAssertFalse(configured.needsUploadSetup)
        XCTAssertTrue(configured.canExport)
    }

    // MARK: Text

    func testSummaryDescribesTheEffectivePreset() {
        let model = model()
        XCTAssertEqual(model.summaryText, ["HEVC", L("Source size"), L("High quality"), L("Captions burned in")].joined(separator: " · "))
        model.select(ExportPresetStore.streamID)
        XCTAssertEqual(model.summaryText, ["H.264", String(format: L("Up to %d px"), 1920), String(format: L("Up to %d fps"), 30),
                                           String(format: L("%@ Mbps"), "8"), L("Soft captions")].joined(separator: " · "))
        model.updateAdjust { $0.audio = .mute }
        XCTAssertTrue(model.summaryText.contains(L("No audio")))
    }

    func testGIFSummaryOmitsVideoOnlyFields() {
        let model = model()
        model.select(ExportPresetStore.loopID)
        XCTAssertEqual(model.summaryText, ["GIF", L("Source size"), L("Fits Images limits"), L("Captions burned in")].joined(separator: " · "))
    }

    func testDestinationText() {
        let model = model()
        XCTAssertTrue(model.destinationText.hasSuffix("Movies/Markclip Archive"))
        model.select(ExportPresetStore.streamID)
        XCTAssertEqual(model.destinationText, L("Cloudflare Stream · also saved locally"))
        model.select(ExportPresetStore.loopID)
        XCTAssertEqual(model.destinationText, L("Cloudflare Images"))
    }

    func testDetailLineShowsSizeDurationAndEstimate() {
        let model = model(bytes: 45_000_000)
        model.select(ExportPresetStore.streamID)
        XCTAssertEqual(model.detailText, "1920×1080 · 0:32 · ~" + ByteCountFormatter.string(fromByteCount: 45_000_000, countStyle: .file))
        let unknown = self.model(size: nil)
        XCTAssertEqual(unknown.detailText, "0:32")
    }

    func testDurationFormatting() {
        XCTAssertEqual(ExportPopoverModel.durationText(0), "0:00")
        XCTAssertEqual(ExportPopoverModel.durationText(61.4), "1:01")
        XCTAssertEqual(ExportPopoverModel.durationText(3725), "1:02:05")
    }

    // MARK: Save as Preset

    func testSaveAsPresetStoresTheEffectiveSettingsAsACustomPreset() {
        let model = model()
        model.select(ExportPresetStore.streamID)
        model.updateAdjust { $0.longEdgeCap = 1280; $0.captions = .off }
        let saved = model.saveAsPreset(named: "  Small stream ")
        XCTAssertEqual(saved.name, "Small stream")
        XCTAssertFalse(saved.isBuiltIn)
        XCTAssertNotEqual(saved.id, ExportPresetStore.streamID)
        XCTAssertEqual(saved.longEdgeCap, 1280)
        XCTAssertEqual(saved.captions, .off)
        XCTAssertEqual(saved.destination, .stream)
        XCTAssertEqual(model.selectedID, saved.id)
        XCTAssertFalse(model.hasAdjustments, "the new preset starts unmodified")
        XCTAssertEqual(ExportPresetStore.preset(id: saved.id, defaults: defaults), saved)
        XCTAssertEqual(ExportPresetStore.preset(id: ExportPresetStore.streamID, defaults: defaults)?.longEdgeCap, 1920,
                       "the original preset is untouched")
    }

    func testSavedPresetNamesStayUnique() {
        let model = model()
        let first = model.saveAsPreset(named: "Review")
        let second = model.saveAsPreset(named: "review")
        XCTAssertEqual(first.name, "Review")
        XCTAssertEqual(second.name, "review 2")
        XCTAssertEqual(ExportPresetNaming.uniqueName("Archive", among: ExportPresetStore.builtIns()), "Archive 2")
        XCTAssertEqual(ExportPresetNaming.uniqueName("   ", among: []), L("New Preset"))
    }

    // MARK: Status line

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadyStatusLine() {
        let record = ExportRecord(remoteKind: .stream, remoteID: "uid9", uploadedAt: now.addingTimeInterval(-2 * 86_400 - 60), state: .ready)
        let line = ExportStatusLine.make(record: record, percent: nil, now: now, accountID: "acct1")
        XCTAssertEqual(line?.text, String(format: L("Uploaded %@"), String(format: L("%dd ago"), 2)) + " · " + L("Ready"))
        XCTAssertEqual(line?.tone, .success)
        XCTAssertEqual(line?.dashboardURL?.absoluteString, "https://dash.cloudflare.com/acct1/stream/videos/uid9")
        XCTAssertEqual(line?.canRetry, false)
    }

    func testProcessingStatusLineShowsPercentWhenKnown() {
        let record = ExportRecord(remoteKind: .stream, remoteID: "uid9", uploadedAt: now.addingTimeInterval(-90), state: .processing)
        let withPercent = ExportStatusLine.make(record: record, percent: 44.6, now: now, accountID: "a")
        XCTAssertEqual(withPercent?.text, String(format: L("Uploaded %@"), String(format: L("%dm ago"), 1)) + " · " + String(format: L("Processing %d%%"), 45))
        XCTAssertEqual(withPercent?.tone, .neutral)
        let without = ExportStatusLine.make(record: record, percent: nil, now: now, accountID: "a")
        XCTAssertTrue(without?.text.hasSuffix(L("Processing")) == true)
    }

    func testFailedStatusLineOffersRetryAndNoDashboardLink() {
        var record = ExportRecord(remoteKind: .stream, remoteID: "u", uploadedAt: now, state: .failed)
        record.errorText = "Couldn't reach Cloudflare"
        let line = ExportStatusLine.make(record: record, percent: nil, now: now, accountID: "a")
        XCTAssertEqual(line?.text, String(format: L("Upload failed: %@"), "Couldn't reach Cloudflare"))
        XCTAssertEqual(line?.tone, .failure)
        XCTAssertEqual(line?.canRetry, true)
        XCTAssertNil(line?.dashboardURL)
        record.errorText = "  "
        XCTAssertEqual(ExportStatusLine.make(record: record, percent: nil, now: now, accountID: "a")?.text, L("Upload failed"))
    }

    func testUploadingAndEmptyRecords() {
        let uploading = ExportRecord(remoteKind: .stream, state: .uploading)
        XCTAssertEqual(ExportStatusLine.make(record: uploading, percent: nil, now: now, accountID: nil)?.text, L("Uploading…"))
        XCTAssertNil(ExportStatusLine.make(record: nil, percent: nil, now: now, accountID: nil))
        XCTAssertNil(ExportStatusLine.make(record: ExportRecord(localFile: ExportFileRecord(path: "/x", size: 1, mtime: 1)),
                                           percent: nil, now: now, accountID: nil))
    }

    func testFitSummaryIsAppended() {
        let record = ExportRecord(remoteKind: .images, remoteID: "img", uploadedAt: now, state: .ready, fitSummary: "fit: 12 fps, 960 px")
        let line = ExportStatusLine.make(record: record, percent: nil, now: now, accountID: "acct")
        XCTAssertTrue(line?.text.hasSuffix("fit: 12 fps, 960 px") == true)
        XCTAssertEqual(line?.dashboardURL?.absoluteString, "https://dash.cloudflare.com/acct/images/images")
    }

    func testAgeBuckets() {
        let date = now
        XCTAssertEqual(ExportStatusLine.age(from: date, to: date.addingTimeInterval(10)), L("just now"))
        XCTAssertEqual(ExportStatusLine.age(from: date, to: date.addingTimeInterval(59 * 60)), String(format: L("%dm ago"), 59))
        XCTAssertEqual(ExportStatusLine.age(from: date, to: date.addingTimeInterval(5 * 3600)), String(format: L("%dh ago"), 5))
        XCTAssertEqual(ExportStatusLine.age(from: date, to: date.addingTimeInterval(40 * 86_400)), String(format: L("%dd ago"), 40))
        XCTAssertEqual(ExportStatusLine.age(from: date, to: date.addingTimeInterval(-500)), L("just now"), "a future date never shows a negative age")
    }

    func testDashboardURLRefusesOddIdentifiers() {
        XCTAssertNil(ExportStatusLine.dashboardURL(kind: .stream, remoteID: "../x", accountID: "a"))
        XCTAssertNil(ExportStatusLine.dashboardURL(kind: .stream, remoteID: "u", accountID: "a/b"))
        XCTAssertNil(ExportStatusLine.dashboardURL(kind: .stream, remoteID: "u", accountID: nil))
        XCTAssertNil(ExportStatusLine.dashboardURL(kind: .stream, remoteID: nil, accountID: "a"))
    }

    func testModelReadsTheSelectedPresetsRecord() {
        let model = model()
        let records = ExportRecordStore(url: nil)
        records.update(ExportPresetStore.streamID) {
            $0.remoteKind = .stream; $0.remoteID = "u1"; $0.uploadedAt = now; $0.state = .processing
        }
        XCTAssertNil(model.statusLine(records: records), "a folder preset has no upload status")
        model.select(ExportPresetStore.streamID)
        XCTAssertNotNil(model.statusLine(records: records))
        XCTAssertTrue(model.statusLine(records: records, processingPercent: [ExportPresetStore.streamID.uuidString: 12])?.text
            .contains("12") == true)
        model.select(ExportPresetStore.loopID)
        XCTAssertNil(model.statusLine(records: records), "Loop has no record")
    }

    // MARK: Ready / failed transitions

    func testWatcherReportsOnlyProcessingToReadyOrFailed() {
        var records = ExportRecords()
        records.presets["a"] = ExportRecord(remoteKind: .stream, remoteID: "1", state: .processing)
        records.presets["b"] = ExportRecord(remoteKind: .stream, remoteID: "2", state: .uploading)
        records.presets["c"] = ExportRecord(remoteKind: .stream, remoteID: "3", state: .ready)
        var watcher = ExportProcessingWatcher()
        watcher.prime(records)
        XCTAssertEqual(watcher.events(for: records), [])

        records.presets["a"]?.state = .ready
        records.presets["b"]?.state = .ready     // upload finished inside its own run: not announced here
        XCTAssertEqual(watcher.events(for: records), [.ready(presetKey: "a")])
        XCTAssertEqual(watcher.events(for: records), [], "announced once")

        records.presets["a"]?.state = .processing
        records.presets["a"]?.state = .failed
        records.presets["a"]?.errorText = "bad"
        XCTAssertEqual(watcher.events(for: records), [], "processing was never seen")
        records.presets["c"]?.state = .processing
        _ = watcher.events(for: records)
        records.presets["c"]?.state = .failed
        records.presets["c"]?.errorText = "encode error"
        XCTAssertEqual(watcher.events(for: records), [.failed(presetKey: "c", message: "encode error")])
    }
}
