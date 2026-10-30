import Foundation

// Per-project export memory: what each preset last wrote locally and uploaded.
//
// Lives in `<take>.exports.json`, next to `<take>.project.json` (same folder
// logic as `VideoEditorDocument`), and deliberately not inside `VideoProject`:
// export bookkeeping must not enter undo snapshots or the dirty state.
// Everything decodes leniently (CLAUDE.md): a newer or older build's file loses
// at most the entry it can't read.

/// A file an export wrote. The overwrite guard compares all three fields to the
/// file on disk, so a file the user replaced or edited is never overwritten.
nonisolated struct ExportFileRecord: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    /// `timeIntervalSince1970` of the modification date.
    var mtime: Double

    init(path: String, size: Int64, mtime: Double) {
        self.path = path
        self.size = size
        self.mtime = mtime
    }

    private enum CodingKeys: String, CodingKey { case path, size, mtime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.decode(.path, or: "")
        size = c.decode(.size, or: 0)
        mtime = c.decode(.mtime, or: 0)
    }

    /// Reads the current size and mtime of `url`; nil when it isn't a file.
    static func describing(_ url: URL, fileManager: FileManager = .default) -> ExportFileRecord? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return ExportFileRecord(path: url.path, size: size, mtime: date.timeIntervalSince1970)
    }

    /// True when the file at `path` still has the recorded size and mtime.
    func matchesDisk(fileManager: FileManager = .default) -> Bool {
        guard !path.isEmpty,
              let current = Self.describing(URL(fileURLWithPath: path), fileManager: fileManager) else { return false }
        return current.size == size && abs(current.mtime - mtime) < 0.001
    }
}

nonisolated enum ExportRemoteKind: String, Codable, Sendable {
    case stream, images
    /// Stream through Coach OS; the remote id is the Coach OS reservation id.
    case trainWithDixon
}

nonisolated enum ExportUploadState: String, Codable, Sendable {
    /// The upload is in flight (or was, when the app quit).
    case uploading
    /// Uploaded; Stream is still encoding it.
    case processing
    /// Playable (Stream) or stored (Images).
    case ready
    case failed
}

