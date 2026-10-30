import Foundation

/// A field of `GIFFitSettings` as typed in Settings, with its bounds. Editing
/// goes through `parse`/`apply` so nothing outside the bounds is ever stored.
enum GIFFitField: CaseIterable {
    case maxMegabytes, maxMegapixels, minLongEdge, minFPS, startFPS

    var range: ClosedRange<Double> {
        switch self {
        case .maxMegabytes: return 0.5...100
        case .maxMegapixels: return 1...1000
        case .minLongEdge: return 64...4096
        case .minFPS, .startFPS: return 1...30
        }
    }

    var isWholeNumber: Bool { self != .maxMegabytes && self != .maxMegapixels }

    func text(for settings: GIFFitSettings) -> String {
        switch self {
        case .maxMegabytes: return String(format: "%g", Double(settings.maxBytes) / 1_000_000)
        case .maxMegapixels: return String(format: "%g", settings.maxTotalMegapixels)
        case .minLongEdge: return String(settings.minLongEdge)
        case .minFPS: return String(settings.minFPS)
        case .startFPS: return String(settings.startFPS)
        }
    }

    /// The error for `text`, or nil when it can be applied to `settings`.
    func error(for text: String, in settings: GIFFitSettings) -> String? {
        guard let value = parsedValue(text) else { return rangeMessage }
        var copy = settings
        apply(value, to: &copy)
        // The start rate can't be below the floor it counts down to.
        if copy.startFPS < copy.minFPS { return L("The starting frame rate must be at least the lowest frame rate.") }
        return nil
    }

    /// Applies a valid `text`; returns false (leaving `settings` alone) when it isn't.
    @discardableResult
    func apply(_ text: String, to settings: inout GIFFitSettings) -> Bool {
        guard error(for: text, in: settings) == nil, let value = parsedValue(text) else { return false }
        apply(value, to: &settings)
        return true
    }

    private func parsedValue(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, range.contains(value) else { return nil }
        if isWholeNumber, value != value.rounded() { return nil }
        return value
    }

    private func apply(_ value: Double, to settings: inout GIFFitSettings) {
        switch self {
        case .maxMegabytes: settings.maxBytes = Int((value * 1_000_000).rounded())
        case .maxMegapixels: settings.maxTotalMegapixels = value
        case .minLongEdge: settings.minLongEdge = Int(value)
        case .minFPS: settings.minFPS = Int(value)
        case .startFPS: settings.startFPS = Int(value)
        }
    }

    private var rangeMessage: String {
        let low = isWholeNumber ? String(Int(range.lowerBound)) : String(format: "%g", range.lowerBound)
        let high = isWholeNumber ? String(Int(range.upperBound)) : String(format: "%g", range.upperBound)
        return String(format: L("Enter a number from %@ to %@."), low, high)
    }
}

/// Editing state behind Settings ▸ Export: the preset list and every field of
/// the selected preset, each edit persisted at once through `ExportPresetStore`.
/// Free of AppKit so the editing rules are unit-tested directly.
@MainActor
final class ExportSettingsModel {
    enum DestinationKind: Equatable { case folder, stream, images, trainWithDixon }

