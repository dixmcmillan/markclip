import AVFoundation
import AppKit

// The editor's export engine glue. Every output is a preset run through
// `exportQueue` (see `ExportQueue`/`ExportRun`): it renders from an immutable
// copy of the project, publishes atomically, and runs as a
// `MediaExportCoordinator` job that outlives the window. The UI is in
// `+ExportUI.swift`.
extension VideoEditorWindowController {

    // MARK: Preset export queue

    /// This editor's serial preset export queue. UI observes
    /// `exportQueue.state` / `observe(_:)`; see `ExportQueue`.
    var exportQueue: ExportQueue {
        if let existing = exportQueueStorage { return existing }
        let records: ExportRecordStore = editorDocument.exportRecordsURL.map { ExportRecordStore.store(for: $0) }
            ?? ExportRecordStore(url: nil)
        let source = editorDocument.source
        var environment = ExportEnvironment(
            projectName: editorDocument.source.originalURL.deletingPathExtension().lastPathComponent,
            renderer: EditorExportRenderer(exporter: exporter, document: editorDocument),
            records: records,
            remote: {
                #if OFFLINE
                return nil
                #else
                return CloudflareExportService.make()
                #endif
            },
            localFolderForUploads: { ExportEnvironment.defaultLocalFolderForUploads() })
        // Saving over a disposable input (or a recording's original) must make
        // that path the user's, so closing the editor never deletes it.
        environment.localFilePublished = { source.didSave(at: $0) }
        let queue = ExportQueue(environment: environment)
        exportQueueStorage = queue
        // Toasts for results and for Stream finishing later; independent of this window.
        ExportCompletionNotifier.attach(to: queue, projectName: environment.projectName)
        return queue
    }

    /// Runs `preset` (with optional one-off Adjust overrides), or queues it
    /// behind the running export, and remembers it as the last-used preset.
    @discardableResult
    func runExportPreset(_ preset: ExportPreset, overrides: ExportOverrides = ExportOverrides()) -> UUID {
        ExportPresetStore.setLastUsedID(preset.id)
        return exportQueue.enqueue(preset, overrides: overrides)
    }
}

// MARK: - GIF viewer

/// GIF files cannot be edited by AVFoundation; they open in a small viewer
/// with copy and reveal actions.
final class GIFPreviewController: NSObject, NSWindowDelegate {
    private static var open: [GIFPreviewController] = []
    private var window: NSWindow?
    private let url: URL
    private let lease: TemporaryMediaLease

    private init(url: URL, lease: TemporaryMediaLease) {
        self.url = url
        self.lease = lease
    }

    static func show(prepared: PreparedVideoSource, owner: AnyObject) -> Bool {
        guard let image = NSImage(contentsOf: prepared.snapshot.mediaURL) else { return false }
        let controller = GIFPreviewController(url: prepared.snapshot.originalURL, lease: prepared.snapshot.lease)
        let size = image.size
        let scale = min(1, 900 / max(size.width, 1), 700 / max(size.height, 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(360, size.width * scale), height: max(240, size.height * scale)),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = prepared.snapshot.originalURL.lastPathComponent
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        let view = NSImageView(image: image)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window = window
        open.append(controller)
        _ = owner
        return true
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
