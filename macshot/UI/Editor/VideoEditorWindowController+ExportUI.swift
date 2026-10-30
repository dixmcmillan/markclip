import AppKit
import UniformTypeIdentifiers

// The editor's export UI: the top-bar split button, the export popover, the
// Save As… panel and the Save as Preset… prompt. The engine is `exportQueue`
// (see `+Export.swift`); this file only presents it.
extension VideoEditorWindowController {

    /// Connects the top bar to the export queue. Called once the interface exists.
    func bindExportQueue() {
        let queue = exportQueue
        topBar.exportControl.setLastUsed(name: ExportPresetStore.lastUsedPreset()?.name)
        topBar.exportControl.apply(queue.state)
        var wasBusy = queue.state.isBusy
        exportQueueObserver = queue.observe { [weak self] state in
            guard let self else { return }
            self.topBar.exportControl.apply(state)
            // Status text only on the busy -> idle edge; record polling re-sends the same state.
            defer { wasBusy = state.isBusy }
            guard wasBusy, !state.isBusy, let result = state.lastResult else { return }
            if result.wasCancelled {
                self.showStatus(L("Cancelled"))
            } else if result.succeeded, result.remoteKind == nil, let file = result.localFile {
                self.showStatus(String(format: L("Saved to %@"), file.lastPathComponent))
            }
        }
    }

    // MARK: Running presets

    /// Runs `preset` now (or queues it) and remembers it as the last used.
    /// The top bar's main segment and ⇧⌘E run the same thing.
    @objc func runLastExportAction() {
        guard let preset = ExportPresetStore.lastUsedPreset() else { return }
        PopoverHelper.dismiss()
        runExportPreset(preset)
        topBar.exportControl.setLastUsed(name: preset.name)
    }

    /// File ▸ Export Preset ▸ …
    func runExportPresetFromMenu(_ preset: ExportPreset) {
        PopoverHelper.dismiss()
        runExportPreset(preset)
        topBar.exportControl.setLastUsed(name: preset.name)
    }

    // MARK: Popover

    /// Opens (or closes) the export popover under the split button.
    @objc func showExportPopover(_ sender: Any?) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let anchor = topBar?.exportControl else { return }
        let queue = exportQueue
        let model = ExportPopoverModel(environment: exportPopoverEnvironment())
        activeExportPopoverModel = model
        var handlers = ExportPopoverView.Handlers()
        handlers.run = { [weak self] preset, overrides in
            PopoverHelper.dismiss()
            self?.runExportPreset(preset, overrides: overrides)
            self?.topBar.exportControl.setLastUsed(name: preset.name)
        }
        handlers.saveAs = { [weak self] preset, overrides in
            PopoverHelper.dismiss()
            self?.presentSaveAsPanel(preset: preset, overrides: overrides)
        }
        handlers.savePreset = { [weak self] model in
            PopoverHelper.dismiss()
            self?.promptSavePreset(model)
        }
        handlers.cancelCurrent = { [weak queue] in queue?.cancelCurrent(dropQueued: false) }
        handlers.cancelQueued = { [weak queue] ticket in queue?.cancelQueued(ticket: ticket) }
        handlers.openCloudflareSettings = {
            PopoverHelper.dismiss()
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: SettingsWindowController.cloudflareTabID)
        }
        handlers.openExportSettings = {
            PopoverHelper.dismiss()
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: SettingsWindowController.exportTabID)
        }
        let view = ExportPopoverView(model: model, queue: queue, records: queue.records, handlers: handlers)
        PopoverHelper.showAutoLayout(view, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Pick up a Stream video that finished while the popover was closed,
        // and retry deleting a replaced one.
        Task { await queue.refreshRemoteState() }
    }

    func exportPopoverEnvironment() -> ExportPopoverModel.Environment {
        ExportPopoverModel.Environment(
            nativeSize: { [weak self] in self?.exporter.nativeCanvasSize },
            outputSize: { [weak self] settings in self?.exporter.outputSize(settings) },
            estimatedBytes: { [weak self] settings in self?.exporter.estimatedBytes(settings) },
            outputDuration: { [weak self] in
                self.map { VideoRenderPlanner.outputDuration(project: $0.editorDocument.project) } ?? 0
            },
            cloudflareConfigured: { ExportCloudflareSupport.isConfigured },
            cloudflareAccountID: { ExportCloudflareSupport.accountID },
            coachOSConfigured: { ExportCoachOSSupport.isConfigured })
    }

    // MARK: Save As…

    /// ⇧⌘S and File ▸ Save As…: the same panel as the popover's Save As…, for
    /// the preset selected in the open popover (with its Adjust overrides),
    /// otherwise the last-used preset.
    @objc func saveAsAction() {
        guard window?.attachedSheet == nil else { return }
        let preset: ExportPreset
        var overrides = ExportOverrides()
        if PopoverHelper.isVisible, let model = activeExportPopoverModel {
            guard model.canSaveAs else { return }
            preset = model.selectedPreset
            overrides = model.overrides
        } else if let last = ExportPresetStore.lastUsedPreset() {
            preset = last
        } else {
            return
        }
        PopoverHelper.dismiss()
        presentSaveAsPanel(preset: preset, overrides: overrides)
    }

    /// Asks where to put one export of `preset`'s encoding, then queues it.
    /// Local only: Save As never uploads.
    func presentSaveAsPanel(preset: ExportPreset, overrides: ExportOverrides) {
        guard let window else { return }
        let effective = overrides.applied(to: preset)
        let gif = effective.format.isGIF
        let panel = NSSavePanel()
        panel.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        let base = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = ExportRun.fileBase(base) + (gif ? ".gif" : ".mp4")
        panel.directoryURL = preset.destination.resolvedFolderURL().flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? SaveDirectoryAccess.recordingDirectoryHint()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var chosen = overrides
            chosen.saveAsURL = url
            self.runExportPreset(preset, overrides: chosen)
            self.topBar.exportControl.setLastUsed(name: preset.name)
        }
    }

    // MARK: Save as Preset…

    func promptSavePreset(_ model: ExportPopoverModel) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Save as Preset")
        alert.informativeText = L("Name this preset:")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = L("Preset name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let preset = model.saveAsPreset(named: name)
            ExportPresetStore.setLastUsedID(preset.id)
            NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
            self?.topBar.exportControl.setLastUsed(name: preset.name)
            self?.showStatus(String(format: L("Saved preset %@"), preset.name))
        }
    }
}
