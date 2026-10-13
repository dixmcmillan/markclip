import CoreGraphics
import Foundation

// MARK: - Quick Export support (pure, testable logic)

/// Resolves where Quick Export (⇧⌘E) should write without prompting.
enum QuickExportDestination {
    /// Returns the directory to use, or nil when the caller should fall back
    /// to the regular export dialog once (no last-used destination yet, or
    /// it's no longer writable — e.g. an external drive that's been ejected).
    static func resolve(lastUsedDirectory: URL?, isWritable: (URL) -> Bool) -> URL? {
        guard let lastUsedDirectory, isWritable(lastUsedDirectory) else { return nil }
        return lastUsedDirectory
    }
}

/// Builds the `<source name> <date/time>.<ext>` Quick Export filename.
enum QuickExportFilename {
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        // No colons: valid on disk either way, but colons render as "/" in
        // Finder (classic Mac OS path-separator legacy) which is confusing.
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// `base` should already be sanitized/deduped by the caller if needed —
    /// this only formats the stamped name, it does not touch the filesystem.
    static func build(sourceName: String, date: Date, formatter: DateFormatter = QuickExportFilename.dateFormatter()) -> String {
        "\(sourceName) \(formatter.string(from: date))"
    }
}

/// Picks a free destination URL in `directory`, appending " 2", " 3", … to
/// avoid overwriting an existing file — the same dedup rule `saveVideo()`
/// uses, extracted so both call sites (and tests) share one implementation.
enum FreeDestinationPicker {
    static func pick(directory: URL, base: String, ext: String, keep: URL? = nil, exists: (URL) -> Bool) -> URL {
        var destination = directory.appendingPathComponent(base + "." + ext)
        var n = 2
        while exists(destination), destination != keep {
            destination = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return destination
    }
}
