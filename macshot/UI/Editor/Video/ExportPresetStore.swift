import Foundation

/// Persistence for `ExportPreset`s: the full ordered list (built-ins first)
/// under `exportPresets.v2`, plus the last-used preset id. The first read
/// seeds the built-ins and migrates the legacy `videoExportCustomPresets`
/// list exactly once, then removes the pre-preset loose export keys.
enum ExportPresetStore {
    static let presetsKey = "exportPresets.v2"
    static let lastUsedKey = "lastUsedExportPresetID"
    /// Set once the legacy list has been folded into `exportPresets.v2`.
    static let migrationFlagKey = "exportPresets.v2.migratedLegacy"

    /// Set once the pre-preset loose keys (`legacyKeys`) have been removed.
    static let legacyCleanupFlagKey = "exportPresets.v2.legacyKeysRemoved"

    // Keys written by the pre-preset export panel. Read once by the migration
    // (custom presets, Archive folder), then deleted by `removeLegacyKeysIfNeeded`.
    static let legacyPresetsKey = "videoExportCustomPresets"
    static let legacyDirectoryKey = "lastExportDestinationDirectory"
    static let legacyKeys = [
        "lastExportScale", "lastExportQuality", "gifExportFPS", "videoEditorExportFormat",
        legacyDirectoryKey, legacyPresetsKey,
    ]

    // Fixed ids: later phases (shortcuts, upload state) refer to built-ins by id.
    static let archiveID = UUID(uuidString: "6D41C11B-0000-4000-8000-000000000001")!
    static let streamID = UUID(uuidString: "6D41C11B-0000-4000-8000-000000000002")!
    static let loopID = UUID(uuidString: "6D41C11B-0000-4000-8000-000000000003")!

    /// Archive, Stream, Loop, in that order. Names are plain strings (persisted
    /// and user-editable, deliberately not localized). `archiveFolderPath` seeds the
    /// Archive folder.
    static func builtIns(archiveFolderPath: String = ExportDestination.defaultArchivePath) -> [ExportPreset] {
        [
            ExportPreset(id: archiveID, name: "Archive", isBuiltIn: true, format: .hevc,
                         longEdgeCap: nil, fpsCap: nil, quality: .high, audio: .keep, captions: .burned,
                         destination: .folder(bookmark: nil, path: archiveFolderPath)),
            ExportPreset(id: streamID, name: "Stream", isBuiltIn: true, format: .h264,
                         longEdgeCap: 1920, fpsCap: 30, quality: .medium, explicitBitrate: 8_000_000,
                         audio: .keep, captions: .soft, destination: .stream,
                         alsoSaveLocally: true, requireSignedURLs: false),
            ExportPreset(id: loopID, name: "Loop", isBuiltIn: true, format: .gif,
                         quality: .medium, audio: .mute, captions: .burned, destination: .images,
                         gifFit: .default),
        ]
    }

    // MARK: Reading

    /// Every stored preset in order (built-ins first), including ones hidden
    /// by OFFLINE. Seeds/migrates on first use.
    static func allPresets(defaults: UserDefaults = .standard) -> [ExportPreset] {
        migrateIfNeeded(defaults: defaults)
        return ensuringBuiltIns(in: stored(defaults: defaults), defaults: defaults)
    }

    /// What pickers should list. Under OFFLINE, stream/images presets are
    /// hidden here but stay in storage.
    static func visiblePresets(defaults: UserDefaults = .standard, offline: Bool = BuildVariant.isOffline) -> [ExportPreset] {
        allPresets(defaults: defaults).filter { $0.isAvailable(offline: offline) }
    }

    static func preset(id: UUID, defaults: UserDefaults = .standard) -> ExportPreset? {
        allPresets(defaults: defaults).first { $0.id == id }
    }

    // MARK: Writing

