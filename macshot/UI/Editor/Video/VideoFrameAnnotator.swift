import Cocoa

/// Editor window that hosts the screenshot annotation toolkit over a single
/// paused video frame ("pause-and-annotate" in the video editor).
///
/// Modeled on `DetachedEditorWindowController` — same scroll view /
/// `CenteringClipView` / fit-to-window setup — but stripped of everything
/// that doesn't apply to a throwaway drawing session: no history, no save,
/// no upload/pin/OCR. The only output is the finished annotation list handed
/// back through `completion`; the caller (the video editor) turns that into a
/// `VideoAnnotationSegment`.
@MainActor
final class VideoFrameAnnotator: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var overlayView: EditorView?
    private var completion: (([Annotation]?) -> Void)?
    /// Undo identity captured right after the starting annotations were
    /// applied, so a close can tell whether the user changed anything.
    private var baselineUndoState: UUID?
    /// Set once the outcome (Done, or a confirmed discard) is decided, so
    /// `windowShouldClose` doesn't ask again while the window finishes closing.
    private var resolved = false

    private static var activeControllers: [VideoFrameAnnotator] = []

    /// Opens the annotator over `frame`, shown at `canvasSize` points so
    /// canvas coordinates equal annotation coordinates on both sides — no
    /// scaling math when the result is turned into a `VideoAnnotationSegment`.
    /// `completion` receives the finished (possibly empty) annotation list,
    /// or nil if the user cancelled.
    static func open(frame: CGImage, canvasSize: CGSize, annotations: [Annotation], title: String,
                      completion: @escaping ([Annotation]?) -> Void) {
        let controller = VideoFrameAnnotator()
        controller.completion = completion
        controller.show(frame: frame, canvasSize: canvasSize, annotations: annotations, title: title)
        activeControllers.append(controller)
        if activeControllers.count == 1 { NSApp.setActivationPolicy(.regular) }
    }

    private func show(frame: CGImage, canvasSize: CGSize, annotations: [Annotation], title: String) {
        let screenFrame = NSScreen.preferredVisibleFrame

        let minW: CGFloat = 640
        let minH: CGFloat = 400
        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9
        // Space for the top bar plus the same toolbar chrome allowance the
        // detached editor reserves (right tool strip, bottom strip, options row).
        let chromeW: CGFloat = 46 + 60
        let chromeH: CGFloat = 36 + 44 + 40 + 40
        let winW = min(maxW, max(minW, canvasSize.width + chromeW))
        let winH = min(maxH, max(minH, canvasSize.height + chromeH))

        let win = NSWindow(
            contentRect: NSRect(x: screenFrame.midX - winW / 2, y: screenFrame.midY - winH / 2, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.minSize = NSSize(width: minW, height: minH)
        win.maxSize = NSSize(width: screenFrame.width, height: screenFrame.height)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]

        // EditorView as the document view inside an NSScrollView, exactly like
        // the detached editor — canvas points equal view points, no manual
        // coordinate math.
        let view = EditorView()
        view.frame = NSRect(origin: .zero, size: canvasSize)
        view.autoresizingMask = []
        view.screenshotImage = NSImage(cgImage: frame, size: canvasSize)
        view.overlayDelegate = self
        // A paused video frame is the whole picture; it never gets beautify's
        // gradient background like a screenshot capture would.
        view.beautifyEnabled = false
        // Deliberately not touching currentTool/currentColor/currentStrokeWidth
        // otherwise: those already loaded the user's last-used choices from
        // UserDefaults. Crop is the one exception — there's no crop button
        // here to turn it off again, and cropping this view would resize the
        // canvas out from under `VideoAnnotationSegment`'s fixed coordinate
        // mapping. If the user's last tool (anywhere in the app) was crop,
        // fall back to the ordinary initial tool instead.
        if view.currentTool == .crop { view.currentTool = .arrow }

        let topBarHeight: CGFloat = 36
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        // Manual zoom (OverlayView's own scrollWheel/magnify) — see the
        // detached editor for why NSScrollView's own magnification is disabled.
        scrollView.allowsMagnification = false
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 50)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -84, right: -50)

        let clipView = CenteringClipView(frame: scrollView.contentView.frame)
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = view

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: winW, height: winH)))
        container.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        let topBar = AnnotatorTopBar(frame: NSRect(x: 0, y: winH - topBarHeight, width: winW, height: topBarHeight))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.onDone = { [weak self] in self?.complete() }
        container.addSubview(topBar)

        // Chrome parent set before applySelection so the tool strips/options
        // row land in the container, not the document view.
        view.chromeParentView = container
        view.applySelection(NSRect(origin: .zero, size: canvasSize))
        if !annotations.isEmpty { view.setAnnotations(annotations) }
        view.ensureCustomBeautifyBackgroundLoaded()

        // Baseline for the close-confirmation dirty check, captured after the
        // starting annotations are in place (editing them counts as a change,
        // just receiving them doesn't).
        baselineUndoState = view.undoStateIdentity

        win.contentView = container
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Fit-to-window for frames larger than the screen, same as the
        // detached editor.
        scrollView.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.bounds.size
        if canvasSize.width > 0, canvasSize.height > 0, visible.width > 0, visible.height > 0 {
            let fitMag = min(visible.width / canvasSize.width, visible.height / canvasSize.height)
            let initialMag = min(1.0, fitMag)
            let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, initialMag))
            if clamped < 0.999 { scrollView.magnification = clamped }
        }

        self.window = win
        self.overlayView = view
    }

    private func isDirty(_ view: EditorView) -> Bool { view.undoStateIdentity != baselineUndoState }

    /// Finishes annotating: hands the drawn annotations back to the caller
    /// and closes. `isMovable` filters out `.select`/`.translateOverlay`
    /// pseudo-annotations, matching how the detached editor extracts what the
    /// user actually drew (see `currentAnnotationData`).
    private func complete() {
        guard let view = overlayView else { return }
        // Done is outside the canvas, so a text box still being typed hasn't
        // been committed yet.
        view.commitTextFieldIfNeeded()
        let result = view.annotations.filter { $0.isMovable }.map { $0.clone() }
        resolved = true
        completion?(result)
        completion = nil
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !resolved, let view = overlayView, isDirty(view) else { return true }
        let alert = NSAlert()
        alert.messageText = L("Discard Drawing?")
        alert.informativeText = L("Your drawing will be lost if you close without adding it.")
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.resolved = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        completion?(nil)  // still set only when the window closed without Done
        completion = nil
        overlayView?.reset()
        overlayView?.overlayDelegate = nil
        window?.contentView = nil
        overlayView = nil
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}

// MARK: - OverlayViewDelegate

extension VideoFrameAnnotator: OverlayViewDelegate {
    func overlayViewDidCancel() { window?.performClose(nil) }
    /// Return, and the double-click "confirm" gesture some tools use, both
    /// finish annotating exactly like the Done button.
    func overlayViewDidConfirm() { complete() }
    func overlayViewDidRequestQuickSave() { complete() }

    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewDidRequestAddCapture() {}
}

// MARK: - Top bar

/// Minimal chrome: just an always-visible Done button. Unlike the detached
/// editor's Done (which appears only once something changes, mirroring the
/// overlay → editor flow), pause-and-annotate has no "clean" state worth
/// returning to — an empty drawing is still a valid "add nothing" outcome.
private final class AnnotatorTopBar: NSView {
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor

        let button = NSButton()
        button.bezelStyle = .recessed
        button.isBordered = true
        button.title = L("Done")
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = ToolbarLayout.accentColor
        button.target = self
        button.action = #selector(doneClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func doneClicked() { onDone?() }
}
