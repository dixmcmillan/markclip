import Foundation

/// One-time recovery for data left behind in a macOS sandbox container.
///
/// Markclip Phase 1 (identity — see ROADMAP.md) disables App Sandbox and
/// changes the bundle ID. Every on-disk path this app uses under
/// Application Support is a fixed literal string ("com.sw33tlie.macshot/…"),
/// not derived from the bundle ID — see `RecordingSessionStore.rootURL`,
/// and `ScreenshotHistory`. That's what normally keeps old
/// data reachable across a bundle ID change without any migration at all.
///
/// But a *sandboxed* build (the app's previous configuration) wrote that
/// folder inside its own per-bundle-ID container —
/// `~/Library/Containers/<old-bundle-id>/Data/Library/Application
/// Support/com.sw33tlie.macshot` — which an unsandboxed build can no longer
/// reach through `FileManager.applicationSupportDirectory`: that now
/// resolves to the real `~/Library/Application Support`, not a container.
/// Disabling the sandbox is itself a location change, so it needs this.
///
/// Runs once at launch, before anything reads or writes that folder: if the
/// real (unsandboxed) location doesn't have it yet, and exactly one old
/// container has it, copy it over. Never moves or deletes the original, and
/// never overwrites an existing destination. Ambiguous (more than one old
/// container matches) or nothing found: does nothing automatically rather
/// than guess — the original data is untouched either way, just not
/// auto-discovered, and can still be moved manually.
enum SandboxContainerMigration {
    static let dataFolderName = "com.sw33tlie.macshot"

    static func runIfNeeded(fileManager: FileManager = .default,
                            containersDirectory: URL? = nil,
                            applicationSupportDirectory: URL? = nil) {
        let fm = fileManager
        guard let support = applicationSupportDirectory
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let destination = support.appendingPathComponent(dataFolderName, isDirectory: true)
        // Already migrated (or a fresh install with nothing to migrate yet).
        guard !fm.fileExists(atPath: destination.path) else { return }

        let containers = containersDirectory
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) else { return }

        let candidates = entries
            .filter { $0.lastPathComponent.lowercased().contains("macshot") }
            .map { $0.appendingPathComponent("Data/Library/Application Support/\(dataFolderName)", isDirectory: true) }
            .filter { fm.fileExists(atPath: $0.path) }

        guard candidates.count == 1, let source = candidates.first else { return }

        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: destination)
    }
}
