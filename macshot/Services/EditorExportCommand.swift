import Cocoa

/// The video editor's fixed export chords, matched through
/// `KeyboardShortcutMatcher` so they follow the user's layout.
///
/// - ⌘S and ⇧⌘E run the last-used preset, exactly like the top bar's main Export segment.
/// - ⇧⌘S is Save As… (asks where, for the last-used or open-popover preset).
/// - ⌘E opens the export popover.
///
/// `ExportPresetShortcutStore.reservedShortcuts()` is derived from `allShortcuts`,
/// so the preset shortcut recorder can never take one of these chords.
enum EditorExportCommand: CaseIterable {
    case runLastPreset
    case saveAs
    case showPopover

    typealias Shortcut = EditorCommandShortcutManager.Shortcut

    var shortcuts: [Shortcut] {
        switch self {
        case .runLastPreset:
            return [Shortcut(character: "s", modifiers: [.command]),
                    Shortcut(character: "e", modifiers: [.command, .shift])]
        case .saveAs:
            return [Shortcut(character: "s", modifiers: [.command, .shift])]
        case .showPopover:
            return [Shortcut(character: "e", modifiers: [.command])]
        }
    }

    /// Every chord the commands own.
    static var allShortcuts: [Shortcut] { allCases.flatMap(\.shortcuts) }

    /// The command a key event triggers, if any.
    static func command(for event: NSEvent) -> EditorExportCommand? {
        allCases.first { command in
            command.shortcuts.contains {
                KeyboardShortcutMatcher.matches(event, character: $0.character, modifiers: $0.modifiers)
            }
        }
    }
}
