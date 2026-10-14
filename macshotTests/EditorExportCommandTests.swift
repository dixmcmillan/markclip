import XCTest

/// The video editor's fixed export chords: ⌘S runs the last preset, ⇧⌘S is
/// Save As…, ⌘E opens the popover, ⇧⌘E repeats the last preset.
final class EditorExportCommandTests: XCTestCase {

    private typealias Command = EditorExportCommand

    private func event(_ character: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        TestKeyEvent.keyDown(characters: character, keyCode: code, modifiers: modifiers)
    }

    func testCommandSRunsTheLastPreset() {
        XCTAssertEqual(Command.command(for: event("s", TestKeyEvent.Code.s, [.command])), .runLastPreset)
    }

    func testShiftCommandEAlsoRunsTheLastPreset() {
        XCTAssertEqual(Command.command(for: event("e", TestKeyEvent.Code.e, [.command, .shift])), .runLastPreset)
    }

    func testShiftCommandSIsSaveAs() {
        XCTAssertEqual(Command.command(for: event("s", TestKeyEvent.Code.s, [.command, .shift])), .saveAs)
    }

    func testCommandEOpensThePopover() {
        XCTAssertEqual(Command.command(for: event("e", TestKeyEvent.Code.e, [.command])), .showPopover)
    }

    func testMatchingFollowsTheCharacterNotTheKeyCode() {
        // Dvorak: the physical S key (code 1) types "o"; the "s" character lives elsewhere.
        XCTAssertNil(Command.command(for: event("o", TestKeyEvent.Code.s, [.command])))
        XCTAssertEqual(Command.command(for: event("s", 41, [.command])), .runLastPreset)
        XCTAssertEqual(Command.command(for: event("s", 41, [.command, .shift])), .saveAs)
    }

    func testOtherModifierCombinationsDoNothing() {
        XCTAssertNil(Command.command(for: event("s", TestKeyEvent.Code.s, [])))
        XCTAssertNil(Command.command(for: event("s", TestKeyEvent.Code.s, [.shift])))
        XCTAssertNil(Command.command(for: event("s", TestKeyEvent.Code.s, [.command, .option])))
        XCTAssertNil(Command.command(for: event("s", TestKeyEvent.Code.s, [.control, .command])))
        XCTAssertNil(Command.command(for: event("e", TestKeyEvent.Code.e, [.control, .command])))
        XCTAssertNil(Command.command(for: event("a", TestKeyEvent.Code.a, [.command])))
    }

    func testExportChordsAreReservedFromThePresetRecorder() {
        typealias Store = ExportPresetShortcutStore
        for shortcut in Command.allShortcuts {
            XCTAssertEqual(Store.validate(shortcut), .reserved, Store.displayString(for: shortcut))
        }
        XCTAssertEqual(Set(Command.allShortcuts.map(Store.displayString(for:))), ["⌘S", "⇧⌘S", "⌘E", "⇧⌘E"])
        XCTAssertTrue(Store.reservedShortcuts().contains(Store.Shortcut(character: "c", modifiers: [.command])))
        // The default preset chords stay free.
        XCTAssertEqual(Store.validate(Store.Shortcut(character: "1", modifiers: [.control, .command])), .ok)
    }
}
