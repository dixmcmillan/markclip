import CoreGraphics
import Foundation

// MARK: - Preset value types

/// Output format of a preset. H.264/HEVC are MP4 video; GIF is the animated
/// image path.
enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case h264, hevc, gif

    var isGIF: Bool { self == .gif }

    /// The legacy container-level format the existing export paths switch on.
    var settingsFormat: VideoExportSettings.Format { self == .gif ? .gif : .mp4 }

    /// The video codec for the encoder. GIF carries no codec; H.264 is the
    /// inert default.
    var codec: VideoCodec { self == .hevc ? .hevc : .h264 }
}

enum ExportAudioMode: String, Codable, CaseIterable, Sendable {
    case keep, mute
}

enum ExportCaptionsMode: String, Codable, CaseIterable, Sendable {
    /// Rendered into the pixels.
    case burned
    /// Delivered as a separate WebVTT/SRT track; the video has no caption pixels.
    case soft
    case off
}

extension VideoQuality: Codable {}

/// Limits for GIF auto-fit (Loop preset). Planner lives in Phase 2; these are
/// just the persisted knobs.
struct GIFFitSettings: Codable, Equatable, Sendable {
    /// Hard file-size ceiling in bytes (Cloudflare Images: 10 MB).
    var maxBytes: Int = 10_000_000
    /// Ceiling on frames x width x height, in megapixels (Images: 50 MP).
    var maxTotalMegapixels: Double = 50
    /// Auto-fit never shrinks the long edge below this.
    var minLongEdge: Int = 640
    /// Auto-fit never drops below this frame rate.
    var minFPS: Int = 8
    /// Frame rate auto-fit starts from.
    var startFPS: Int = 15

    static let `default` = GIFFitSettings()

    init() {}

    private enum CodingKeys: String, CodingKey { case maxBytes, maxTotalMegapixels, minLongEdge, minFPS, startFPS }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GIFFitSettings()
        maxBytes = max(1, c.decode(.maxBytes, or: d.maxBytes))
        let mp = c.decode(.maxTotalMegapixels, or: d.maxTotalMegapixels)
        maxTotalMegapixels = mp.isFinite && mp > 0 ? mp : d.maxTotalMegapixels
        minLongEdge = max(16, c.decode(.minLongEdge, or: d.minLongEdge))
        minFPS = max(1, c.decode(.minFPS, or: d.minFPS))
        startFPS = max(minFPS, c.decode(.startFPS, or: d.startFPS))
    }
}

/// Where a preset delivers its result.
enum ExportDestination: Codable, Equatable, Sendable {
    /// A local folder. `bookmark` is preferred when present and resolvable;
    /// `path` is the fallback (and what is shown in UI).
    case folder(bookmark: Data?, path: String)
    /// Cloudflare Stream (video). Unavailable in the OFFLINE build.
    case stream
    /// Cloudflare Images (short loops). Unavailable in the OFFLINE build.
    case images
    /// TrainWithDixon: Stream through Coach OS's managed upload, so the video
    /// lands Managed with signed delivery. Unavailable in the OFFLINE build.
    case trainWithDixon

