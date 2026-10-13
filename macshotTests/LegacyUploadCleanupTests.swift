import XCTest

final class LegacyUploadCleanupTests: XCTestCase {
    private var support: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        suite = "macshot-legacy-upload-cleanup-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
    }

    private var tokenFile: URL {
        support.appendingPathComponent("com.sw33tlie.macshot").appendingPathComponent("gdrive_tokens.json")
    }
    private func writeTokenFile() throws {
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"refreshToken":"x"}"#.utf8).write(to: tokenFile)
    }

    func testRemovesEveryObsoleteKeyAndTheTokenFileThenSetsTheFlag() throws {
        for key in LegacyUploadCleanup.obsoleteDefaultsKeys { defaults.set("value", forKey: key) }
        defaults.set("png", forKey: "imageFormat")
        let sibling = tokenFile.deletingLastPathComponent().appendingPathComponent("keep.json")
        try writeTokenFile()
        try Data("{}".utf8).write(to: sibling)

        LegacyUploadCleanup.run(defaults: defaults, applicationSupportDirectory: support)

        for key in LegacyUploadCleanup.obsoleteDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), "`\(key)` should be removed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "only the Drive token file is deleted")
        XCTAssertEqual(defaults.string(forKey: "imageFormat"), "png", "unrelated settings are untouched")
        XCTAssertTrue(defaults.bool(forKey: LegacyUploadCleanup.doneKey))
    }

    func testKeyListCoversTheSecretsTheOldUploadersStored() {
        let keys = Set(LegacyUploadCleanup.obsoleteDefaultsKeys)
        for required in ["s3SecretAccessKey", "s3AccessKeyID", "imgbbAPIKey", "imgbbUploads", "uploadProvider",
                         "googleDriveRefreshToken", "gdriveUserEmail", "gdriveFolderName", "uploadConfirmEnabled"] {
            XCTAssertTrue(keys.contains(required), "`\(required)` missing from the cleanup list")
        }
    }

    func testRunsOnlyOnce() throws {
        LegacyUploadCleanup.run(defaults: defaults, applicationSupportDirectory: support)
        defaults.set("late", forKey: "s3Bucket")
        try writeTokenFile()

        LegacyUploadCleanup.run(defaults: defaults, applicationSupportDirectory: support)

        XCTAssertEqual(defaults.string(forKey: "s3Bucket"), "late", "the done flag prevents a second sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFile.path))
    }

    func testMissingTokenFileIsFineAndStillCompletes() {
        defaults.set("x", forKey: "imgbbAPIKey")
        LegacyUploadCleanup.run(defaults: defaults, applicationSupportDirectory: support)
        XCTAssertNil(defaults.object(forKey: "imgbbAPIKey"))
        XCTAssertTrue(defaults.bool(forKey: LegacyUploadCleanup.doneKey))
    }
}
