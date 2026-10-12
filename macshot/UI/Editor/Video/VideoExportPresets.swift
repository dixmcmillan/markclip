import CoreGraphics
import Foundation

/// A named export configuration shown in the export panel's Presets popup.
/// Persisted in UserDefaults as JSON (custom presets only — built-ins are
/// static). Decodes leniently per CLAUDE.md "Persisted models must decode
/// leniently": a future field or a file written by an older build must not
/// drop every saved preset.
struct VideoExportPreset: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// `VideoExportSettings.Format.rawValue`. Stored as a plain string (not
    /// the enum itself) so this type has no Codable dependency on
    /// `VideoExportSettings.Format`.
    var formatRaw: String
    /// Target long edge in pixels; nil means source resolution (scale 1).
    /// Resolution-independent so a preset applies sensibly to any source.
    var targetLongEdge: Double?
    /// `VideoQuality.rawValue`.
    var qualityRaw: String
    var gifFPS: Int
    /// Built-ins can't be edited or deleted.
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, format: VideoExportSettings.Format, targetLongEdge: Double?,
         quality: VideoQuality, gifFPS: Int = 15, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.formatRaw = format.rawValue
        self.targetLongEdge = targetLongEdge
        self.qualityRaw = quality.rawValue
        self.gifFPS = gifFPS
        self.isBuiltIn = isBuiltIn
    }

    var format: VideoExportSettings.Format { VideoExportSettings.Format(rawValue: formatRaw) ?? .mp4 }
    var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .high }

    /// Resolves this preset against a source's native canvas size (nil when
    /// unknown yet — falls back to scale 1).
    func resolvedSettings(nativeSize: CGSize?) -> VideoExportSettings {
        var settings = VideoExportSettings()
        settings.format = format
        settings.quality = quality
        settings.gifFPS = min(30, max(5, gifFPS))
        if let targetLongEdge, targetLongEdge > 0, let nativeSize {
            let long = max(nativeSize.width, nativeSize.height)
            settings.scale = long > 0 ? min(1, CGFloat(targetLongEdge) / long) : 1
        } else {
            settings.scale = 1
        }
        return settings
    }

    private enum CodingKeys: String, CodingKey { case id, name, formatRaw, targetLongEdge, qualityRaw, gifFPS, isBuiltIn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        name = c.decode(.name, or: "Preset")
        formatRaw = c.decode(.formatRaw, or: VideoExportSettings.Format.mp4.rawValue)
        targetLongEdge = c.decodeOptional(.targetLongEdge)
        qualityRaw = c.decode(.qualityRaw, or: VideoQuality.high.rawValue)
        let fps = c.decode(.gifFPS, or: 15)
        gifFPS = min(30, max(5, fps))
        isBuiltIn = c.decode(.isBuiltIn, or: false)
    }
}

/// Built-ins + custom-preset persistence.
enum VideoExportPresetStore {
    private static let defaultsKey = "videoExportCustomPresets"

    static let builtIns: [VideoExportPreset] = [
        VideoExportPreset(name: L("Web (1080p H.264 Medium)"), format: .mp4, targetLongEdge: 1920,
                          quality: .medium, isBuiltIn: true),
        VideoExportPreset(name: L("Full Quality (source res, High)"), format: .mp4, targetLongEdge: nil,
                          quality: .high, isBuiltIn: true),
        VideoExportPreset(name: L("GIF (small)"), format: .gif, targetLongEdge: 640,
                          quality: .medium, gifFPS: 12, isBuiltIn: true),
    ]

    /// Built-ins first, then saved custom presets in creation order.
    static func all(defaults: UserDefaults = .standard) -> [VideoExportPreset] {
        builtIns + customPresets(defaults: defaults)
    }

    static func customPresets(defaults: UserDefaults = .standard) -> [VideoExportPreset] {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = LenientArrayDecoder.decode(VideoExportPreset.self, from: data) else { return [] }
        return saved.filter { !$0.isBuiltIn }
    }

    static func save(customPresets: [VideoExportPreset], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(customPresets.filter { !$0.isBuiltIn }) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Adds (or replaces, by id) a custom preset and persists it.
    static func addOrReplace(_ preset: VideoExportPreset, defaults: UserDefaults = .standard) {
        var presets = customPresets(defaults: defaults)
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        save(customPresets: presets, defaults: defaults)
    }

    /// Removes a custom preset by id. Built-ins can't be removed (no-op).
    static func delete(id: UUID, defaults: UserDefaults = .standard) {
        let presets = customPresets(defaults: defaults).filter { $0.id != id }
        save(customPresets: presets, defaults: defaults)
    }
}

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