    private let defaults: UserDefaults
    private let offline: Bool
    private(set) var presets: [ExportPreset] = []
    private(set) var selectedID: UUID?
    /// Fires after any change to the list, the selection or a preset.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, offline: Bool = BuildVariant.isOffline) {
        self.defaults = defaults
        self.offline = offline
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        selectedID = presets.first?.id
    }

    var selected: ExportPreset? { presets.first { $0.id == selectedID } }

    /// Destinations this build offers (folders only under OFFLINE).
    var availableDestinations: [DestinationKind] { offline ? [.folder] : [.folder, .stream, .images, .trainWithDixon] }

    func reload() {
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        if !presets.contains(where: { $0.id == selectedID }) { selectedID = presets.first?.id }
        onChange?()
    }

    func select(_ id: UUID?) {
        guard id == nil || presets.contains(where: { $0.id == id }) else { return }
        guard id != selectedID else { return }
        selectedID = id
        onChange?()
    }

    // MARK: List

    /// A new custom H.264 folder preset, selected.
    @discardableResult
    func addPreset() -> ExportPreset {
        let name = ExportPresetNaming.uniqueName(L("New Preset"), among: ExportPresetStore.allPresets(defaults: defaults))
        let preset = ExportPreset(name: name, format: .h264, quality: .high, destination: .defaultFolder)
        return insert(preset)
    }

    @discardableResult
    func duplicate(_ id: UUID) -> ExportPreset? {
        guard var copy = presets.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = ExportPresetNaming.uniqueName(String(format: L("%@ copy"), copy.name),
                                                  among: ExportPresetStore.allPresets(defaults: defaults))
        return insert(copy)
    }

    /// Deletes a custom preset (built-ins can't be) along with its shortcut,
    /// and selects its neighbor.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }), !presets[index].isBuiltIn else { return false }
        ExportPresetStore.delete(id: id, defaults: defaults)
        ExportPresetShortcutStore.remove(id, defaults: defaults)
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        if selectedID == id { selectedID = presets.indices.contains(index) ? presets[index].id : presets.last?.id }
        onChange?()
        return true
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onChange?(); return }
        let unique = ExportPresetNaming.uniqueName(trimmed, among: ExportPresetStore.allPresets(defaults: defaults), excluding: id)
        update(id) { $0.name = unique }
    }

    private func insert(_ preset: ExportPreset) -> ExportPreset {
        ExportPresetStore.addOrReplace(preset, defaults: defaults)
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        selectedID = preset.id
        onChange?()
        return preset
    }

    // MARK: Editing

    /// Applies `body` to the preset and saves it.
    func update(_ id: UUID, _ body: (inout ExportPreset) -> Void) {
        guard var preset = ExportPresetStore.preset(id: id, defaults: defaults) else { return }
        body(&preset)
        ExportPresetStore.addOrReplace(preset, defaults: defaults)
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        onChange?()
    }

    /// Changing the format keeps the destination coherent: Images only takes
    /// GIFs, Stream and TrainWithDixon only take video.
    func setFormat(_ id: UUID, _ format: ExportFormat) {
        update(id) { preset in
            preset.format = format
            if format.isGIF {
                if preset.destination == .stream || preset.destination == .trainWithDixon { preset.destination = .images }
                preset.audio = .mute
            } else if preset.destination == .images {
                preset.destination = .stream
            }
        }
    }

    func setDestination(_ id: UUID, _ kind: DestinationKind, folder: URL? = nil) {
        guard availableDestinations.contains(kind) else { return }
        update(id) { preset in
            switch kind {
            case .folder:
                if case .folder = preset.destination { return }
                preset.destination = .defaultFolder
                preset.alsoSaveLocally = false
            case .stream:
                preset.destination = .stream
                if preset.format.isGIF { preset.format = .h264; preset.audio = .keep }
            case .images:
                preset.destination = .images
                if !preset.format.isGIF { preset.format = .gif; preset.audio = .mute }
            case .trainWithDixon:
                preset.destination = .trainWithDixon
                if preset.format.isGIF { preset.format = .h264; preset.audio = .keep }
            }
        }
    }

    /// Points a folder preset at `url`, keeping a bookmark when one can be made.
    func setFolder(_ id: UUID, to url: URL) {
        update(id) { $0.destination = .folder(url: url) }
    }

    /// The result of typing a bitrate (megabits per second).
    @discardableResult
    func setBitrate(_ id: UUID, text: String) -> ExportBitrateInput.Result {
        let result = ExportBitrateInput.parse(text)
        switch result {
        case .none: update(id) { $0.explicitBitrate = nil }
        case .bitsPerSecond(let bits): update(id) { $0.explicitBitrate = bits }
        case .invalid: break
        }
        return result
    }

    /// Returns the error for `text`, or nil when it was applied.
    func setGIFFit(_ id: UUID, field: GIFFitField, text: String) -> String? {
        guard let preset = ExportPresetStore.preset(id: id, defaults: defaults) else { return nil }
        if let error = field.error(for: text, in: preset.gifFit) { return error }
        update(id) { field.apply(text, to: &$0.gifFit) }
        return nil
    }

    /// A warning when the format and destination can't work together (a
    /// preset imported or edited by hand), else nil.
    func compatibilityNote(for preset: ExportPreset) -> String? {
        switch preset.destination {
        case .stream where preset.format.isGIF, .trainWithDixon where preset.format.isGIF:
            return L("Stream takes video. Use H.264 or HEVC.")
        case .images where !preset.format.isGIF: return L("Images takes GIFs. Use the GIF format.")
        default: return nil
        }
    }

    // MARK: Shortcuts

    enum ShortcutOutcome: Equatable {
        /// Assigned; `tookFrom` names the preset that lost the same chord.
        case assigned(tookFrom: String?)
        case rejected(String)
    }

    func shortcutText(for id: UUID) -> String? {
        ExportPresetShortcutStore.displayString(for: id, defaults: defaults)
    }

    func assignShortcut(_ shortcut: EditorCommandShortcutManager.Shortcut, to id: UUID) -> ShortcutOutcome {
        if let message = ExportPresetShortcutStore.validate(shortcut).message { return .rejected(message) }
        let all = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        let previous = ExportPresetShortcutStore.conflictingPreset(for: shortcut, excluding: id, among: all, defaults: defaults)
        ExportPresetShortcutStore.set(shortcut, for: id, among: all, defaults: defaults)
        onChange?()
        return .assigned(tookFrom: previous?.name)
    }

    func clearShortcut(_ id: UUID) {
        ExportPresetShortcutStore.disable(id, defaults: defaults)
        onChange?()
    }

    func resetShortcut(_ id: UUID) {
        ExportPresetShortcutStore.reset(id, defaults: defaults)
        onChange?()
    }
}