    /// Replaces the whole list. Built-ins missing from `presets` are restored
    /// on the next read.
    static func save(_ presets: [ExportPreset], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsKey)
    }

    /// Adds (appended) or replaces (by id) a preset and persists the list.
    static func addOrReplace(_ preset: ExportPreset, defaults: UserDefaults = .standard) {
        var presets = allPresets(defaults: defaults)
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        save(presets, defaults: defaults)
    }

    /// Removes a custom preset. Built-ins can't be removed (no-op).
    static func delete(id: UUID, defaults: UserDefaults = .standard) {
        let presets = allPresets(defaults: defaults)
        guard presets.contains(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        save(presets.filter { $0.id != id }, defaults: defaults)
        if lastUsedID(defaults: defaults) == id { defaults.removeObject(forKey: lastUsedKey) }
    }

    // MARK: Last used

    static func lastUsedID(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: lastUsedKey).flatMap(UUID.init(uuidString:))
    }

    static func setLastUsedID(_ id: UUID?, defaults: UserDefaults = .standard) {
        if let id { defaults.set(id.uuidString, forKey: lastUsedKey) } else { defaults.removeObject(forKey: lastUsedKey) }
    }

    /// The last-used preset if it still exists and is visible in this build;
    /// otherwise the first visible one (Archive).
    static func lastUsedPreset(defaults: UserDefaults = .standard, offline: Bool = BuildVariant.isOffline) -> ExportPreset? {
        let visible = visiblePresets(defaults: defaults, offline: offline)
        if let id = lastUsedID(defaults: defaults), let match = visible.first(where: { $0.id == id }) { return match }
        return visible.first
    }

    // MARK: Seeding and migration

    private static func stored(defaults: UserDefaults) -> [ExportPreset] {
        guard let data = defaults.data(forKey: presetsKey),
              let decoded = LenientArrayDecoder.decode(ExportPreset.self, from: data) else { return [] }
        return decoded
    }

    /// Built-ins always exist: re-insert any that are missing (ahead of the
    /// custom presets, in canonical order) without touching stored ones.
    private static func ensuringBuiltIns(in presets: [ExportPreset], defaults: UserDefaults) -> [ExportPreset] {
        let missing = builtIns(archiveFolderPath: seedArchivePath(defaults: defaults))
            .filter { builtIn in !presets.contains { $0.id == builtIn.id } }
        guard !missing.isEmpty else { return presets }
        let builtInIDs = [archiveID, streamID, loopID]
        let present = presets.filter { builtInIDs.contains($0.id) }
        let custom = presets.filter { !builtInIDs.contains($0.id) }
        return (present + missing).sorted { builtInIDs.firstIndex(of: $0.id)! < builtInIDs.firstIndex(of: $1.id)! } + custom
    }

    /// `lastExportDestinationDirectory` if set, else `~/Movies/Markclip Archive`.
    private static func seedArchivePath(defaults: UserDefaults) -> String {
        if let path = defaults.string(forKey: legacyDirectoryKey), !path.isEmpty { return path }
        return ExportDestination.defaultArchivePath
    }

    /// One-time: seed built-ins and fold in the legacy custom presets, then
    /// drop the legacy keys. Both steps are idempotent (`migrationFlagKey`,
    /// `legacyCleanupFlagKey`); the removal always comes after the migration
    /// has read them, and also covers users who migrated before it existed.
    private static func migrateIfNeeded(defaults: UserDefaults) {
        migrateLegacy(defaults: defaults)
        removeLegacyKeysIfNeeded(defaults: defaults)
    }

    /// Deletes the loose pre-preset export keys once. Public so launch can
    /// run it without touching the preset list.
    static func removeLegacyKeysIfNeeded(defaults: UserDefaults = .standard) {
        // Never delete what the migration has not read yet.
        guard defaults.bool(forKey: migrationFlagKey), !defaults.bool(forKey: legacyCleanupFlagKey) else { return }
        for key in legacyKeys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: legacyCleanupFlagKey)
    }

    private static func migrateLegacy(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        let folderPath = seedArchivePath(defaults: defaults)
        var presets = stored(defaults: defaults)   // normally empty on first run
        let existingIDs = Set(presets.map(\.id))
        if let data = defaults.data(forKey: legacyPresetsKey),
           let legacy = LenientArrayDecoder.decode(LegacyPreset.self, from: data) {
            presets += legacy.filter { !$0.isBuiltIn && !existingIDs.contains($0.id) }
                .map { $0.migrated(folderPath: folderPath) }
        }
        save(ensuringBuiltIns(in: presets, defaults: defaults), defaults: defaults)
        defaults.set(true, forKey: migrationFlagKey)
    }

    /// Shape of the pre-v2 `VideoExportPreset` as stored under
    /// `videoExportCustomPresets`. Decode-only.
    struct LegacyPreset: Decodable, Equatable {
        var id: UUID
        var name: String
        var formatRaw: String
        var targetLongEdge: Double?
        var qualityRaw: String
        var gifFPS: Int
        var isBuiltIn: Bool

        private enum CodingKeys: String, CodingKey { case id, name, formatRaw, targetLongEdge, qualityRaw, gifFPS, isBuiltIn }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.decode(.id, or: UUID())
            name = c.decode(.name, or: "Preset")
            formatRaw = c.decode(.formatRaw, or: "mp4")
            targetLongEdge = c.decodeOptional(.targetLongEdge)
            qualityRaw = c.decode(.qualityRaw, or: VideoQuality.high.rawValue)
            gifFPS = min(30, max(5, c.decode(.gifFPS, or: 15)))
            isBuiltIn = c.decode(.isBuiltIn, or: false)
        }

        /// Old mp4 -> H.264 folder preset; old gif -> GIF folder preset with
        /// gifFPS as its fps cap (a video preset never had a frame-rate cap).
        func migrated(folderPath: String) -> ExportPreset {
            let isGIF = formatRaw == "gif"
            let cap: Int? = targetLongEdge.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
            return ExportPreset(id: id, name: name, format: isGIF ? .gif : .h264, longEdgeCap: cap,
                                fpsCap: isGIF ? gifFPS : nil,
                                quality: VideoQuality(rawValue: qualityRaw) ?? .high,
                                audio: isGIF ? .mute : .keep,
                                destination: .folder(bookmark: nil, path: folderPath))
        }
    }
}
