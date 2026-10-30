import AppKit

extension ExportStage {
    /// The stage name for progress text.
    var localizedTitle: String {
        switch self {
        case .preparing: return L("Preparing…")
        case .rendering: return L("Rendering…")
        case .publishing: return L("Saving…")
        case .uploading: return L("Uploading…")
        case .captions: return L("Adding captions…")
        }
    }
}

/// The export popover: pick a preset, see what it will do, adjust it for this
/// run, then export. Laid out entirely with Auto Layout: the width is one
/// constraint, the height is whatever the visible rows need, and
/// `PopoverHelper.resizeActive(to:)` follows it when a disclosure opens or a
/// status line appears. (The panel this replaces had a fixed frame and a
/// one-time `fittingSize`, which left controls without hit areas.)
@MainActor
final class ExportPopoverView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 340
    private static let inset: CGFloat = 16
    private static let contentWidth = width - 2 * inset
    private static let cardTextWidth = contentWidth - 24

    /// What the popover asks the editor to do. Every closure is optional so
    /// tests and probes can show the view on its own.
    struct Handlers {
        var run: (ExportPreset, ExportOverrides) -> Void = { _, _ in }
        var saveAs: (ExportPreset, ExportOverrides) -> Void = { _, _ in }
        var savePreset: (ExportPopoverModel) -> Void = { _ in }
        var cancelCurrent: () -> Void = {}
        var cancelQueued: (UUID) -> Void = { _ in }
        var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var openCloudflareSettings: () -> Void = {}
        var openExportSettings: () -> Void = {}
    }

    let model: ExportPopoverModel
    private let queue: ExportQueue?
    private let records: ExportRecordStore?
    private let handlers: Handlers
    private var queueObserver: UUID?
    private var queueState = ExportQueueState()
    private var isAdjustOpen = false
    private var shownPresetIDs: [UUID] = []
    private var statusLine: ExportStatusLine?

    // Rows
    private let stack = NSStackView()
    private let presetStack = NSStackView()
    private let summaryLabel = ExportPopoverView.wrapping("", size: 12)
    private let destinationLabel = ExportPopoverView.wrapping("", size: 11.5, color: VideoEditorStyle.textSecondary)
    private let detailLabel = ExportPopoverView.wrapping("", size: 11.5, color: VideoEditorStyle.textSecondary)
    private let statusStack = NSStackView()
    private let statusLabel = ExportPopoverView.wrapping("", size: 11.5)
    private let dashboardButton = ExportPopoverView.linkButton(L("Open in dashboard"))
    private let retryButton = ExportPopoverView.linkButton(L("Retry"))
    private let setupStack = NSStackView()
    private var setupLabel = NSTextField()
    private var setupButton = NSButton()
    private let adjustButton = NSButton()
    private let adjustStack = NSStackView()
    private var formatRow: InlineSegmentRow!
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sizeRow: NSStackView!
    private var fpsRow: NSStackView!
    private var qualityRow: InlineSegmentRow!
    private let bitrateField = NSTextField()
    private var bitrateRow: NSStackView!
    private let bitrateError = ExportPopoverView.wrapping("", size: 11, color: NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1))
    private var audioRow: InlineSegmentRow!
    private var captionsRow: InlineSegmentRow!
    private let resetButton = NSButton()
    private let savePresetButton = NSButton()
    private let busyStack = NSStackView()
    private let busyLabel = VideoEditorStyle.label("", size: 12, weight: .medium)
    private let progressBar = NSProgressIndicator()
    private let cancelButton = VideoPillButton(title: L("Cancel"), symbol: nil, target: nil, action: nil)
    private let queuedStack = NSStackView()
    private let failureLabel = ExportPopoverView.wrapping("", size: 11.5, color: NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1))
    private let saveAsButton = VideoPillButton(title: L("Save As…"), symbol: nil, target: nil, action: nil)
    private let exportButton = VideoPillButton(title: L("Export"), symbol: "square.and.arrow.up", target: nil, action: nil)

    init(model: ExportPopoverModel, queue: ExportQueue?, records: ExportRecordStore?, handlers: Handlers = Handlers()) {
        self.model = model
        self.queue = queue
        self.records = records
        self.handlers = handlers
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        model.onChange = { [weak self] in self?.refresh() }
        if let queue {
            queueState = queue.state
            queueObserver = queue.observe { [weak self] state in
                self?.queueState = state
                self?.refresh()
            }
        }
        refresh(resize: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let queue, let queueObserver {
            queue.removeObserver(queueObserver)
            self.queueObserver = nil
        }
    }

    // MARK: Build

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
        ])

        // Header
        let title = VideoEditorStyle.label(L("Export"), size: 14, weight: .semibold)
        let settingsButton = VideoIconButton(symbol: "gearshape", size: 12, tooltip: L("Edit presets in Settings"),
                                             target: self, action: #selector(openExportSettings))
        settingsButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let header = Self.row([title, Self.spacer(), settingsButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        add(header)

        // Presets
        presetStack.orientation = .vertical
        presetStack.alignment = .leading
        presetStack.spacing = 2
        add(presetStack)

        // Summary card
        for label in [summaryLabel, destinationLabel, detailLabel] { label.preferredMaxLayoutWidth = Self.cardTextWidth }
        let card = InspectorCard([summaryLabel, destinationLabel, detailLabel])
        card.stack.spacing = 4
        add(card)

        // Upload setup notice (Cloudflare or TrainWithDixon)
        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 4
        setupLabel = Self.wrapping(L("This preset uploads to Cloudflare, which isn't set up yet."), size: 11.5,
                                       color: VideoEditorStyle.textSecondary)
        setupButton = Self.linkButton(L("Set up Cloudflare in Settings"))
        setupButton.target = self
        setupButton.action = #selector(openCloudflareSettings)
        setupStack.addArrangedSubview(setupLabel)
        setupStack.addArrangedSubview(setupButton)
        add(setupStack)

        // Upload status
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 4
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth
        dashboardButton.target = self
        dashboardButton.action = #selector(openDashboard)
        retryButton.target = self
        retryButton.action = #selector(retry)
        let statusActions = NSStackView(views: [dashboardButton, retryButton])
        statusActions.orientation = .horizontal
        statusActions.spacing = 12
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(statusActions)
        add(statusStack)

        // Adjust
        adjustButton.isBordered = false
        adjustButton.setButtonType(.momentaryChange)
        adjustButton.imagePosition = .imageLeading
        adjustButton.alignment = .left
        adjustButton.target = self
        adjustButton.action = #selector(toggleAdjust)
        adjustButton.focusRingType = .none
        adjustButton.translatesAutoresizingMaskIntoConstraints = false
        adjustButton.setAccessibilityLabel(L("Adjust"))
        add(adjustButton)

        buildAdjust()
        add(adjustStack)

        // Progress
        busyStack.orientation = .vertical
        busyStack.alignment = .leading
        busyStack.spacing = 6
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelCurrent)
        let busyRow = Self.row([busyLabel, Self.spacer(), cancelButton])
        busyRow.orientation = .horizontal
        busyRow.alignment = .centerY
        busyStack.addArrangedSubview(busyRow)
        busyStack.addArrangedSubview(progressBar)
        busyRow.widthAnchor.constraint(equalTo: busyStack.widthAnchor).isActive = true
        progressBar.widthAnchor.constraint(equalTo: busyStack.widthAnchor).isActive = true
        add(busyStack)

        queuedStack.orientation = .vertical
        queuedStack.alignment = .leading
        queuedStack.spacing = 2
        add(queuedStack)

        failureLabel.preferredMaxLayoutWidth = Self.contentWidth
        add(failureLabel)

        // Actions
        saveAsButton.target = self
        saveAsButton.action = #selector(saveAs)
        exportButton.target = self
        exportButton.action = #selector(runExport)
        exportButton.fill = VideoEditorStyle.accentFill
        exportButton.textColor = .white
        exportButton.keyEquivalent = "\r"
        let actions = Self.row([Self.spacer(), saveAsButton, exportButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        add(actions)
        for button in [saveAsButton, exportButton] { button.heightAnchor.constraint(equalToConstant: 30).isActive = true }
    }

    private func buildAdjust() {
        adjustStack.orientation = .vertical
        adjustStack.alignment = .leading
        adjustStack.spacing = 8
        adjustStack.translatesAutoresizingMaskIntoConstraints = false

        let formats: [ExportFormat] = [.h264, .hevc, .gif]
        formatRow = InlineSegmentRow(title: L("Format"), labels: formats.map(ExportPresetDescription.formatName)) { [model] i in
            model.updateAdjust { $0.format = formats[i] }
        }

        sizePopup.controlSize = .small
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        sizeRow = Self.titled(L("Size"), sizePopup)
        fpsPopup.controlSize = .small
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        fpsRow = Self.titled(L("Frame rate"), fpsPopup)

        let qualities: [VideoQuality] = [.high, .medium, .low]
        qualityRow = InlineSegmentRow(title: L("Quality"), labels: [L("High"), L("Medium"), L("Low")]) { [model] i in
            model.updateAdjust { $0.quality = qualities[i] }
        }

        bitrateField.placeholderString = L("Auto")
        bitrateField.controlSize = .small
        bitrateField.font = VideoEditorStyle.mono(11.5, .regular)
        bitrateField.alignment = .right
        bitrateField.delegate = self
        bitrateField.translatesAutoresizingMaskIntoConstraints = false
        bitrateField.setAccessibilityLabel(L("Bitrate (Mbps)"))
        bitrateField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let bitrateTitle = VideoEditorStyle.label(L("Bitrate (Mbps)"), size: 12)
        bitrateRow = Self.row([bitrateTitle, Self.spacer(), bitrateField])
        bitrateRow.orientation = .horizontal
        bitrateRow.alignment = .centerY
        bitrateError.preferredMaxLayoutWidth = Self.contentWidth

        let audio: [ExportAudioMode] = [.keep, .mute]
        audioRow = InlineSegmentRow(title: L("Audio"), labels: [L("Keep"), L("Mute")]) { [model] i in
            model.updateAdjust { $0.audio = audio[i] }
        }
        let captions: [ExportCaptionsMode] = [.burned, .soft, .off]
        captionsRow = InlineSegmentRow(title: L("Captions"), labels: [L("Burned in"), L("Soft"), L("Off")]) { [model] i in
            model.updateAdjust { $0.captions = captions[i] }
        }

        resetButton.title = L("Reset")
        Self.styleLink(resetButton)
        resetButton.target = self
        resetButton.action = #selector(resetAdjust)
        savePresetButton.title = L("Save as Preset…")
        Self.styleLink(savePresetButton)
        savePresetButton.target = self
        savePresetButton.action = #selector(savePreset)
        let footer = Self.row([resetButton, Self.spacer(), savePresetButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let rows: [NSView] = [formatRow, sizeRow, fpsRow, qualityRow, bitrateRow, bitrateError, audioRow, captionsRow, footer]
        for row in rows {
            adjustStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: adjustStack.widthAnchor).isActive = true
        }
    }

    /// Adds a full-width row to the root stack.
    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: Refresh

    /// Re-reads the model and the queue and updates every row. Resizes the
    /// popover when the visible rows changed its height.
    func refresh(resize: Bool = true) {
        rebuildPresetRowsIfNeeded()
        let preset = model.selectedPreset
        for (index, button) in presetButtons().enumerated() { button.state = model.presets[index].id == preset.id ? .on : .off }

        summaryLabel.stringValue = model.summaryText
        destinationLabel.stringValue = model.destinationText
        let detail = model.detailText
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        setupStack.isHidden = !model.needsUploadSetup
        let setup = model.uploadSetupText
        setupLabel.stringValue = setup.message
        if setupButton.title != setup.link {
            setupButton.title = setup.link
            Self.styleLink(setupButton)
        }
        statusLine = records.flatMap { model.statusLine(records: $0, processingPercent: queue?.sync.processingPercent ?? [:]) }
        statusStack.isHidden = statusLine == nil
        if let line = statusLine {
            statusLabel.stringValue = line.text
            switch line.tone {
            case .neutral: statusLabel.textColor = VideoEditorStyle.textSecondary
            case .success: statusLabel.textColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            case .failure: statusLabel.textColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.55, alpha: 1)
            }
            dashboardButton.isHidden = line.dashboardURL == nil
            retryButton.isHidden = !line.canRetry
        }

        refreshAdjust()
        refreshProgress()

        let busy = queueState.isBusy
        exportButton.title = busy ? L("Add to Queue") : L("Export")
        exportButton.isEnabled = model.canExport
        saveAsButton.isEnabled = model.canSaveAs
        exportButton.toolTip = model.needsUploadSetup ? model.uploadSetupText.link : nil
        if resize { resizeToFit() }
    }

    private func refreshAdjust() {
        let state = model.adjust
        let modified = model.hasAdjustments
        let symbol = VideoEditorStyle.symbol(isAdjustOpen ? "chevron.down" : "chevron.right", size: 10, weight: .semibold)
        adjustButton.image = symbol
        adjustButton.contentTintColor = VideoEditorStyle.textSecondary
        let text = NSMutableAttributedString(string: " " + L("Adjust"), attributes: [
            .font: VideoEditorStyle.font(12, .semibold), .foregroundColor: VideoEditorStyle.textPrimary,
        ])
        if modified {
            text.append(NSAttributedString(string: "   " + L("Modified"), attributes: [
                .font: VideoEditorStyle.font(11, .medium), .foregroundColor: VideoEditorStyle.accentText,
            ]))
        }
        adjustButton.attributedTitle = text
        adjustStack.isHidden = !isAdjustOpen
        guard isAdjustOpen else { return }

        let formats: [ExportFormat] = [.h264, .hevc, .gif]
        formatRow.control.selectedSegment = formats.firstIndex(of: state.format) ?? 0
        let isGIF = state.format.isGIF

        fill(sizePopup, values: ExportAdjustState.longEdgeChoices, current: state.longEdgeCap,
             none: L("Source size")) { String(format: L("%d px"), $0) }
        fill(fpsPopup, values: ExportAdjustState.fpsChoices, current: state.fpsCap,
             none: isGIF ? L("Auto") : L("Source rate")) { String(format: L("%d fps"), $0) }
        let qualities: [VideoQuality] = [.high, .medium, .low]
        qualityRow.control.selectedSegment = qualities.firstIndex(of: state.quality) ?? 0
        if bitrateField.stringValue != state.bitrateText, bitrateField.currentEditor() == nil {
            bitrateField.stringValue = state.bitrateText
        }
        let error = model.bitrateError
        bitrateError.stringValue = error ?? ""
        bitrateError.isHidden = error == nil
        audioRow.control.selectedSegment = state.audio == .keep ? 0 : 1
        let captions: [ExportCaptionsMode] = [.burned, .soft, .off]
        captionsRow.control.selectedSegment = captions.firstIndex(of: state.captions) ?? 0

        // GIF has no quality tier, bitrate or audio.
        qualityRow.isHidden = isGIF
        bitrateRow.isHidden = isGIF
        if isGIF { bitrateError.isHidden = true }
        audioRow.isHidden = isGIF
        resetButton.isEnabled = modified
        resetButton.alphaValue = modified ? 1 : 0.4
    }

    private func refreshProgress() {
        let state = queueState
        busyStack.isHidden = state.current == nil
        if let current = state.current {
            let percent = Int((max(0, min(1, current.fraction)) * 100).rounded())
            if current.isCancelling {
                busyLabel.stringValue = L("Cancelling…")
            } else {
                busyLabel.stringValue = "\(current.presetName) · \(current.stage.localizedTitle) \(percent)%"
            }
            progressBar.doubleValue = current.fraction.isFinite ? max(0, min(1, current.fraction)) : 0
            cancelButton.isEnabled = !current.isCancelling
        }

        for view in queuedStack.arrangedSubviews { queuedStack.removeArrangedSubview(view); view.removeFromSuperview() }
        queuedStack.isHidden = state.waiting.isEmpty
        for (index, waiting) in state.waiting.enumerated() {
            let label = VideoEditorStyle.label(String(format: L("Queued: %@"), waiting.presetName), size: 11.5,
                                               color: VideoEditorStyle.textSecondary)
            let remove = VideoIconButton(symbol: "xmark", size: 9, tooltip: L("Remove from queue"), target: self,
                                         action: #selector(removeQueued(_:)))
            remove.tag = index
            remove.widthAnchor.constraint(equalToConstant: 22).isActive = true
            remove.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let row = Self.row([label, Self.spacer(), remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            queuedStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: queuedStack.widthAnchor).isActive = true
        }

        if state.current == nil, let result = state.lastResult, let failure = result.failure, result.presetID == model.selectedID {
            failureLabel.stringValue = String(format: L("Export failed: %@"), failure.message)
            failureLabel.isHidden = false
        } else {
            failureLabel.isHidden = true
        }
    }

    /// Popup of `Source/Auto` plus `values`, with the preset's own value added
    /// when it isn't one of the standard choices. `tag` carries the value
    /// (0 = no cap).
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

    private func rebuildPresetRowsIfNeeded() {
        let ids = model.presets.map(\.id)
        guard ids != shownPresetIDs else {
            // Shortcut text may have changed in Settings; names too.
            return
        }
        shownPresetIDs = ids
        for view in presetStack.arrangedSubviews { presetStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, preset) in model.presets.enumerated() {
            let radio = NSButton(radioButtonWithTitle: preset.name, target: self, action: #selector(presetClicked(_:)))
            radio.tag = index
            radio.attributedTitle = NSAttributedString(string: preset.name, attributes: [
                .font: VideoEditorStyle.font(12.5, .medium), .foregroundColor: VideoEditorStyle.textPrimary,
            ])
            radio.setContentHuggingPriority(.defaultLow, for: .horizontal)
            radio.focusRingType = .none
            radio.setAccessibilityLabel(preset.name)
            var views: [NSView] = [radio]
            if let shortcut = model.shortcutText(for: preset) {
                let hint = VideoEditorStyle.label(shortcut, size: 11.5, color: VideoEditorStyle.textSecondary)
                hint.font = VideoEditorStyle.mono(11.5, .regular)
                hint.setContentHuggingPriority(.required, for: .horizontal)
                hint.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(hint)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 8
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            presetStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: presetStack.widthAnchor).isActive = true
        }
    }

    private func presetButtons() -> [NSButton] {
        presetStack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSButton }
    }

    /// Asks the popover to take the height the visible rows need.
    func resizeToFit() {
        layoutSubtreeIfNeeded()
        guard window != nil else { return }
        PopoverHelper.resizeActive(to: fittingSize)
    }

    // MARK: Actions

    @objc private func presetClicked(_ sender: NSButton) {
        guard model.presets.indices.contains(sender.tag) else { return }
        model.select(model.presets[sender.tag].id)
    }

    @objc private func toggleAdjust() {
        isAdjustOpen.toggle()
        refresh()
    }

    @objc private func sizeChanged() {
        let value = sizePopup.selectedItem?.tag ?? 0
        model.updateAdjust { $0.longEdgeCap = value > 0 ? value : nil }
    }

    @objc private func fpsChanged() {
        let value = fpsPopup.selectedItem?.tag ?? 0
        model.updateAdjust { $0.fpsCap = value > 0 ? value : nil }
    }

    @objc private func resetAdjust() { model.resetAdjust() }

    @objc private func savePreset() { handlers.savePreset(model) }

    @objc private func runExport() {
        guard model.canExport else { return }
        handlers.run(model.selectedPreset, model.overrides)
    }

    @objc private func saveAs() {
        guard model.canSaveAs else { return }
        handlers.saveAs(model.selectedPreset, model.overrides)
    }

    @objc private func cancelCurrent() { handlers.cancelCurrent() }

    @objc private func removeQueued(_ sender: NSButton) {
        guard queueState.waiting.indices.contains(sender.tag) else { return }
        handlers.cancelQueued(queueState.waiting[sender.tag].id)
    }

    @objc private func openDashboard() {
        if let url = statusLine?.dashboardURL { handlers.open(url) }
    }

    @objc private func retry() { handlers.run(model.selectedPreset, model.overrides) }
    @objc private func openCloudflareSettings() { handlers.openCloudflareSettings() }
    @objc private func openExportSettings() { handlers.openExportSettings() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === bitrateField else { return }
        model.updateAdjust { $0.bitrateText = bitrateField.stringValue }
    }

    // MARK: Helpers

    /// Probe/test access: the view's control with this accessibility label.
    var exportActionButton: NSButton { exportButton }
    var saveAsActionButton: NSButton { saveAsButton }
    var adjustToggleButton: NSButton { adjustButton }
    var isAdjustExpanded: Bool { isAdjustOpen }
    var cancelActionButton: NSButton { cancelButton }

    private static func wrapping(_ text: String, size: CGFloat, color: NSColor = VideoEditorStyle.textPrimary) -> NSTextField {
        let label = VideoEditorStyle.label(text, size: size, color: color)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.preferredMaxLayoutWidth = contentWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func linkButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        styleLink(button)
        return button
    }

    private static func styleLink(_ button: NSButton) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: VideoEditorStyle.font(11.5, .medium), .foregroundColor: VideoEditorStyle.accentText,
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A flexible gap for horizontal rows.
    private static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return view
    }

    /// A horizontal row whose spacer stretches.
    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    /// Title on the left, a control on the right.
    private static func titled(_ title: String, _ control: NSView) -> NSStackView {
        let label = VideoEditorStyle.label(title, size: 12)
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = Self.row([label, Self.spacer(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }
}

/// "Title  [ segment | segment | segment ]" on one line.
private final class InlineSegmentRow: NSStackView {
    let control: NSSegmentedControl
    private let onSelect: (Int) -> Void

    init(title: String, labels: [String], onSelect: @escaping (Int) -> Void) {
        control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        self.onSelect = onSelect
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 8
        let label = VideoEditorStyle.label(title, size: 12)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        control.selectedSegment = 0
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(title)
        control.target = self
        control.action = #selector(changed)
        addArrangedSubview(label)
        addArrangedSubview(control)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onSelect(control.selectedSegment) }
}
