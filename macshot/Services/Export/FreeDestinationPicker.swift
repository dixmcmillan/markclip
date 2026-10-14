import Foundation

/// Picks a free destination URL in `directory`, appending " 2", " 3", … to
/// avoid overwriting an existing file. `ExportLocalDestination` builds on it.
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
