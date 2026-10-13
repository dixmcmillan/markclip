import Cocoa

/// Per-preset export shortcuts, keyed by preset id (an `EditorCommandShortcutManager`
/// `Action` is a fixed enum, so presets the user adds can't live there).
///
/// Editor-scoped: matched from `VideoEditorWindowController.handleKeyEquivalent`
/// and shown on File ▸ Export Preset. Never registered globally.
///
/// Storage is one JSON dictionary under `exportPresetShortcuts.v1`:
///
/// - no entry: the built-in default (⌃⌘1/2/3 for Archive/Stream/Loop, nothing
///   for custom presets);
/// - an entry with a shortcut: the user's chord;
/// - an entry marked `disabled`: the user cleared it, so the default does not
///   come back until Reset.
///
/// Entries decode one by one, so a corrupt value costs that preset's custom
/// chord, not the whole table.
enum ExportPresetShortcutStore {
    typealias Shortcut = EditorCommandShortcutManager.Shortcut

    static let defaultsKey = "exportPresetShortcuts.v1"

    // MARK: Defaults

    /// ⌃⌘1–⌃⌘3 by built-in order. Custom presets have none.
    static func defaultShortcut(for presetID: UUID) -> Shortcut? {
        let builtIns = [ExportPresetStore.archiveID, ExportPresetStore.streamID, ExportPresetStore.loopID]
        guard let index = builtIns.firstIndex(of: presetID) else { return nil }
        return Shortcut(character: String(index + 1), modifiers: [.control, .command])
    }

    // MARK: Stored entries

    private struct Entry: Codable, Equatable {
        var shortcut: Shortcut?
        var disabled: Bool

        init(shortcut: Shortcut?, disabled: Bool) {
            self.shortcut = shortcut
            self.disabled = disabled
        }

        private enum CodingKeys: String, CodingKey { case shortcut, disabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shortcut = try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)
            disabled = (try? c.decodeIfPresent(Bool.self, forKey: .disabled)) ?? false
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Table: Codable {
        var entries: [String: Entry] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            for key in container.allKeys {
                if let entry = try? container.decode(Entry.self, forKey: key) { entries[key.stringValue] = entry }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, entry) in entries {
                try container.encode(entry, forKey: AnyKey(stringValue: key)!)
            }
        }
    }