/// What one preset last did for this project.
nonisolated struct ExportRecord: Codable, Equatable, Sendable {
    var localFile: ExportFileRecord?
    var remoteKind: ExportRemoteKind?
    /// Stream UID, Images id or Coach OS reservation id of the latest upload.
    var remoteID: String?
    var uploadedAt: Date?
    var state: ExportUploadState?
    /// Why `state` is `.failed`.
    var errorText: String?
    /// Stream UIDs superseded by a newer upload. Each is deleted only after the
    /// newest upload is ready; a failed delete stays here and is retried when
    /// the popover opens. (The plan names one `pendingDeleteUID`; a list keeps a
    /// second re-upload from orphaning the first one's video. A legacy singular
    /// `pendingDeleteUID` key still decodes into this list.)
    var pendingDeleteUIDs: [String]
    /// Language of the Stream caption track that was uploaded, if any.
    var captionsLanguage: String?
    /// What GIF auto-fit changed, e.g. "fit: 12 fps, 960 px".
    var fitSummary: String?

    init(localFile: ExportFileRecord? = nil, remoteKind: ExportRemoteKind? = nil, remoteID: String? = nil,
         uploadedAt: Date? = nil, state: ExportUploadState? = nil, errorText: String? = nil,
         pendingDeleteUIDs: [String] = [], captionsLanguage: String? = nil, fitSummary: String? = nil) {
        self.localFile = localFile
        self.remoteKind = remoteKind
        self.remoteID = remoteID
        self.uploadedAt = uploadedAt
        self.state = state
        self.errorText = errorText
        self.pendingDeleteUIDs = pendingDeleteUIDs
        self.captionsLanguage = captionsLanguage
        self.fitSummary = fitSummary
    }

    private enum CodingKeys: String, CodingKey {
        case localFile, remoteKind, remoteID, uploadedAt, state, errorText
        case pendingDeleteUIDs, pendingDeleteUID, captionsLanguage, fitSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localFile = c.decodeOptional(.localFile)
        remoteKind = c.decodeOptional(.remoteKind)
        remoteID = c.decodeOptional(.remoteID, as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        uploadedAt = c.decodeOptional(.uploadedAt)
        state = c.decodeOptional(.state)
        errorText = c.decodeOptional(.errorText)
        var pending: [String] = c.decode(.pendingDeleteUIDs, or: [])
        if let legacy = c.decodeOptional(.pendingDeleteUID, as: String.self), !legacy.isEmpty, !pending.contains(legacy) {
            pending.append(legacy)
        }
        pendingDeleteUIDs = pending.filter { !$0.isEmpty }
        captionsLanguage = c.decodeOptional(.captionsLanguage)
        fitSummary = c.decodeOptional(.fitSummary)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(localFile, forKey: .localFile)
        try c.encodeIfPresent(remoteKind, forKey: .remoteKind)
        try c.encodeIfPresent(remoteID, forKey: .remoteID)
        try c.encodeIfPresent(uploadedAt, forKey: .uploadedAt)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(errorText, forKey: .errorText)
        if !pendingDeleteUIDs.isEmpty { try c.encode(pendingDeleteUIDs, forKey: .pendingDeleteUIDs) }
        try c.encodeIfPresent(captionsLanguage, forKey: .captionsLanguage)
        try c.encodeIfPresent(fitSummary, forKey: .fitSummary)
    }

    /// A Stream video (direct or through Coach OS) that must be polled until it is playable.
    var needsStatusPolling: Bool {
        (remoteKind == .stream || remoteKind == .trainWithDixon) && state == .processing && remoteID != nil
    }
}

/// The whole sidecar: records keyed by preset id (`UUID.uuidString`).
nonisolated struct ExportRecords: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = ExportRecords.currentVersion
    var presets: [String: ExportRecord] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, presets }

    /// Decodes each preset's record on its own, so one unreadable record costs
    /// that entry rather than the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(.version, or: Self.currentVersion)
        presets = [:]
        guard let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .presets) else { return }
        for key in nested.allKeys {
            if let record = try? nested.decode(ExportRecord.self, forKey: key) { presets[key.stringValue] = record }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func decode(_ data: Data) -> ExportRecords? {
        try? JSONDecoder.exportRecords.decode(ExportRecords.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder.exportRecords.encode(self)
    }
}

private extension JSONEncoder {
    nonisolated static var exportRecords: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var exportRecords: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reads and writes one project's `.exports.json`. One instance per file
/// (`store(for:)`), so two editors on the same take share their records.
@MainActor
final class ExportRecordStore {
    /// `<take>.project.json` -> `<take>.exports.json`; nil when the project
    /// has no sidecar location.
    nonisolated static func sidecarURL(forProjectURL projectURL: URL) -> URL {
        let name = projectURL.lastPathComponent
        let suffix = ".project.json"
        let base = name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : projectURL.deletingPathExtension().lastPathComponent
        return projectURL.deletingLastPathComponent().appendingPathComponent(base + ".exports.json")
    }

    private static var shared: [String: ExportRecordStore] = [:]

    /// The store for `url`; the same instance for the same file.
    static func store(for url: URL) -> ExportRecordStore {
        let key = url.standardizedFileURL.path
        if let existing = shared[key] { return existing }
        let store = ExportRecordStore(url: url)
        shared[key] = store
        return store
    }

    /// The sidecar file; nil for an in-memory store (no location to write).
    let url: URL?
    private(set) var records: ExportRecords
    private var observers: [UUID: () -> Void] = [:]

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = ExportRecords.decode(data) {
            records = decoded
        } else {
            records = ExportRecords()
        }
    }

    func record(for presetID: UUID) -> ExportRecord? { records.presets[presetID.uuidString] }
    func record(forKey key: String) -> ExportRecord? { records.presets[key] }

    /// Mutates (creating if needed) one preset's record and saves.
    @discardableResult
    func update(_ presetID: UUID, _ body: (inout ExportRecord) -> Void) -> ExportRecord {
        update(key: presetID.uuidString, body)
    }

    @discardableResult
    func update(key: String, _ body: (inout ExportRecord) -> Void) -> ExportRecord {
        var record = records.presets[key] ?? ExportRecord()
        body(&record)
        records.presets[key] = record
        save()
        return record
    }

    func remove(_ presetID: UUID) {
        guard records.presets.removeValue(forKey: presetID.uuidString) != nil else { return }
        save()
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Atomic write. The file is tiny, so this stays on the calling thread; a
    /// failed write is not fatal (the in-memory records stay correct for the
    /// session).
    private func save() {
        defer { for handler in observers.values { handler() } }
        guard let url, let data = records.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Bookkeeping only; never fail an export over it.
        }
    }
}
