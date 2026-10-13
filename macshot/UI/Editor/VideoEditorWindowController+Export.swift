import AVFoundation
import AppKit
import UniformTypeIdentifiers

// Saving and copying. Every output renders from an immutable copy
// of the project through `VideoEditorExporter`, publishes atomically, and
// runs as a `MediaExportCoordinator` job that outlives the window.
extension VideoEditorWindowController {

    // MARK: Export panel

    @objc func showExportPanel(_ sender: NSView) {
        let panel = VideoExportPanel(settings: exportSettings, controller: self)
        PopoverHelper.show(panel, size: panel.fittingSize, relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func exportSettingsChanged(_ settings: VideoExportSettings) {
        exportSettings = settings
        settings.save()
        savedURL = nil
    }

    /// Estimated file size and output size text for the export panel.
    func exportSummary(_ settings: VideoExportSettings) -> String {
        var parts: [String] = []
        if let size = exporter.outputSize(settings) { parts.append("\(Int(size.width))×\(Int(size.height))") }
        parts.append(VideoTransportBar.format(VideoRenderPlanner.outputDuration(project: editorDocument.project)))
        if let bytes = exporter.estimatedBytes(settings) {
            parts.append("~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Preset export queue

    /// This editor's serial preset export queue. UI observes
    /// `exportQueue.state` / `observe(_:)`; see `ExportQueue`.
    var exportQueue: ExportQueue {
        if let existing = exportQueueStorage { return existing }
        let records: ExportRecordStore = editorDocument.exportRecordsURL.map { ExportRecordStore.store(for: $0) }
            ?? ExportRecordStore(url: nil)
        let environment = ExportEnvironment(
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
        let queue = ExportQueue(environment: environment)
        exportQueueStorage = queue
        return queue
    }

    /// Runs `preset` (with optional one-off Adjust overrides), or queues it
    /// behind the running export, and remembers it as the last-used preset.
    @discardableResult
    func runExportPreset(_ preset: ExportPreset, overrides: ExportOverrides = ExportOverrides()) -> UUID {
        ExportPresetStore.setLastUsedID(preset.id)
        return exportQueue.enqueue(preset, overrides: overrides)
    }

    // MARK: Save

    @objc func saveAction() { PopoverHelper.dismiss(); saveVideo() }
    @objc func saveAsAction() { PopoverHelper.dismiss(); saveVideoAs() }

    /// Saves to the recordings folder, or asks where when it isn't set.
    func saveVideo() {
        guard !isExporting else { return }
        guard let directory = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() else {
            saveVideoAs()
            return
        }
        let ext = exportSettings.format == .gif ? "gif" : "mp4"
        let base = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent
        // Never replace an unrelated file silently: pick a free name.
        let destination = FreeDestinationPicker.pick(directory: directory, base: base, ext: ext, keep: savedURL) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        export(to: destination, directory: directory)
    }

    /// ⇧⌘E: exports immediately with the last-used settings and destination
    /// folder, no dialog. Falls back to the regular Export panel once when
    /// there's no usable last-used destination yet (first run, or the
    /// destination volume is gone).
    @objc func quickExportAction() {
        PopoverHelper.dismiss()
        guard !isExporting else { return }
        guard let directory = QuickExportDestination.resolve(lastUsedDirectory: VideoExportSettings.lastDirectory(),
                                                              isWritable: { FileManager.default.isWritableFile(atPath: $0.path) }) else {
            showExportPanel(topBar.exportButton)
            return
        }
        let settings = exportSettings
        let ext = settings.format == .gif ? "gif" : "mp4"
        let sourceName = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent
        let stampedBase = QuickExportFilename.build(sourceName: sourceName, date: Date())
        let destination = FreeDestinationPicker.pick(directory: directory, base: stampedBase, ext: ext) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        export(to: destination, directory: directory, quickExport: true)
    }

    func saveVideoAs() {
        guard !isExporting, let window else { return }
        let panel = NSSavePanel()
        let gif = exportSettings.format == .gif
        panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent + (gif ? ".gif" : ".mp4")
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.isExporting, response == .OK, let url = panel.url else { return }
            self.export(to: url, directory: nil)
        }
    }

    private func export(to destination: URL, directory: URL?, quickExport: Bool = false) {
        let directoryLease = SaveDirectoryLease(alreadyAccessing: directory)
        let settings = exportSettings
        let revision = editorDocument.revision
        let snapshot = editorDocument.source
        let sourceURL = editorDocument.source.mediaURL
        let sourceLease = editorDocument.source.lease
        do {
            if settings.format == .gif {
                let staged = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).gif")
                _ = staged
                let request = try exporter.gifRequest(settings, outputURL: destination)
                startExport(status: L("Processing GIF…"), title: destination.lastPathComponent, operation: { cancellation, progress in
                    try await GIFExporter.export(request, cancellation: cancellation, progress: progress)
                }, completion: { [weak self, directoryLease] result in
                    defer { withExtendedLifetime(directoryLease) {} }
                    self?.finishSave(result, destination: destination, revision: revision, snapshot: snapshot, quickExport: quickExport)
                })
                return
            }
            let job: VideoExportJob? = exporter.needsRender(settings)
                ? try exporter.mp4Job(settings, outputURL: destination) : nil
            startExport(status: job == nil ? L("Saving...") : L("Exporting..."), title: destination.lastPathComponent,
                operation: { cancellation, progress in
                    let save = try await MediaExportIO.perform { () throws -> AtomicMediaSave in
                        try cancellation.check()
                        return try AtomicMediaSave(destinationURL: destination)
                    }
                    if let job {
                        try await job.export(to: save.stagingURL) { progress($0) }
                    } else {
                        try await MediaExportIO.perform {
                            try save.copySource(sourceURL, checkCancellation: { try cancellation.check() }, progress: progress)
                        }
                    }
                    try await MediaExportIO.perform {
                        try save.commit(beforePublish: { try cancellation.beginPublication() })
                    }
                }, completion: { [weak self, directoryLease, sourceLease] result in
                    defer { withExtendedLifetime(directoryLease) {}; withExtendedLifetime(sourceLease) {} }
                    self?.finishSave(result, destination: destination, revision: revision, snapshot: snapshot, quickExport: quickExport)
                })
        } catch {
            showStatus(L("Export failed") + ": " + error.localizedDescription, isError: true)
        }
    }

    private func finishSave(_ result: Result<Void, Error>, destination: URL, revision: UInt64, snapshot: VideoSourceSnapshot,
                            quickExport: Bool = false) {
        switch result {
        case .success:
            snapshot.didSave(at: destination)
            if editorDocument.revision == revision {
                savedURL = destination
                savedRevision = revision
            }
            // Quick Export (⇧⌘E) reuses this destination folder next time.
            VideoExportSettings.setLastDirectory(destination.deletingLastPathComponent())
            if quickExport {
                (NSApp.delegate as? AppDelegate)?.showExportCompletedToast(destination)
            }
            showStatus(String(format: L("Saved to %@"), destination.lastPathComponent))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let message = L("Save failed") + ": " + error.localizedDescription
            if window?.isVisible == true { showStatus(message, isError: true) }
            else { (NSApp.delegate as? AppDelegate)?.showFailureToast(message) }
        }
    }

    @objc func revealAction() {
        PopoverHelper.dismiss()
        guard let url = savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Copy

    @objc func copyAction() {
        PopoverHelper.dismiss()
        guard !isExporting else { return }
        let settings = exportSettings
        if let savedURL, savedRevision == editorDocument.revision,
           savedURL.pathExtension.lowercased() == (settings.format == .gif ? "gif" : "mp4") {
            settings.format == .gif ? copyGIFData(from: savedURL) : copyMP4Data(from: savedURL, contentIsMP4: true)
            return
        }
        renderTemporary(settings) { [weak self] url in
            settings.format == .gif ? self?.copyGIFData(from: url) : self?.copyMP4Data(from: url, contentIsMP4: true)
        }
    }

    /// Renders the edited video to a temporary file that outlives the editor.
    private func renderTemporary(_ settings: VideoExportSettings, completion: @escaping (URL) -> Void) {
        let ext = settings.format == .gif ? "gif" : "mp4"
        let base = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macshot-share/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(FilenameSanitizer.sanitize(base) + "." + ext)
        let sourceURL = editorDocument.source.mediaURL
        let sourceLease = editorDocument.source.lease
        do {
            if settings.format == .gif {
                let request = try exporter.gifRequest(settings, outputURL: output)
                startExport(status: L("Processing GIF…"), title: output.lastPathComponent, operation: { cancellation, progress in
                    try await GIFExporter.export(request, cancellation: cancellation, progress: progress)
                }, completion: { [weak self] result in
                    self?.handleTemporary(result, output: output, completion: completion)
                })
                return
            }
            let job: VideoExportJob? = exporter.needsRender(settings) ? try exporter.mp4Job(settings, outputURL: output) : nil
            startExport(status: L("Exporting..."), title: output.lastPathComponent, operation: { cancellation, progress in
                if let job {
                    try await job.export(to: output) { progress($0) }
                    try cancellation.beginPublication()
                } else {
                    // The atomic commit begins publication itself.
                    try await MediaExportIO.perform {
                        let save = try AtomicMediaSave(destinationURL: output)
                        try save.copySource(sourceURL, checkCancellation: { try cancellation.check() }, progress: progress)
                        try save.commit(overwritingExisting: false, beforePublish: cancellation.beginPublication)
                    }
                }
            }, completion: { [weak self, sourceLease] result in
                defer { withExtendedLifetime(sourceLease) {} }
                self?.handleTemporary(result, output: output, completion: completion)
            })
        } catch {
            showStatus(L("Export failed") + ": " + error.localizedDescription, isError: true)
        }
    }

    private func handleTemporary(_ result: Result<Void, Error>, output: URL, completion: (URL) -> Void) {
        switch result {
        case .success:
            completion(output)
        case .failure(let error):
            try? FileManager.default.removeItem(at: output)
            if !(error is CancellationError) { showStatus(L("Export failed") + ": " + error.localizedDescription, isError: true) }
        }
    }

    private func copyGIFData(from url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? UInt64.max
        if bytes <= 150_000_000, let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
        showStatus(L("Copied to clipboard!"))
    }

    /// Inline MP4 bytes (for apps that paste video data) plus the file URL.
    private func copyMP4Data(from url: URL, contentIsMP4: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let isMP4 = contentIsMP4 || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .mpeg4Movie) ?? false)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if isMP4, bytes <= 150_000_000, let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
        showStatus(L("Copied to clipboard!"))
    }

    // MARK: Job lifecycle

    /// One app-owned lifecycle for every export. The progress window stays
    /// usable after the editor closes.
    func startExport(status: String, title: String,
                     operation: @escaping @MainActor (MediaExportCancellation, @escaping @Sendable (Double) -> Void) async throws -> Void,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        // The old path and the preset queue never render at the same time.
        guard !isExporting, exportQueueStorage?.isBusy != true else { completion(.failure(CancellationError())); return }
        isExporting = true
        topBar.exportButton.isEnabled = false
        topBar.copyButton.isEnabled = false
        let token = UUID()
        activeExportToken = token
        showStatus(status, persist: true)
        let job = MediaExportCoordinator.shared.start(title: title, status: status, operation: { [weak self] cancellation, report in
            let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                guard fraction.isFinite else { return }
                report(fraction)
                let percent = Int(max(0, min(1, fraction)) * 100)
                DispatchQueue.main.async {
                    guard let self, self.activeExportToken == token, self.activeExportJob?.isCancelling != true else { return }
                    self.showStatus(status + " \(percent)%", persist: true)
                }
            }
            try await operation(cancellation, progress)
        }, completion: { [weak self] result in
            if let self {
                self.isExporting = false
                self.activeExportJob = nil
                self.activeExportToken = nil
                self.topBar.exportButton.isEnabled = true
                self.topBar.copyButton.isEnabled = true
                if case .failure(let error) = result, error is CancellationError { self.showStatus(L("Cancelled")) }
            }
            completion(result)
        })
        activeExportJob = job
        MediaExportProgressController.show(for: job)
    }
}

// MARK: - Export panel

/// Popover with output settings and the export actions.
final class VideoExportPanel: NSView {
    private var settings: VideoExportSettings
    private weak var controller: VideoEditorWindowController?
    private let summary = VideoEditorStyle.label("", size: 11.5, color: VideoEditorStyle.textSecondary)
    private let stack = NSStackView()
    private var formatRow: InspectorSegmentRow?
    private var qualityRow: InspectorSegmentRow?
    private var fpsRow: InspectorSegmentRow?
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var scales: [CGFloat] = []
    private let presetsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var presets: [ExportPreset] = []
    /// The custom/built-in preset last chosen from the popup (not the
    /// "Save…"/"Delete" action rows) — tracked separately so "Delete Preset"
    /// knows which one, even though picking it moves the popup's own
    /// selection to the action row.
    private var lastSelectedPresetID: UUID?

    init(settings: VideoExportSettings, controller: VideoEditorWindowController) {
        self.settings = settings
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 320),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        stack.addArrangedSubview(VideoEditorStyle.label(L("Export"), size: 14, weight: .semibold))

        let presetsTitle = VideoEditorStyle.label(L("Preset"), size: 12)
        presetsPopup.translatesAutoresizingMaskIntoConstraints = false
        presetsPopup.controlSize = .small
        presetsPopup.target = self
        presetsPopup.action = #selector(presetChanged)
        let presetsRow = NSStackView(views: [presetsTitle, presetsPopup])
        presetsRow.orientation = .vertical
        presetsRow.alignment = .leading
        presetsRow.spacing = 6
        stack.addArrangedSubview(presetsRow)
        fillPresets()

        let format = InspectorSegmentRow(title: L("Format"), labels: ["MP4", "GIF"], selected: settings.format == .gif ? 1 : 0) { [weak self] i in
            self?.settings.format = i == 1 ? .gif : .mp4
            self?.changed()
        }
        formatRow = format
        stack.addArrangedSubview(format)

        let resolutionTitle = VideoEditorStyle.label(L("Resolution"), size: 12)
        resolutionPopup.translatesAutoresizingMaskIntoConstraints = false
        resolutionPopup.controlSize = .small
        resolutionPopup.target = self
        resolutionPopup.action = #selector(resolutionChanged)
        let resolution = NSStackView(views: [resolutionTitle, resolutionPopup])
        resolution.orientation = .vertical
        resolution.alignment = .leading
        resolution.spacing = 6
        stack.addArrangedSubview(resolution)
        fillResolutions()

        let qualities: [VideoQuality] = [.high, .medium, .low]
        let quality = InspectorSegmentRow(title: L("Quality"), labels: [L("High"), L("Medium"), L("Low")],
                                          selected: qualities.firstIndex(of: settings.quality) ?? 0) { [weak self] i in
            self?.settings.quality = qualities[i]
            self?.changed()
        }
        qualityRow = quality
        stack.addArrangedSubview(quality)
        let rates = [10, 15, 20, 25, 30]
        let fps = InspectorSegmentRow(title: L("Frame rate"), labels: rates.map { "\($0)" },
                                      selected: rates.firstIndex(of: settings.gifFPS) ?? 1) { [weak self] i in
            self?.settings.gifFPS = rates[i]
            self?.changed()
        }
        fpsRow = fps
        stack.addArrangedSubview(fps)
        stack.addArrangedSubview(summary)

        guard let controller else { return }
        let save = VideoPillButton(title: L("Save"), symbol: "square.and.arrow.down", target: controller,
                                   action: #selector(VideoEditorWindowController.saveAction))
        save.fill = VideoEditorStyle.accent
        save.textColor = .white
        let saveAs = VideoPillButton(title: L("Save As…"), symbol: nil, target: controller,
                                     action: #selector(VideoEditorWindowController.saveAsAction))
        let copy = VideoPillButton(title: L("Copy"), symbol: "doc.on.doc", target: controller,
                                   action: #selector(VideoEditorWindowController.copyAction))
        let primary = NSStackView(views: [copy, saveAs, save])
        primary.spacing = 8
        primary.distribution = .fillEqually
        stack.addArrangedSubview(primary)
        primary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        var secondary: [NSView] = []
        if controller.savedURL != nil {
            secondary.append(VideoPillButton(title: L("Show in Finder"), symbol: "folder", target: controller,
                                             action: #selector(VideoEditorWindowController.revealAction)))
        }
        if !secondary.isEmpty {
            let row = NSStackView(views: secondary)
            row.spacing = 8
            row.distribution = .fillEqually
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        for view in [presetsRow, format, resolution, quality, fps] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        resolutionPopup.widthAnchor.constraint(equalTo: resolution.widthAnchor).isActive = true
        presetsPopup.widthAnchor.constraint(equalTo: presetsRow.widthAnchor).isActive = true
        updateVisibility()
    }

    // MARK: Presets

    private func fillPresets() {
        presetsPopup.removeAllItems()
        presets = ExportPresetStore.visiblePresets()
        for preset in presets { presetsPopup.addItem(withTitle: preset.name) }
        presetsPopup.menu?.addItem(.separator())
        presetsPopup.addItem(withTitle: L("Save Current as Preset…"))
        presetsPopup.addItem(withTitle: L("Delete Preset"))
        presetsPopup.item(withTitle: L("Delete Preset"))?.isEnabled = presets.contains { $0.id == lastSelectedPresetID && !$0.isBuiltIn }
        if let id = lastSelectedPresetID, let index = presets.firstIndex(where: { $0.id == id }) {
            presetsPopup.selectItem(at: index)
        } else {
            presetsPopup.select(nil)
        }
    }

    @objc private func presetChanged() {
        let index = presetsPopup.indexOfSelectedItem
        guard index >= 0 else { return }
        if index < presets.count { applyPreset(presets[index]); return }
        if index == presets.count + 1 { saveCurrentAsPreset(); return }
        if index == presets.count + 2 { deleteSelectedPreset(); return }
    }

    private func applyPreset(_ preset: ExportPreset) {
        lastSelectedPresetID = preset.id
        settings = preset.resolvedSettings(nativeSize: controller?.exporter.nativeCanvasSize)
        formatRow?.control.selectedSegment = settings.format == .gif ? 1 : 0
        fillResolutions()
        let qualities: [VideoQuality] = [.high, .medium, .low]
        qualityRow?.control.selectedSegment = qualities.firstIndex(of: settings.quality) ?? 0
        let rates = [10, 15, 20, 25, 30]
        fpsRow?.control.selectedSegment = rates.firstIndex(of: settings.gifFPS) ?? 1
        presetsPopup.item(withTitle: L("Delete Preset"))?.isEnabled = !preset.isBuiltIn
        changed()
    }

    private func saveCurrentAsPreset() {
        defer { fillPresets() }
        guard controller != nil else { return }
        let alert = NSAlert()
        alert.messageText = L("Save Current as Preset")
        alert.informativeText = L("Name this preset:")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = L("Preset name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let native = controller?.exporter.nativeCanvasSize
        let longEdge = native.map { max($0.width, $0.height) }
        let longEdgeCap: Int? = (settings.scale >= 0.999) ? nil : longEdge.map { Int(($0 * settings.scale).rounded()) }
        let isGIF = settings.format == .gif
        // Legacy panel: a saved preset is a plain folder preset (no upload).
        let preset = ExportPreset(name: name, format: isGIF ? .gif : .h264, longEdgeCap: longEdgeCap,
                                  fpsCap: isGIF ? settings.gifFPS : nil, quality: settings.quality,
                                  audio: isGIF ? .mute : .keep)
        ExportPresetStore.addOrReplace(preset)
        lastSelectedPresetID = preset.id
    }

    private func deleteSelectedPreset() {
        defer { fillPresets() }
        guard let id = lastSelectedPresetID, let preset = presets.first(where: { $0.id == id }), !preset.isBuiltIn else {
            controller?.showStatus(L("Select a custom preset to delete first"), isError: true)
            return
        }
        ExportPresetStore.delete(id: id)
        lastSelectedPresetID = nil
    }

    private func fillResolutions() {
        resolutionPopup.removeAllItems()
        scales = []
        guard let native = controller?.exporter.nativeCanvasSize else { return }
        let long = max(native.width, native.height)
        var candidates: [CGFloat] = [1]
        for target in [3840.0, 2560, 1920, 1280, 960, 640] where CGFloat(target) < long * 0.98 {
            candidates.append(CGFloat(target) / long)
        }
        for scale in candidates {
            let w = Int((native.width * scale / 2).rounded()) * 2, h = Int((native.height * scale / 2).rounded()) * 2
            let title = scale >= 0.999 ? "\(w) × \(h)  (\(L("Original")))" : "\(w) × \(h)"
            resolutionPopup.addItem(withTitle: title)
            scales.append(scale)
        }
        let index = scales.enumerated().min { abs($0.element - settings.scale) < abs($1.element - settings.scale) }?.offset ?? 0
        resolutionPopup.selectItem(at: index)
        settings.scale = scales[index]
    }

    @objc private func resolutionChanged() {
        let i = resolutionPopup.indexOfSelectedItem
        guard scales.indices.contains(i) else { return }
        settings.scale = scales[i]
        changed()
    }

    private func changed() {
        controller?.exportSettingsChanged(settings)
        updateVisibility()
    }

    private func updateVisibility() {
        qualityRow?.isHidden = settings.format == .gif
        fpsRow?.isHidden = settings.format != .gif
        summary.stringValue = controller?.exportSummary(settings) ?? ""
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
