import XCTest

/// Per-preset export shortcuts: defaults, custom chords, conflicts, lenient
/// decoding and character-based key matching (never raw key codes).
final class ExportPresetShortcutStoreTests: XCTestCase {
    private typealias Store = ExportPresetShortcutStore
    private typealias Shortcut = EditorCommandShortcutManager.Shortcut
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "export-shortcuts-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private let control: NSEvent.ModifierFlags = [.control, .command]
    private func presets(extra: [ExportPreset] = []) -> [ExportPreset] { ExportPresetStore.builtIns() + extra }
    private func event(_ character: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        TestKeyEvent.keyDown(characters: character, keyCode: code, modifiers: modifiers)
    }

    // MARK: Defaults

    func testBuiltInsDefaultToControlCommandOneToThree() {
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.archiveID, defaults: defaults), Shortcut(character: "1", modifiers: control))
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.streamID, defaults: defaults), Shortcut(character: "2", modifiers: control))
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.loopID, defaults: defaults), Shortcut(character: "3", modifiers: control))
        XCTAssertEqual(Store.displayString(for: ExportPresetStore.streamID, defaults: defaults), "⌃⌘2")
    }

    func testCustomPresetsHaveNoDefault() {
        XCTAssertNil(Store.shortcut(for: UUID(), defaults: defaults))
    }

    func testNothingIsStoredUntilSomethingChanges() {
        _ = Store.shortcut(for: ExportPresetStore.archiveID, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: Store.defaultsKey))
        XCTAssertTrue(Store.isDefault(for: ExportPresetStore.archiveID, defaults: defaults))
    }

    // MARK: Matching

    func testControlCommandDigitsRunTheBuiltIns() {
        let all = presets()
        XCTAssertEqual(Store.preset(for: event("1", code: TestKeyEvent.Code.one, control), among: all, defaults: defaults)?.id,
                       ExportPresetStore.archiveID)
        XCTAssertEqual(Store.preset(for: event("2", code: 19, control), among: all, defaults: defaults)?.id, ExportPresetStore.streamID)
        XCTAssertEqual(Store.preset(for: event("3", code: 20, control), among: all, defaults: defaults)?.id, ExportPresetStore.loopID)
    }

    func testOtherModifierCombinationsDoNotMatch() {
        let all = presets()
        XCTAssertNil(Store.preset(for: event("1", code: 18, [.command]), among: all, defaults: defaults))
        XCTAssertNil(Store.preset(for: event("1", code: 18, [.control]), among: all, defaults: defaults))
        XCTAssertNil(Store.preset(for: event("1", code: 18, [.control, .command, .shift]), among: all, defaults: defaults))
        XCTAssertNil(Store.preset(for: event("4", code: 21, control), among: all, defaults: defaults))
    }

    func testMatchingFollowsTheCharacterNotTheKeyCode() {
        // A layout where the "2" character sits on another physical key.
        XCTAssertEqual(Store.preset(for: event("2", code: 33, control), among: presets(), defaults: defaults)?.id,
                       ExportPresetStore.streamID)
    }

    func testPresetsNotInTheListAreNotMatched() {
        let visibleOnly = presets().filter { $0.id != ExportPresetStore.streamID }
        XCTAssertNil(Store.preset(for: event("2", code: 19, control), among: visibleOnly, defaults: defaults))
    }

    // MARK: Custom chords

    func testCustomChordRunsACustomPreset() {
        let custom = ExportPreset(name: "Review")
        let all = presets(extra: [custom])
        Store.set(Shortcut(character: "9", modifiers: control), for: custom.id, among: all, defaults: defaults)
        XCTAssertEqual(Store.preset(for: event("9", code: 25, control), among: all, defaults: defaults)?.id, custom.id)
        XCTAssertFalse(Store.isDefault(for: custom.id, defaults: defaults))
    }

    func testChoosingATakenChordMovesItAndLeavesTheOldOwnerUnassigned() {
        let custom = ExportPreset(name: "Review")
        let all = presets(extra: [custom])
        let archiveChord = Shortcut(character: "1", modifiers: control)
        XCTAssertEqual(Store.conflictingPreset(for: archiveChord, excluding: custom.id, among: all, defaults: defaults)?.id,
                       ExportPresetStore.archiveID)
        Store.set(archiveChord, for: custom.id, among: all, defaults: defaults)
        XCTAssertNil(Store.shortcut(for: ExportPresetStore.archiveID, defaults: defaults))
        XCTAssertEqual(Store.shortcut(for: custom.id, defaults: defaults), archiveChord)
        XCTAssertEqual(Store.preset(for: event("1", code: 18, control), among: all, defaults: defaults)?.id, custom.id)
    }

    func testDisablingKeepsADefaultOffUntilReset() {
        Store.disable(ExportPresetStore.loopID, defaults: defaults)
        XCTAssertNil(Store.shortcut(for: ExportPresetStore.loopID, defaults: defaults))
        XCTAssertNil(Store.preset(for: event("3", code: 20, control), among: presets(), defaults: defaults))
        Store.reset(ExportPresetStore.loopID, defaults: defaults)
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.loopID, defaults: defaults), Shortcut(character: "3", modifiers: control))
        XCTAssertNil(defaults.data(forKey: Store.defaultsKey), "a fully default table isn't stored")
    }

    func testSharedChordInStoredDataGoesToTheEarlierPresetOnly() throws {
        let custom = ExportPreset(name: "Dup")
        // Hand-written table: custom also claims ⌃⌘1.
        let chord = Shortcut(character: "1", modifiers: control)
        let entry = ["shortcut": try JSONSerialization.jsonObject(with: JSONEncoder().encode(chord)), "disabled": false] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: [custom.id.uuidString: entry])
        defaults.set(data, forKey: Store.defaultsKey)
        let all = presets(extra: [custom])
        let assignments = Store.assignments(for: all, defaults: defaults)
        XCTAssertEqual(assignments.first { $0.preset.id == ExportPresetStore.archiveID }?.shortcut, chord)
        XCTAssertNil(assignments.first { $0.preset.id == custom.id }?.shortcut)
        XCTAssertEqual(Store.preset(for: event("1", code: 18, control), among: all, defaults: defaults)?.id, ExportPresetStore.archiveID)
    }

    func testRemoveForgetsAPresetsEntry() {
        let custom = ExportPreset(name: "Gone")
        Store.set(Shortcut(character: "8", modifiers: control), for: custom.id, among: presets(extra: [custom]), defaults: defaults)
        Store.remove(custom.id, defaults: defaults)
        XCTAssertNil(Store.shortcut(for: custom.id, defaults: defaults))
    }

    // MARK: Lenient decoding

    func testGarbageStorageFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: Store.defaultsKey)
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.archiveID, defaults: defaults), Shortcut(character: "1", modifiers: control))
        defaults.set("a string", forKey: Store.defaultsKey)
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.streamID, defaults: defaults), Shortcut(character: "2", modifiers: control))
    }

    func testOneCorruptEntryCostsOnlyThatPreset() throws {
        let custom = ExportPreset(name: "Keep")
        let good = ["shortcut": ["character": "7", "modifiersRawValue": control.rawValue], "disabled": false] as [String: Any]
        let table: [String: Any] = [
            custom.id.uuidString: good,
            ExportPresetStore.archiveID.uuidString: ["shortcut": 12, "disabled": "maybe"],
            ExportPresetStore.streamID.uuidString: "nonsense",
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: table), forKey: Store.defaultsKey)
        XCTAssertEqual(Store.shortcut(for: custom.id, defaults: defaults), Shortcut(character: "7", modifiers: control))
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.archiveID, defaults: defaults), Shortcut(character: "1", modifiers: control),
                       "an unreadable entry falls back to the default")
        XCTAssertEqual(Store.shortcut(for: ExportPresetStore.streamID, defaults: defaults), Shortcut(character: "2", modifiers: control))
    }

    // MARK: Validation, display, menus

    func testValidationNeedsCommandOrControlAndAvoidsEditorCommands() {
        XCTAssertEqual(Store.validate(Shortcut(character: "1", modifiers: control)), .ok)
        XCTAssertEqual(Store.validate(Shortcut(character: "1", modifiers: [.control])), .ok)
        XCTAssertEqual(Store.validate(Shortcut(character: "1", modifiers: [.command, .shift])), .ok)
        XCTAssertEqual(Store.validate(Shortcut(character: "1", modifiers: [])), .needsModifier)
        XCTAssertEqual(Store.validate(Shortcut(character: "1", modifiers: [.option, .shift])), .needsModifier)
        XCTAssertEqual(Store.validate(Shortcut(character: "e", modifiers: [.command])), .reserved)
        XCTAssertEqual(Store.validate(Shortcut(character: "s", modifiers: [.command, .shift])), .reserved)
        XCTAssertEqual(Store.validate(Shortcut(character: "z", modifiers: [.command])), .reserved)
        XCTAssertNotNil(Store.ValidationResult.needsModifier.message)
        XCTAssertNil(Store.ValidationResult.ok.message)
    }

    func testDisplayOrdersModifiersLikeMenus() {
        XCTAssertEqual(Store.displayString(for: Shortcut(character: "k", modifiers: [.command, .shift, .option, .control])), "⌃⌥⇧⌘K")
    }

    func testMenuItemGetsTheKeyEquivalent() {
        let item = NSMenuItem(title: "Archive", action: nil, keyEquivalent: "")
        Store.apply(Shortcut(character: "1", modifiers: control), to: item)
        XCTAssertEqual(item.keyEquivalent, "1")
        XCTAssertEqual(item.keyEquivalentModifierMask, control)
        Store.apply(nil, to: item)
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertTrue(item.keyEquivalentModifierMask.isEmpty)
    }
}