    /// `~/Movies/Markclip Archive`.
    static var defaultArchivePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Markclip Archive", isDirectory: true).path
    }

    static var defaultFolder: ExportDestination { .folder(bookmark: nil, path: defaultArchivePath) }

    /// Folder destination for `url`; the bookmark is best-effort (a folder that
    /// doesn't exist yet can't be bookmarked, the path still works).
    static func folder(url: URL) -> ExportDestination {
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return .folder(bookmark: bookmark, path: url.path)
    }

    var isFolder: Bool { if case .folder = self { return true } else { return false } }

    /// Stream, Images and TrainWithDixon need an uploader, which the OFFLINE
    /// build compiles out.
    var requiresNetwork: Bool { !isFolder }

    /// The folder to write into, or nil for non-folder destinations. Prefers a
    /// non-stale bookmark, then the stored path.
    func resolvedFolderURL() -> URL? {
        guard case let .folder(bookmark, path) = self else { return nil }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale {
                return url
            }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private enum CodingKeys: String, CodingKey { case kind, bookmark, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.decode(.kind, or: "folder") {
        case "stream": self = .stream
        case "images": self = .images
        case "trainWithDixon": self = .trainWithDixon
        default:
            // Unknown/future kinds fall back to a local folder: the safe
            // destination that never uploads anything.
            let path: String = c.decode(.path, or: "")
            self = .folder(bookmark: c.decodeOptional(.bookmark),
                           path: path.isEmpty ? Self.defaultArchivePath : path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .folder(bookmark, path):
            try c.encode("folder", forKey: .kind)
            try c.encodeIfPresent(bookmark, forKey: .bookmark)
            try c.encode(path, forKey: .path)
        case .stream: try c.encode("stream", forKey: .kind)
        case .images: try c.encode("images", forKey: .kind)
        case .trainWithDixon: try c.encode("trainWithDixon", forKey: .kind)
        }
    }
}

// MARK: - Preset

/// A named export configuration: encoding plus destination. Persisted by
/// `ExportPresetStore`; decodes leniently per CLAUDE.md so a future field or
/// an older build's file never drops the whole list.
struct ExportPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Built-ins can't be deleted (they can still be re-pointed at a folder).
    var isBuiltIn: Bool
    var format: ExportFormat
    /// Long-edge pixel cap; nil means source resolution. Never upscales.
    var longEdgeCap: Int?
    /// Frame-rate cap; nil means source rate (GIF: `gifFit.startFPS`).
    var fpsCap: Int?
    var quality: VideoQuality
    /// Bits per second. When set it wins over `quality` for the encoder.
    var explicitBitrate: Int?
    var audio: ExportAudioMode
    var captions: ExportCaptionsMode
    var destination: ExportDestination
    /// Stream/Images only: also write a local copy.
    var alsoSaveLocally: Bool
    /// Stream only.
    var requireSignedURLs: Bool
    var gifFit: GIFFitSettings

    init(id: UUID = UUID(), name: String, isBuiltIn: Bool = false, format: ExportFormat = .h264,
         longEdgeCap: Int? = nil, fpsCap: Int? = nil, quality: VideoQuality = .high,
         explicitBitrate: Int? = nil, audio: ExportAudioMode = .keep, captions: ExportCaptionsMode = .burned,
         destination: ExportDestination = .defaultFolder, alsoSaveLocally: Bool = false,
         requireSignedURLs: Bool = false, gifFit: GIFFitSettings = .default) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.format = format
        self.longEdgeCap = longEdgeCap
        self.fpsCap = fpsCap
        self.quality = quality
        self.explicitBitrate = explicitBitrate
        self.audio = audio
        self.captions = captions
        self.destination = destination
        self.alsoSaveLocally = alsoSaveLocally
        self.requireSignedURLs = requireSignedURLs
        self.gifFit = gifFit
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, format, longEdgeCap, fpsCap, quality, explicitBitrate, audio, captions
        case destination, alsoSaveLocally, requireSignedURLs, gifFit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        name = c.decode(.name, or: "Preset")
        isBuiltIn = c.decode(.isBuiltIn, or: false)
        format = c.decode(.format, or: .h264)
        longEdgeCap = c.decodeOptional(.longEdgeCap, as: Int.self).flatMap { $0 > 0 ? $0 : nil }
        fpsCap = c.decodeOptional(.fpsCap, as: Int.self).flatMap { $0 > 0 ? $0 : nil }
        quality = c.decode(.quality, or: .high)
        explicitBitrate = c.decodeOptional(.explicitBitrate, as: Int.self).flatMap { $0 > 0 ? $0 : nil }
        audio = c.decode(.audio, or: .keep)
        captions = c.decode(.captions, or: .burned)
        destination = c.decode(.destination, or: .defaultFolder)
        alsoSaveLocally = c.decode(.alsoSaveLocally, or: false)
        requireSignedURLs = c.decode(.requireSignedURLs, or: false)
        gifFit = c.decode(.gifFit, or: .default)
    }

    /// Hidden in OFFLINE builds: anything that needs the network.
    func isAvailable(offline: Bool) -> Bool { !(offline && destination.requiresNetwork) }

    /// Resolves this preset against a source's native canvas size (nil when
    /// unknown yet: scale 1), with optional one-off "Adjust" overrides applied
    /// on top.
    func resolvedSettings(nativeSize: CGSize?, overrides: ExportOverrides = ExportOverrides()) -> VideoExportSettings {
        let p = overrides.applied(to: self)
        var settings = VideoExportSettings()
        settings.format = p.format.settingsFormat
        settings.codec = p.format.codec
        settings.quality = p.quality
        settings.gifFit = p.gifFit
        settings.gifFPS = min(30, max(5, p.fpsCap ?? p.gifFit.startFPS))
        settings.fpsCap = p.fpsCap
        settings.explicitBitrate = p.explicitBitrate
        settings.captions = p.captions
        settings.muted = p.audio == .mute
        if let cap = p.longEdgeCap, cap > 0, let nativeSize {
            let long = max(nativeSize.width, nativeSize.height)
            settings.scale = long > 0 ? min(1, CGFloat(cap) / long) : 1
        } else {
            settings.scale = 1
        }
        return settings
    }
}

/// A one-off change to a numeric cap: remove it, or set it.
enum ExportLimitOverride: Equatable, Sendable {
    case removed
    case value(Int)

    func apply(to current: Int?) -> Int? {
        switch self {
        case .removed: return nil
        case .value(let v): return v > 0 ? v : nil
        }
    }
}

/// One-off tweaks from the popover's Adjust disclosure. Every field is
/// optional; nil leaves the preset's value alone. Never persisted.
struct ExportOverrides: Equatable, Sendable {
    var format: ExportFormat?
    var longEdgeCap: ExportLimitOverride?
    var fpsCap: ExportLimitOverride?
    var quality: VideoQuality?
    var explicitBitrate: ExportLimitOverride?
    var audio: ExportAudioMode?
    var captions: ExportCaptionsMode?
    /// "Save As…": write the preset's encoding to exactly this file and do
    /// nothing else (no upload, no change to the per-preset records). The
    /// extension follows the format. Not a preset field, so `applied(to:)`
    /// ignores it; `ExportRun` reads it.
    var saveAsURL: URL?

    /// True when no encoding field is overridden. A Save As destination is not
    /// an "adjustment", so it doesn't count.
    var isEmpty: Bool {
        var copy = self
        copy.saveAsURL = nil
        return copy == ExportOverrides()
    }

    func applied(to preset: ExportPreset) -> ExportPreset {
        var p = preset
        if let format { p.format = format }
        if let longEdgeCap { p.longEdgeCap = longEdgeCap.apply(to: p.longEdgeCap) }
        if let fpsCap { p.fpsCap = fpsCap.apply(to: p.fpsCap) }
        if let quality { p.quality = quality }
        if let explicitBitrate { p.explicitBitrate = explicitBitrate.apply(to: p.explicitBitrate) }
        if let audio { p.audio = audio }
        if let captions { p.captions = captions }
        return p
    }
}