    private static func load(_ defaults: UserDefaults) -> Table {
        guard let data = defaults.data(forKey: defaultsKey),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return Table() }
        return table
    }

    private static func store(_ table: Table, _ defaults: UserDefaults) {
        if table.entries.isEmpty { defaults.removeObject(forKey: defaultsKey); return }
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    // MARK: Reading

    /// The chord that runs `presetID`, or nil when it has none.
    static func shortcut(for presetID: UUID, defaults: UserDefaults = .standard) -> Shortcut? {
        if let entry = load(defaults).entries[presetID.uuidString] {
            return entry.disabled ? nil : (entry.shortcut ?? defaultShortcut(for: presetID))
        }
        return defaultShortcut(for: presetID)
    }

    /// True while the preset uses its built-in chord (or has none by default).
    static func isDefault(for presetID: UUID, defaults: UserDefaults = .standard) -> Bool {
        load(defaults).entries[presetID.uuidString] == nil
    }

    /// Every preset's effective chord, in `presets` order. A chord that two
    /// presets would share goes to the earlier one only; the later one reads
    /// as unassigned, so lookups are never ambiguous.
    static func assignments(for presets: [ExportPreset], defaults: UserDefaults = .standard) -> [(preset: ExportPreset, shortcut: Shortcut?)] {
        var taken: [Shortcut] = []
        return presets.map { preset in
            guard let shortcut = shortcut(for: preset.id, defaults: defaults), !taken.contains(shortcut) else {
                return (preset, nil)
            }
            taken.append(shortcut)
            return (preset, shortcut)
        }
    }

    /// The preset an editor key event runs, if any. Matches through
    /// `KeyboardShortcutMatcher` (layout-aware), never raw key codes.
    static func preset(for event: NSEvent, among presets: [ExportPreset], defaults: UserDefaults = .standard) -> ExportPreset? {
        for (preset, shortcut) in assignments(for: presets, defaults: defaults) {
            guard let shortcut else { continue }
            if KeyboardShortcutMatcher.matches(event, character: shortcut.character, modifiers: shortcut.modifiers) {
                return preset
            }
        }
        return nil
    }

    // MARK: Writing

    /// Sets `presetID`'s chord. A chord belongs to one preset: any other
    /// preset that held it (by default or by choice) is cleared.
    static func set(_ shortcut: Shortcut, for presetID: UUID, among presets: [ExportPreset], defaults: UserDefaults = .standard) {
        var table = load(defaults)
        for other in presets where other.id != presetID && self.shortcut(for: other.id, defaults: defaults) == shortcut {
            table.entries[other.id.uuidString] = Entry(shortcut: nil, disabled: true)
        }
        table.entries[presetID.uuidString] = Entry(shortcut: shortcut, disabled: false)
        store(table, defaults)
    }

    /// No shortcut for `presetID`, and the default stays off until `reset`.
    static func disable(_ presetID: UUID, defaults: UserDefaults = .standard) {
        var table = load(defaults)
        table.entries[presetID.uuidString] = Entry(shortcut: nil, disabled: true)
        store(table, defaults)
    }

    /// Back to the built-in default (none for custom presets).
    static func reset(_ presetID: UUID, defaults: UserDefaults = .standard) {
        var table = load(defaults)
        table.entries.removeValue(forKey: presetID.uuidString)
        store(table, defaults)
    }

    /// Forgets a deleted preset's entry.
    static func remove(_ presetID: UUID, defaults: UserDefaults = .standard) {
        reset(presetID, defaults: defaults)
    }

    // MARK: Conflicts

    /// Chords the editor already owns, which a preset must not take:
    /// ⌘S/⇧⌘S (save), ⌘E/⇧⌘E (export), ⌘C and the configurable Undo/Redo chords.
    static func reservedShortcuts() -> [Shortcut] {
        var reserved = [
            Shortcut(character: "s", modifiers: [.command]),
            Shortcut(character: "s", modifiers: [.command, .shift]),
            Shortcut(character: "e", modifiers: [.command]),
            Shortcut(character: "e", modifiers: [.command, .shift]),
            Shortcut(character: "c", modifiers: [.command]),
        ]
        for action in EditorCommandShortcutManager.Action.allCases {
            reserved += EditorCommandShortcutManager.shortcuts(for: action)
        }
        return reserved
    }

    /// Whether `shortcut` may be assigned: it needs ⌘ or ⌃ (a bare letter would
    /// fight text entry and the single-key tools) and must not be reserved.
    static func validate(_ shortcut: Shortcut, reserved: [Shortcut] = reservedShortcuts()) -> ValidationResult {
        let modifiers = shortcut.modifiers
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return .needsModifier }
        guard !shortcut.character.isEmpty else { return .needsModifier }
        if reserved.contains(shortcut) { return .reserved }
        return .ok
    }

    enum ValidationResult: Equatable {
        case ok
        /// Needs ⌘ or ⌃.
        case needsModifier
        /// Already used by an editor command.
        case reserved

        var message: String? {
            switch self {
            case .ok: return nil
            case .needsModifier: return L("Use ⌘ or ⌃ in the shortcut.")
            case .reserved: return L("That shortcut is used by another editor command.")
            }
        }
    }

    /// The preset (other than `presetID`) that currently holds `shortcut`, so
    /// the recorder can say what it is about to take the chord from.
    static func conflictingPreset(for shortcut: Shortcut, excluding presetID: UUID, among presets: [ExportPreset],
                                  defaults: UserDefaults = .standard) -> ExportPreset? {
        assignments(for: presets, defaults: defaults).first { $0.preset.id != presetID && $0.shortcut == shortcut }?.preset
    }

    // MARK: Display

    /// `⌃⌘1`. Control, option, shift, command order, as in menus.
    static func displayString(for shortcut: Shortcut) -> String {
        var result = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + shortcut.character.uppercased()
    }

    static func displayString(for presetID: UUID, defaults: UserDefaults = .standard) -> String? {
        shortcut(for: presetID, defaults: defaults).map(displayString(for:))
    }

    /// Menu key equivalent for `shortcut`.
    static func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        guard let shortcut else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.character
        item.keyEquivalentModifierMask = shortcut.modifiers
    }
}

extension Notification.Name {
    /// Posted when presets or their shortcuts change (Settings ▸ Export, Save
    /// as Preset…), so the File ▸ Export Preset menu rebuilds.
    static let exportPresetsChanged = Notification.Name("macshot.exportPresetsChanged")
}
