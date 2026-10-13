import Foundation

/// One-time removal of the credentials and bookkeeping left behind by the
/// retired Google Drive, S3-compatible and imgbb uploaders (Phase 7). The
/// uploaders themselves are gone, so nothing reads these any more — leaving
/// an S3 secret key or a Drive refresh token sitting in the defaults domain
/// and Application Support folder would only be a liability.
///
/// Guarded by a done-flag so it costs one `UserDefaults` read on later
/// launches. If the token file exists but can't be removed, the flag is not
/// set and the next launch tries again.
enum LegacyUploadCleanup {
    static let doneKey = "legacyUploadCleanupDone"

    /// Every UserDefaults key the removed uploaders and their UI wrote.
    static let obsoleteDefaultsKeys: [String] = [
        // S3-compatible
        "s3Endpoint", "s3Region", "s3Bucket", "s3AccessKeyID", "s3SecretAccessKey",
        "s3PublicURLBase", "s3PathPrefix", "s3PublicRead",
        // imgbb
        "imgbbAPIKey", "imgbbUploads",
        // Google Drive
        "googleDriveRefreshToken", "gdriveUserEmail", "gdriveFolderName",
        // Provider selection / screenshot upload confirmation
        "uploadProvider", "uploadConfirmEnabled",
    ]

    /// Same literal folder `GoogleDriveUploader` used (see CLAUDE.md "Project
    /// Setup": the Application Support folder name is fixed, not derived from
    /// the bundle ID).
    static let dataFolderName = "com.sw33tlie.macshot"
    static let driveTokenFileName = "gdrive_tokens.json"

    static func run(defaults: UserDefaults = .standard,
                    fileManager: FileManager = .default,
                    applicationSupportDirectory: URL? = nil) {
        guard !defaults.bool(forKey: doneKey) else { return }

        for key in obsoleteDefaultsKeys { defaults.removeObject(forKey: key) }

        var tokenFileGone = true
        if let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let tokenFile = support
                .appendingPathComponent(dataFolderName, isDirectory: true)
                .appendingPathComponent(driveTokenFileName)
            if fileManager.fileExists(atPath: tokenFile.path) {
                do { try fileManager.removeItem(at: tokenFile) } catch { tokenFileGone = false }
            }
        }

        if tokenFileGone { defaults.set(true, forKey: doneKey) }
    }
}
