import Foundation

/// Where a preset's local copy goes, and whether it may replace what is there.
/// Pure file-system logic, shared by `ExportRun` and the tests.
enum ExportLocalDestination {
    struct Choice: Equatable {
        let url: URL
        /// True only when `url` is the file this preset last wrote and it is
        /// still byte-for-byte what we wrote (size and mtime match).
        let overwrites: Bool
    }

    /// Picks `<folder>/<base>.<ext>`.
    ///
    /// Re-exporting a preset overwrites the file it last wrote for this
    /// project, but only while that file is still the one we wrote: same
    /// folder, same extension, and `recorded` matches the disk (path, size,
    /// mtime). Anything else (a replaced or edited file, an unrelated file with
    /// the name) falls back to numbering (`Name 2.mp4`).
    static func choose(folder: URL, base: String, ext: String, recorded: ExportFileRecord?,
                       fileManager: FileManager = .default) -> Choice {
        var keep: URL?
        if let recorded, recorded.matchesDisk(fileManager: fileManager) {
            let previous = URL(fileURLWithPath: recorded.path)
            if previous.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
               previous.pathExtension == ext {
                // Build it from `folder` so URL equality with the picker's candidates is exact.
                keep = folder.appendingPathComponent(previous.lastPathComponent)
            }
        }
        let url = FreeDestinationPicker.pick(directory: folder, base: base, ext: ext, keep: keep) {
            fileManager.fileExists(atPath: $0.path)
        }
        return Choice(url: url, overwrites: keep != nil && url == keep)
    }

    /// Creates `folder` (and parents) when it is missing.
    nonisolated static func ensureFolder(_ folder: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Creates `~/Movies/Markclip Archive` when it is missing and returns it.
    @discardableResult
    static func ensureDefaultArchiveFolder(fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: ExportDestination.defaultArchivePath, isDirectory: true)
        do { try ensureFolder(url, fileManager: fileManager) } catch { return nil }
        return url
    }
}
