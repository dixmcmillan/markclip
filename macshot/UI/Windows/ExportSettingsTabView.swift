import Cocoa

/// Settings ▸ Export: the preset list on the left, every field of the selected
/// preset on the right. Edits are saved at once (`ExportSettingsModel`); the
/// File ▸ Export Preset menu follows through `.exportPresetsChanged`.
@MainActor
final class ExportSettingsTabView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let labelWidth: CGFloat = 170
    private static let listWidth: CGFloat = 190

    let model: ExportSettingsModel
    /// Asks the Settings window to switch to its Cloudflare tab.
    var onOpenCloudflareTab: (() -> Void)?

    // List
    private let table = NSTableView()
    private let addButton = NSButton()
    private let duplicateButton = NSButton()
    private let removeButton = NSButton()

    // Form
    private let formStack = FlippedFormStack()
    private var rows: [String: NSView] = [:]
    private let nameField = NSTextField()
    private let formatControl = NSSegmentedControl(labels: ["H.264", "HEVC", "GIF"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityControl = NSSegmentedControl(labels: [L("High"), L("Medium"), L("Low")], trackingMode: .selectOne, target: nil, action: nil)
    private let bitrateField = NSTextField()
    private let audioControl = NSSegmentedControl(labels: [L("Keep"), L("Mute")], trackingMode: .selectOne, target: nil, action: nil)
    private let captionsControl = NSSegmentedControl(labels: [L("Burned in"), L("Soft"), L("Off")], trackingMode: .selectOne, target: nil, action: nil)
    private let destinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton()
    private let cloudflareNote = NSTextField(wrappingLabelWithString: "")
    private let cloudflareButton = NSButton()
    private let saveLocallyCheckbox = NSButton(checkboxWithTitle: L("Also save a copy on this Mac"), target: nil, action: nil)
    private let signedCheckbox = NSButton(checkboxWithTitle: L("Require signed URLs"), target: nil, action: nil)
    private var gifFields: [GIFFitField: NSTextField] = [:]
    private let shortcutField = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private let clearShortcutButton = NSButton()
    private let resetShortcutButton = NSButton()
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var isRecording = false
    private var keyMonitor: Any?
    private var isRefreshing = false
    private var isReloadingTable = false

    init(model: ExportSettingsModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildList()
        buildForm()
        model.onChange = { [weak self] in self?.reloadAll() }
        reloadAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preset"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L("Export presets"))
        // System colors throughout: the list follows the window's appearance
        // (Settings is not a dark toolbar/popover context) and selection uses
        // the standard emphasized colors.
        table.style = .inset
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configure(addButton, symbol: "plus", tooltip: L("New preset"), action: #selector(addPreset))
        configure(duplicateButton, symbol: "plus.square.on.square", tooltip: L("Duplicate preset"), action: #selector(duplicatePreset))
        configure(removeButton, symbol: "minus", tooltip: L("Delete preset"), action: #selector(deletePreset))
        let buttons = NSStackView(views: [addButton, duplicateButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        listScroll = scroll
    }

    private var listScroll: NSScrollView!

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .smallSquare
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
    }

    private func buildForm() {
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 20)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = formStack
        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            formStack.topAnchor.constraint(equalTo: clip.topAnchor),
            formStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        nameField.placeholderString = L("Preset name")
        nameField.delegate = self
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        addRow("name", L("Name:"), [nameField])

        for control in [formatControl, qualityControl, audioControl, captionsControl] { control.segmentStyle = .rounded }
        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        addRow("format", L("Format:"), [formatControl])

        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        addRow("size", L("Size:"), [sizePopup])
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        addRow("fps", L("Frame rate cap:"), [fpsPopup])

        qualityControl.target = self
        qualityControl.action = #selector(qualityChanged)
        addRow("quality", L("Quality:"), [qualityControl])

        bitrateField.placeholderString = L("Auto")
        bitrateField.alignment = .right
        bitrateField.delegate = self
        bitrateField.target = self
        bitrateField.action = #selector(bitrateCommitted)
        bitrateField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let bitrateHint = hint(L("Mbps. Overrides quality; empty uses the quality tier."))
        bitrateHint.lineBreakMode = .byWordWrapping
        bitrateHint.maximumNumberOfLines = 3
        bitrateHint.cell?.wraps = true
        bitrateHint.preferredMaxLayoutWidth = 200
        addRow("bitrate", L("Bitrate:"), [bitrateField, bitrateHint])

        audioControl.target = self
        audioControl.action = #selector(audioChanged)
        addRow("audio", L("Audio:"), [audioControl])
        captionsControl.target = self
        captionsControl.action = #selector(captionsChanged)
        addRow("captions", L("Captions:"), [captionsControl])

        destinationPopup.target = self
        destinationPopup.action = #selector(destinationChanged)
        addRow("destination", L("Destination:"), [destinationPopup])

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseFolderButton.title = L("Choose…")
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)
        addRow("folder", L("Folder:"), [folderLabel, chooseFolderButton])

        cloudflareNote.stringValue = L("This destination uploads to Cloudflare, which isn't set up yet.")
        cloudflareNote.font = .systemFont(ofSize: 11)
        cloudflareNote.textColor = .secondaryLabelColor
        cloudflareButton.title = L("Set up Cloudflare in Settings")
        cloudflareButton.bezelStyle = .rounded
        cloudflareButton.target = self
        cloudflareButton.action = #selector(openCloudflare)
        let cloudflareColumn = NSStackView(views: [cloudflareNote, cloudflareButton])
        cloudflareColumn.orientation = .vertical
        cloudflareColumn.alignment = .leading
        cloudflareColumn.spacing = 6
        addRow("cloudflare", "", [cloudflareColumn])

        saveLocallyCheckbox.target = self
        saveLocallyCheckbox.action = #selector(saveLocallyChanged)
        addRow("saveLocally", "", [saveLocallyCheckbox])
        signedCheckbox.target = self
        signedCheckbox.action = #selector(signedChanged)
        addRow("signed", "", [signedCheckbox])

        // GIF auto-fit budget (Cloudflare Images).
        let gifTitles: [(GIFFitField, String)] = [
            (.maxMegabytes, L("Max file size (MB):")), (.maxMegapixels, L("Max total area (MP):")),
            (.minLongEdge, L("Smallest long edge (px):")), (.minFPS, L("Lowest frame rate:")),
            (.startFPS, L("Starting frame rate:")),
        ]
        let gifHeader = NSTextField(labelWithString: L("GIF auto-fit").uppercased())
        gifHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        gifHeader.textColor = .secondaryLabelColor
        addRow("gifHeader", "", [gifHeader])
        for (field, title) in gifTitles {
            let input = NSTextField()
            input.alignment = .right
            input.delegate = self
            input.target = self
            input.action = #selector(gifFieldCommitted(_:))
            input.widthAnchor.constraint(equalToConstant: 80).isActive = true
            input.setAccessibilityLabel(title)
            gifFields[field] = input
            addRow("gif.\(field)", title, [input])
        }

        shortcutField.alignment = .center
        shortcutField.wantsLayer = true
        shortcutField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        recordButton.title = L("Set")
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        clearShortcutButton.title = L("Clear")
        clearShortcutButton.bezelStyle = .rounded
        clearShortcutButton.target = self
        clearShortcutButton.action = #selector(clearShortcut)
        resetShortcutButton.title = L("Reset")
        resetShortcutButton.bezelStyle = .rounded
        resetShortcutButton.target = self
        resetShortcutButton.action = #selector(resetShortcut)
        addRow("shortcut", L("Shortcut:"), [shortcutField, recordButton, clearShortcutButton, resetShortcutButton])
        shortcutMessage.font = .systemFont(ofSize: 10)
        shortcutMessage.textColor = .secondaryLabelColor
        addRow("shortcutMessage", "", [shortcutMessage])

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        addRow("summary", "", [summaryLabel])
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .systemOrange
        addRow("note", "", [noteLabel])
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        addRow("error", "", [errorLabel])

        destinationPopup.removeAllItems()
        for kind in model.availableDestinations {
            destinationPopup.addItem(withTitle: Self.title(for: kind))
            destinationPopup.lastItem?.tag = Self.tag(for: kind)
        }
    }

    private static func title(for kind: ExportSettingsModel.DestinationKind) -> String {
        switch kind {
        case .folder: return L("Folder on this Mac")
        case .stream: return L("Cloudflare Stream")
        case .images: return L("Cloudflare Images")
        case .trainWithDixon: return L("TrainWithDixon")
        }
    }

    private static func tag(for kind: ExportSettingsModel.DestinationKind) -> Int {
        switch kind { case .folder: return 0; case .stream: return 1; case .images: return 2; case .trainWithDixon: return 3 }
    }

    private func kind(forTag tag: Int) -> ExportSettingsModel.DestinationKind {
        switch tag { case 1: return .stream; case 2: return .images; case 3: return .trainWithDixon; default: return .folder }
    }

    @discardableResult
    private func addRow(_ id: String, _ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(row)
        rows[id] = row
        return row
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func show(_ id: String, _ visible: Bool) { rows[id]?.isHidden = !visible }

    // MARK: Refresh

    private func reloadAll() {
        // The table reports selection changes caused by this very reload; they
        // must not feed back into the model.
        isReloadingTable = true
        defer { isReloadingTable = false }
        let selected = model.selectedID
        table.reloadData()
        if let selected, let index = model.presets.firstIndex(where: { $0.id == selected }) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        }
        refreshForm()
    }

    private func refreshForm() {
        isRefreshing = true
        defer { isRefreshing = false }
        let preset = model.selected
        let enabled = preset != nil
        formStack.isHidden = !enabled
        removeButton.isEnabled = preset.map { !$0.isBuiltIn } ?? false
        duplicateButton.isEnabled = enabled
        guard let preset else { return }

        if nameField.currentEditor() == nil { nameField.stringValue = preset.name }
        let formats: [ExportFormat] = [.h264, .hevc, .gif]
        formatControl.selectedSegment = formats.firstIndex(of: preset.format) ?? 0
        let isGIF = preset.format.isGIF

        fill(sizePopup, values: ExportAdjustState.longEdgeChoices, current: preset.longEdgeCap, none: L("Source size")) {
            String(format: L("%d px"), $0)
        }
        fill(fpsPopup, values: ExportAdjustState.fpsChoices, current: preset.fpsCap, none: isGIF ? L("Auto") : L("Source rate")) {
            String(format: L("%d fps"), $0)
        }
        let qualities: [VideoQuality] = [.high, .medium, .low]
        qualityControl.selectedSegment = qualities.firstIndex(of: preset.quality) ?? 0
        if bitrateField.currentEditor() == nil {
            bitrateField.stringValue = preset.explicitBitrate.map(ExportPresetDescription.megabitsText) ?? ""
        }
        audioControl.selectedSegment = preset.audio == .keep ? 0 : 1
        let captions: [ExportCaptionsMode] = [.burned, .soft, .off]
        captionsControl.selectedSegment = captions.firstIndex(of: preset.captions) ?? 0

        let kind: ExportSettingsModel.DestinationKind
        switch preset.destination {
        case .folder: kind = .folder
        case .stream: kind = .stream
        case .images: kind = .images
        case .trainWithDixon: kind = .trainWithDixon
        }
        destinationPopup.selectItem(withTag: Self.tag(for: kind))
        folderLabel.stringValue = ExportPresetDescription.destination(for: preset)
        let uploads = kind != .folder
        saveLocallyCheckbox.state = preset.alsoSaveLocally ? .on : .off
        signedCheckbox.state = preset.requireSignedURLs ? .on : .off
        for (field, input) in gifFields where input.currentEditor() == nil {
            input.stringValue = field.text(for: preset.gifFit)
        }
        refreshShortcut(for: preset)

        show("quality", !isGIF)
        show("bitrate", !isGIF)
        show("audio", !isGIF)
        show("folder", kind == .folder)
        if kind == .trainWithDixon {
            cloudflareNote.stringValue = L("This destination uploads through Coach OS, whose address isn't set yet.")
            cloudflareButton.title = L("Set up TrainWithDixon in Settings")
            show("cloudflare", !ExportCoachOSSupport.isConfigured)
        } else {
            cloudflareNote.stringValue = L("This destination uploads to Cloudflare, which isn't set up yet.")
            cloudflareButton.title = L("Set up Cloudflare in Settings")
            show("cloudflare", uploads && !ExportCloudflareSupport.isConfigured)
        }
        show("saveLocally", uploads)
        show("signed", kind == .stream)
        let showFit = isGIF && kind == .images
        show("gifHeader", showFit)
        for field in GIFFitField.allCases { show("gif.\(field)", showFit) }

        summaryLabel.stringValue = ExportPresetDescription.summary(for: preset) + "\n" + ExportPresetDescription.destination(for: preset)
        if let note = model.compatibilityNote(for: preset) {
            noteLabel.stringValue = note
            show("note", true)
        } else {
            show("note", false)
        }
        if errorLabel.stringValue.isEmpty { show("error", false) }
    }

    private func refreshShortcut(for preset: ExportPreset) {
        shortcutField.stringValue = isRecording ? L("Waiting...") : (model.shortcutText(for: preset.id) ?? L("None"))
        recordButton.title = isRecording ? L("Press keys...") : L("Set")
        show("shortcutMessage", !shortcutMessage.stringValue.isEmpty)
    }

    private func fill(_ popup: NSPopUpButton, values: [Int], current: Int?, none: String, title: (Int) -> String) {
        var choices = values
        if let current, !choices.contains(current) { choices.append(current); choices.sort(by: >) }
        popup.removeAllItems()
        popup.addItem(withTitle: none)
        popup.lastItem?.tag = 0
        for value in choices {
            popup.addItem(withTitle: title(value))
            popup.lastItem?.tag = value
        }
        popup.selectItem(withTag: current ?? 0)
    }

    private func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        show("error", message != nil)
    }

    private func edit(_ body: (UUID) -> Void) {
        guard !isRefreshing, let id = model.selectedID else { return }
        showError(nil)
        body(id)
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.presets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.presets.indices.contains(row) else { return nil }
        let preset = model.presets[row]
        let identifier = NSUserInterfaceItemIdentifier("presetCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ExportPresetCell) ?? ExportPresetCell()
        cell.identifier = identifier
        cell.nameField.delegate = self
        cell.nameField.stringValue = preset.name
        cell.nameField.tag = row
        cell.hintField.stringValue = model.shortcutText(for: preset.id) ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingTable else { return }
        let row = table.selectedRow
        guard model.presets.indices.contains(row) else { return }
        let id = model.presets[row].id
        if id != model.selectedID {
            stopRecording()
            shortcutMessage.stringValue = ""
            showError(nil)
            model.select(id)
        }
    }

    // MARK: Actions

    @objc private func addPreset() { _ = model.addPreset(); NotificationCenter.default.post(name: .exportPresetsChanged, object: nil) }

    @objc private func duplicatePreset() {
        guard let id = model.selectedID else { return }
        _ = model.duplicate(id)
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    @objc private func deletePreset() {
        guard let id = model.selectedID else { return }
        stopRecording()
        _ = model.delete(id)
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    private func commitName(_ name: String) {
        edit { model.rename($0, to: name) }
    }

    @objc private func formatChanged() {
        let formats: [ExportFormat] = [.h264, .hevc, .gif]
        let format = formats[max(0, formatControl.selectedSegment)]
        edit { model.setFormat($0, format) }
    }

    @objc private func sizeChanged() {
        let value = sizePopup.selectedItem?.tag ?? 0
        edit { id in model.update(id) { $0.longEdgeCap = value > 0 ? value : nil } }
    }

    @objc private func fpsChanged() {
        let value = fpsPopup.selectedItem?.tag ?? 0
        edit { id in model.update(id) { $0.fpsCap = value > 0 ? value : nil } }
    }

    @objc private func qualityChanged() {
        let qualities: [VideoQuality] = [.high, .medium, .low]
        let quality = qualities[max(0, qualityControl.selectedSegment)]
        edit { id in model.update(id) { $0.quality = quality } }
    }

    @objc private func bitrateCommitted() {
        let text = bitrateField.stringValue
        edit { id in
            if model.setBitrate(id, text: text) == .invalid {
                showError(L("Enter a bitrate above 0 and up to 500 Mbps, or leave it empty."))
            }
        }
    }

    @objc private func audioChanged() {
        let audio: ExportAudioMode = audioControl.selectedSegment == 1 ? .mute : .keep
        edit { id in model.update(id) { $0.audio = audio } }
    }

    @objc private func captionsChanged() {
        let modes: [ExportCaptionsMode] = [.burned, .soft, .off]
        let mode = modes[max(0, captionsControl.selectedSegment)]
        edit { id in model.update(id) { $0.captions = mode } }
    }

    @objc private func destinationChanged() {
        let kind = kind(forTag: destinationPopup.selectedItem?.tag ?? 0)
        edit { model.setDestination($0, kind) }
    }

    @objc private func chooseFolder() {
        guard let id = model.selectedID, let preset = model.selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.directoryURL = preset.destination.resolvedFolderURL()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.edit { _ in self.model.setFolder(id, to: url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    @objc private func saveLocallyChanged() {
        let on = saveLocallyCheckbox.state == .on
        edit { id in model.update(id) { $0.alsoSaveLocally = on } }
    }

    @objc private func signedChanged() {
        let on = signedCheckbox.state == .on
        edit { id in model.update(id) { $0.requireSignedURLs = on } }
    }

    @objc private func gifFieldCommitted(_ sender: NSTextField) {
        guard let field = gifFields.first(where: { $0.value === sender })?.key else { return }
        let text = sender.stringValue
        edit { id in
            if let error = model.setGIFFit(id, field: field, text: text) {
                showError(error)
                if let preset = model.selected { sender.stringValue = field.text(for: preset.gifFit) }
            }
        }
    }

    @objc private func openCloudflare() { onOpenCloudflareTab?() }

    // MARK: Text fields

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, !isRefreshing else { return }
        if field === nameField {
            commitName(field.stringValue)
        } else if field.superview is ExportPresetCell, model.presets.indices.contains(field.tag) {
            // Inline rename in the list.
            model.rename(model.presets[field.tag].id, to: field.stringValue)
            NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
        } else if field === bitrateField {
            bitrateCommitted()
        } else if gifFields.values.contains(where: { $0 === field }) {
            gifFieldCommitted(field)
        }
    }

    // MARK: Shortcut recording

    @objc private func toggleRecording() {
        if isRecording { stopRecording(); return }
        guard model.selectedID != nil else { return }
        isRecording = true
        shortcutMessage.stringValue = ""
        if let preset = model.selected { refreshShortcut(for: preset) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handleRecordedKey(event) ? nil : event
        }
    }

    /// Returns true when the key was consumed.
    private func handleRecordedKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {   // Escape cancels
            stopRecording()
            return true
        }
        let modifiers = KeyboardShortcutMatcher.modifiers(in: event)
        // Preset chords are menu key equivalents, so they need ⌘ or ⌃
        // (⌃⌘1 is the default); ⇧ and ⌥ may be added.
        guard let character = KeyboardShortcutMatcher.semanticCharacter(for: event) else { return true }
        let shortcut = EditorCommandShortcutManager.Shortcut(character: character, modifiers: modifiers)
        guard let id = model.selectedID else { return true }
        switch model.assignShortcut(shortcut, to: id) {
        case .rejected(let message):
            shortcutMessage.stringValue = message
        case .assigned(let tookFrom):
            shortcutMessage.stringValue = tookFrom.map { String(format: L("Took this shortcut from %@."), $0) } ?? ""
            NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
            stopRecording()
        }
        if let preset = model.selected { refreshShortcut(for: preset) }
        return true
    }

    private func stopRecording() {
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let preset = model.selected { refreshShortcut(for: preset) }
    }

    @objc private func clearShortcut() {
        guard let id = model.selectedID else { return }
        stopRecording()
        shortcutMessage.stringValue = ""
        model.clearShortcut(id)
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    @objc private func resetShortcut() {
        guard let id = model.selectedID else { return }
        stopRecording()
        shortcutMessage.stringValue = ""
        model.resetShortcut(id)
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Switching tabs (or closing Settings) must not leave a key monitor swallowing keys.
        if window == nil { stopRecording() } else { model.reload() }
    }

    // MARK: Test access

    var formControls: (name: NSTextField, bitrate: NSTextField, destination: NSPopUpButton, format: NSSegmentedControl) {
        (nameField, bitrateField, destinationPopup, formatControl)
    }
    func isRowVisible(_ id: String) -> Bool { rows[id].map { !$0.isHidden } ?? false }
    var recordingActive: Bool { isRecording }
    var tableRowCount: Int { table.numberOfRows }
    var errorText: String { errorLabel.stringValue }
}

/// A preset row: editable name, shortcut hint on the right.
private final class ExportPresetCell: NSTableCellView {
    let nameField = NSTextField()
    let hintField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = true
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false
        hintField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hintField.textColor = .secondaryLabelColor
        hintField.translatesAutoresizingMaskIntoConstraints = false
        hintField.setContentHuggingPriority(.required, for: .horizontal)
        hintField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(nameField)
        addSubview(hintField)
        textField = nameField
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 4),
            hintField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hintField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Selected rows use light-on-accent text; the shortcut hint follows.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            nameField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            hintField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

/// Top-pinned vertical stack for the scrolling form.
private final class FlippedFormStack: NSStackView {
    override var isFlipped: Bool { true }
}
