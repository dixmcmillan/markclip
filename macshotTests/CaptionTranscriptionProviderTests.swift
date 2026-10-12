import XCTest

/// Provider selection: `CaptionTranscriptionProviderKind.current()` reads
/// the configured value from `UserDefaults`, falling back to
/// `systemDefault` when unset or when the stored value isn't offered in
/// this build (e.g. an old/garbage value, or a build without the
/// OpenAI-compatible provider).
final class CaptionTranscriptionProviderTests: XCTestCase {

    func testCurrentFallsBackToSystemDefaultWhenUnset() {
        withDefaults([CaptionTranscriptionProviderKind.defaultsKey: nil]) {
            XCTAssertEqual(CaptionTranscriptionProviderKind.current(), CaptionTranscriptionProviderKind.systemDefault)
        }
    }

    func testCurrentFallsBackOnGarbageValue() {
        withDefaults([CaptionTranscriptionProviderKind.defaultsKey: "not-a-real-provider"]) {
            XCTAssertEqual(CaptionTranscriptionProviderKind.current(), CaptionTranscriptionProviderKind.systemDefault)
        }
    }

    func testCurrentHonorsAnOfferedStoredValue() {
        let kind = CaptionTranscriptionProviderKind.offered.last ?? .appleLegacy
        withDefaults([CaptionTranscriptionProviderKind.defaultsKey: kind.rawValue]) {
            XCTAssertEqual(CaptionTranscriptionProviderKind.current(), kind)
        }
    }

    func testAppleLegacyIsAlwaysOffered() {
        // The classic on-device path has to work on every supported macOS
        // version, including below the modern SpeechAnalyzer's floor.
        XCTAssertTrue(CaptionTranscriptionProviderKind.offered.contains(.appleLegacy))
    }

    func testSystemDefaultIsAlwaysOffered() {
        XCTAssertTrue(CaptionTranscriptionProviderKind.offered.contains(CaptionTranscriptionProviderKind.systemDefault))
    }

    func testEveryOfferedKindHasANonEmptyDisplayName() {
        for kind in CaptionTranscriptionProviderKind.offered {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) has no display name")
        }
    }

    func testEveryKindProducesAProvider() {
        for kind in CaptionTranscriptionProviderKind.allCases {
            _ = kind.makeProvider()  // must not crash; existential type-erasure only
        }
    }

    #if OFFLINE
    func testOpenAICompatibleIsNotOfferedInTheOfflineBuild() {
        XCTAssertFalse(CaptionTranscriptionProviderKind.offered.contains(.openAICompatible),
                       "the OpenAI-compatible provider is a cloud integration and must be compiled out of the offline build")
    }
    #endif
}
