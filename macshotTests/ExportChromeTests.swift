import XCTest

/// The top bar's split Export control, the toast wording, and the colors the
/// export UI draws text with.
@MainActor
final class ExportChromeTests: XCTestCase {
    private final class Target: NSObject {
        var runs = 0
        var menus = 0
        @objc func run() { runs += 1 }
        @objc func menu(_ sender: Any?) { menus += 1 }
    }

    private func makeButton(_ target: Target) -> ExportSplitButton {
        ExportSplitButton(target: target, runAction: #selector(Target.run), menuAction: #selector(Target.menu(_:)))
    }

    // MARK: Split button

    func testMainSegmentRunsAndChevronOpens() {
        let target = Target()
        let button = makeButton(target)
        button.mainButton.performClick(nil)
        XCTAssertEqual(target.runs, 1)
        XCTAssertEqual(target.menus, 0)
        button.menuButton.performClick(nil)
        XCTAssertEqual(target.menus, 1)
        XCTAssertEqual(target.runs, 1)
    }

    func testDisablingDisablesBothSegments() {
        let button = makeButton(Target())
        button.isEnabled = false
        XCTAssertFalse(button.mainButton.isEnabled)
        XCTAssertFalse(button.menuButton.isEnabled)
        button.isEnabled = true
        XCTAssertTrue(button.mainButton.isEnabled && button.menuButton.isEnabled)
    }

    func testRingFollowsTheQueueState() {
        let button = makeButton(Target())
        XCTAssertNil(button.ringFraction)
        var state = ExportQueueState()
        state.current = .init(presetID: UUID(), presetName: "Stream", stage: .uploading, stageFraction: 0.5, fraction: 0.62, isCancelling: false)
        button.apply(state)
        XCTAssertEqual(button.ringFraction ?? -1, 0.62, accuracy: 0.0001)
        XCTAssertTrue(button.mainButton.toolTip?.contains("62") == true)
        XCTAssertTrue(button.mainButton.toolTip?.contains("Stream") == true)
        state.waiting = [.init(id: UUID(), presetID: UUID(), presetName: "Loop")]
        button.apply(state)
        XCTAssertEqual(button.mainButton.title, String(format: L("Export +%d"), 1))
        state.current = nil
        state.waiting = []
        button.apply(state)
        XCTAssertNil(button.ringFraction)
        XCTAssertEqual(button.mainButton.title, L("Export"))
    }

    func testTooltipNamesTheLastUsedPreset() {
        let button = makeButton(Target())
        button.setLastUsed(name: "Archive")
        XCTAssertEqual(button.mainButton.toolTip, String(format: L("Export with %@ (⇧⌘E)"), "Archive"))
        button.setLastUsed(name: nil)
        XCTAssertEqual(button.mainButton.toolTip, L("Export (⇧⌘E)"))
    }

    func testCancellingStateIsAnnounced() {
        let button = makeButton(Target())
        var state = ExportQueueState()
        state.current = .init(presetID: UUID(), presetName: "Stream", stage: .rendering, stageFraction: 0, fraction: 0.1, isCancelling: true)
        button.apply(state)
        XCTAssertEqual(button.mainButton.toolTip, L("Cancelling…"))
    }

    func testRingImageDrawsAtEveryProgress() {
        for fraction in [0.0, 0.01, 0.5, 1.0] {
            let image = ExportSplitButton.ringImage(fraction: fraction)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertFalse(image.isTemplate)
            XCTAssertNotNil(image.tiffRepresentation, "fraction \(fraction)")
        }
        // The arc must change what is drawn.
        let empty = ExportSplitButton.ringImage(fraction: 0).tiffRepresentation
        let half = ExportSplitButton.ringImage(fraction: 0.5).tiffRepresentation
        XCTAssertNotEqual(empty, half)
    }

    // MARK: Toasts

    private let folder = URL(fileURLWithPath: "/tmp/Clip.mp4")

    func testSavedToast() {
        var result = ExportRunResult(presetID: UUID(), presetName: "Archive")
        result.localFile = folder
        let toast = ExportToastContent.forResult(result, projectName: "Clip", accountID: nil)
        XCTAssertEqual(toast?.kind, .saved(folder))
        XCTAssertEqual(toast?.title, L("Saved"))
        XCTAssertEqual(toast?.detail, "Clip.mp4")
    }

    func testUploadToastsNameTheProductAndLinkToTheDashboard() {
        var stream = ExportRunResult(presetID: UUID(), presetName: "Stream")
        stream.localFile = folder
        stream.remoteKind = .stream
        stream.remoteID = "uid1"
        let toast = ExportToastContent.forResult(stream, projectName: "Clip", accountID: "acct")
        XCTAssertEqual(toast?.title, L("Uploaded to Stream"))
        XCTAssertEqual(toast?.detail, "Clip")
        XCTAssertEqual(toast?.dashboardURL?.absoluteString, "https://dash.cloudflare.com/acct/stream/videos/uid1")

        var images = ExportRunResult(presetID: UUID(), presetName: "Loop")
        images.remoteKind = .images
        images.remoteID = "img"
        images.fitSummary = "fit: 12 fps, 960 px"
        let loop = ExportToastContent.forResult(images, projectName: "Clip", accountID: "acct")
        XCTAssertEqual(loop?.title, L("Uploaded to Images"))
        XCTAssertEqual(loop?.detail, "Clip · fit: 12 fps, 960 px")
    }

    func testMissingCaptionsAreMentionedInTheUploadToast() {
        var result = ExportRunResult(presetID: UUID(), presetName: "Stream")
        result.remoteKind = .stream
        result.remoteID = "u"
        result.captionsError = "denied"
        XCTAssertTrue(ExportToastContent.forResult(result, projectName: "Clip", accountID: nil)?.detail
            .contains(String(format: L("Captions weren't added: %@"), "denied")) == true)
    }

    func testFailureAndCancelToasts() {
        var failed = ExportRunResult(presetID: UUID(), presetName: "Stream")
        failed.failure = ExportRunFailure(stage: .uploading, message: "network down")
        let toast = ExportToastContent.forResult(failed, projectName: "Clip", accountID: nil)
        XCTAssertEqual(toast?.kind, .failure)
        XCTAssertEqual(toast?.detail, String(format: L("Export failed: %@"), "network down"))

        var cancelled = ExportRunResult(presetID: UUID(), presetName: "Stream")
        cancelled.cancelledAt = .rendering
        XCTAssertNil(ExportToastContent.forResult(cancelled, projectName: "Clip", accountID: nil))
    }

    func testReadyToast() {
        let url = URL(string: "https://dash.cloudflare.com/a/stream/videos/u")
        let toast = ExportToastContent.ready(projectName: "Clip", presetName: "Stream", dashboardURL: url)
        XCTAssertEqual(toast.title, L("Ready to stream"))
        XCTAssertEqual(toast.detail, "Clip · Stream")
        XCTAssertEqual(toast.dashboardURL, url)
    }

    // MARK: Contrast

    /// WCAG relative luminance of an sRGB color composited over `background`.
    private func luminance(_ color: NSColor, over background: Double) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let alpha = Double(c.alphaComponent)
        let r = Double(c.redComponent) * alpha + background * (1 - alpha)
        let g = Double(c.greenComponent) * alpha + background * (1 - alpha)
        let b = Double(c.blueComponent) * alpha + background * (1 - alpha)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ foreground: NSColor, background: Double) -> Double {
        let l1 = luminance(foreground, over: background)
        let l2 = luminance(NSColor(white: CGFloat(background), alpha: 1), over: background)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testPopoverTextMeetsContrastOnTheDarkPopover() {
        // A dark popover material is between ~0.12 and ~0.25 gray; check the lighter end.
        let background = 0.25
        XCTAssertGreaterThanOrEqual(contrast(VideoEditorStyle.textPrimary, background: background), 7)
        XCTAssertGreaterThanOrEqual(contrast(VideoEditorStyle.textSecondary, background: background), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(VideoEditorStyle.accentText, background: background), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1), background: background), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1), background: background), 4.5)
    }

    func testPlainAccentWouldNotHaveBeenReadableAsText() {
        // Documents why links use accentText: the default accent alone is under 3:1.
        XCTAssertLessThan(contrast(ToolbarLayout.defaultAccentColor, background: 0.25), 3)
    }

    func testExportPillFillKeepsWhiteTextReadable() {
        XCTAssertLessThan(VideoEditorStyle.whiteTextContrast(on: ToolbarLayout.defaultAccentColor), 4.5,
                          "the raw default accent is too light for white text")
        XCTAssertGreaterThanOrEqual(VideoEditorStyle.whiteTextContrast(on: VideoEditorStyle.accentFill), 4.5)
        // Whatever accent the user picks.
        for color in [NSColor.systemYellow, .systemOrange, .systemPink, .systemTeal, .white, .systemGreen, .systemBlue] {
            let fill = VideoEditorStyle.fill(forWhiteTextOn: color)
            XCTAssertGreaterThanOrEqual(VideoEditorStyle.whiteTextContrast(on: fill), 4.5, "\(color)")
        }
        // A color that already reads well isn't changed.
        let navy = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.4, alpha: 1)
        XCTAssertEqual(VideoEditorStyle.fill(forWhiteTextOn: navy).usingColorSpace(.sRGB)?.redComponent ?? -1, 0.1, accuracy: 0.001)
    }
}
