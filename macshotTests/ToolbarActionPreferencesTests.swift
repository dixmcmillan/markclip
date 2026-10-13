import XCTest

/// Phase 7 removed the toolbar Upload action (raw value 1001). Stored
/// `enabledActions` / `knownActionTags` arrays are plain `[Int]`, so a retired
/// value can still be sitting in a user's defaults (or an imported settings
/// file) and must be ignored rather than crash or resurrect a button.
final class ToolbarActionPreferencesTests: XCTestCase {
    func testRetiredUploadRawValueIsNotAKnownAction() {
        XCTAssertNil(ToolbarCustomAction(rawValue: 1001))
        XCTAssertFalse(ToolbarActionPreferences.allKnownRawValues.contains(1001))
    }

    func testStoredRetiredValueIsIgnoredAndOtherActionsStillResolve() {
        let stored = [1001, ToolbarCustomAction.pin.rawValue]
        XCTAssertTrue(ToolbarActionPreferences.isEnabled(.pin, in: stored))
        XCTAssertFalse(ToolbarActionPreferences.isEnabled(.ocr, in: stored))
    }

    func testMigrationWithStoredRetiredValueDoesNotCrashAndKeepsUserChoices() {
        withDefaults([
            ToolbarActionPreferences.enabledDefaultsKey: [1001, ToolbarCustomAction.pin.rawValue],
            ToolbarActionPreferences.knownDefaultsKey: [1001, ToolbarCustomAction.pin.rawValue],
        ]) {
            let enabled = ToolbarActionPreferences.enabledRawValuesAfterMigration() ?? []
            XCTAssertTrue(enabled.contains(ToolbarCustomAction.pin.rawValue))
            for action in ToolbarCustomAction.rightToolbarActions {
                _ = action.makeToolbarButton()
            }
        }
    }

    func testToolShortcutActionNoLongerIncludesUpload() {
        XCTAssertNil(ToolShortcutManager.Action(rawValue: "upload"))
        withDefaults(["overlayToolShortcuts": ["upload": "u", "pencil": "p"]]) {
            XCTAssertEqual(ToolShortcutManager.key(for: .pencil), "p")
            XCTAssertNil(ToolShortcutManager.lookupAction(for: "u"), "the retired Upload shortcut no longer maps anywhere")
        }
    }
}
