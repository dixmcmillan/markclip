import CoreGraphics
import Foundation

// The logic behind the export popover and the Settings ▸ Export tab, kept free
// of AppKit so it is unit-tested directly: preset descriptions, the Adjust
// state and the `ExportOverrides` it produces, validation, and the upload
// status line.

// MARK: - Text for presets

/// One-line descriptions of a preset, for the popover summary and the Settings
/// list. Preset names are user data and are shown as stored.
enum ExportPresetDescription {
    static func formatName(_ format: ExportFormat) -> String {
        switch format {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .gif: return "GIF"
        }
    }

    /// `HEVC · Source size · High quality · Captions burned in`.
    static func summary(for preset: ExportPreset) -> String {
        var parts = [formatName(preset.format)]
        parts.append(preset.longEdgeCap.map { String(format: L("Up to %d px"), $0) } ?? L("Source size"))
        if preset.format.isGIF {
            if let fps = preset.fpsCap {
                parts.append(String(format: L("Up to %d fps"), fps))
            } else if preset.destination == .images {
                parts.append(L("Fits Images limits"))
            }
        } else {
            if let fps = preset.fpsCap { parts.append(String(format: L("Up to %d fps"), fps)) }
            if let bitrate = preset.explicitBitrate {
                parts.append(String(format: L("%@ Mbps"), megabitsText(bitrate)))
            } else {
                parts.append(qualityName(preset.quality))
            }
            if preset.audio == .mute { parts.append(L("No audio")) }
        }
        parts.append(captionsName(preset.captions))
        return parts.joined(separator: " · ")
    }

    static func qualityName(_ quality: VideoQuality) -> String {
        switch quality {
        case .high: return L("High quality")
        case .medium: return L("Medium quality")
        case .low: return L("Low quality")
        }
    }

    static func captionsName(_ mode: ExportCaptionsMode) -> String {
        switch mode {
        case .burned: return L("Captions burned in")
        case .soft: return L("Soft captions")
        case .off: return L("No captions")
        }
    }

    /// Where the result goes: a folder path, the Cloudflare product, or TrainWithDixon.
    static func destination(for preset: ExportPreset) -> String {
        switch preset.destination {
        case let .folder(_, path):
            return (path as NSString).abbreviatingWithTildeInPath
        case .stream:
            return preset.alsoSaveLocally ? L("Cloudflare Stream · also saved locally") : L("Cloudflare Stream")
        case .images:
            return preset.alsoSaveLocally ? L("Cloudflare Images · also saved locally") : L("Cloudflare Images")
        case .trainWithDixon:
            return preset.alsoSaveLocally ? L("TrainWithDixon · also saved locally") : L("TrainWithDixon")
        }
    }

    /// `8` / `8.5`, locale-independent so it round-trips through the bitrate field.
    static func megabitsText(_ bitsPerSecond: Int) -> String {
        String(format: "%g", Double(bitsPerSecond) / 1_000_000)
    }
}

/// Keeps preset names distinct without ever rejecting one.
enum ExportPresetNaming {
    /// `base`, or `base 2`, `base 3`… when a preset already has that name.
    static func uniqueName(_ base: String, among presets: [ExportPreset], excluding id: UUID? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? L("New Preset") : trimmed
        let others = presets.filter { $0.id != id }.map { $0.name.lowercased() }
        guard others.contains(name.lowercased()) else { return name }
        var n = 2
        while others.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }
}

// MARK: - Adjust state

/// The popover's Adjust fields. Starts as the selected preset's values; the
/// difference from the preset is the `ExportOverrides` of the run.
struct ExportAdjustState: Equatable {
    var format: ExportFormat
    var longEdgeCap: Int?
    var fpsCap: Int?
    var quality: VideoQuality
    /// Megabits per second as typed; empty means "use the quality tier".
    var bitrateText: String
    var audio: ExportAudioMode
    var captions: ExportCaptionsMode

    init(preset: ExportPreset) {
        format = preset.format
        longEdgeCap = preset.longEdgeCap
        fpsCap = preset.fpsCap
        quality = preset.quality
        bitrateText = preset.explicitBitrate.map(ExportPresetDescription.megabitsText) ?? ""
        audio = preset.audio
        captions = preset.captions
    }

    /// Choices the Adjust popups offer (a preset's own value is added when it
    /// isn't one of them, so selecting a preset never silently changes it).
    static let longEdgeChoices = [3840, 2560, 1920, 1280, 960, 640]
    static let fpsChoices = [60, 30, 24, 15, 12, 10]
}

/// Parsing and bounds for a bitrate typed in megabits per second.
enum ExportBitrateInput {
    static let maxMegabits = 500.0

    enum Result: Equatable {
        /// Field empty: no explicit bitrate.
        case none
        case bitsPerSecond(Int)
        case invalid
    }

    static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return .none }
        guard let value = Double(trimmed), value.isFinite, value > 0, value <= maxMegabits else { return .invalid }
        let bits = Int((value * 1_000_000).rounded())
        return bits > 0 ? .bitsPerSecond(bits) : .invalid
    }
}

// MARK: - Upload status line

/// "Uploaded 2d ago · Processing 45% · Open in dashboard · Retry".
struct ExportStatusLine: Equatable {
    enum Tone { case neutral, success, failure }

    var text: String
    var tone: Tone
    /// Where "Open in dashboard" goes; nil hides the link.
    var dashboardURL: URL?
    var canRetry: Bool

    static func make(record: ExportRecord?, percent: Double?, now: Date, accountID: String?) -> ExportStatusLine? {
        guard let record, record.remoteKind != nil || record.state != nil, let state = record.state else { return nil }
        var parts: [String] = []
        let tone: Tone
        switch state {
        case .uploading:
            return ExportStatusLine(text: L("Uploading…"), tone: .neutral, dashboardURL: nil, canRetry: false)
        case .failed:
            let detail = record.errorText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let text = detail.isEmpty ? L("Upload failed") : String(format: L("Upload failed: %@"), detail)
            return ExportStatusLine(text: text, tone: .failure, dashboardURL: nil, canRetry: true)
        case .processing:
            parts.append(uploadedText(record.uploadedAt, now: now))
            if let percent, percent.isFinite {
                parts.append(String(format: L("Processing %d%%"), Int(max(0, min(100, percent)).rounded())))
            } else {
                parts.append(L("Processing"))
            }
            tone = .neutral
        case .ready:
            parts.append(uploadedText(record.uploadedAt, now: now))
            parts.append(L("Ready"))
            tone = .success
        }
        if let fit = record.fitSummary, !fit.isEmpty { parts.append(fit) }
        let url = dashboardURL(kind: record.remoteKind, remoteID: record.remoteID, accountID: accountID)
        return ExportStatusLine(text: parts.joined(separator: " · "), tone: tone, dashboardURL: url, canRetry: false)
    }

    static func uploadedText(_ date: Date?, now: Date) -> String {
        guard let date else { return L("Uploaded") }
        return String(format: L("Uploaded %@"), age(from: date, to: now))
    }

    /// `just now`, `5m ago`, `3h ago`, `2d ago`.
    static func age(from date: Date, to now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return L("just now") }
        if seconds < 3600 { return String(format: L("%dm ago"), seconds / 60) }
        if seconds < 86_400 { return String(format: L("%dh ago"), seconds / 3600) }
        return String(format: L("%dd ago"), seconds / 86_400)
    }

    /// The Cloudflare dashboard page for an upload. Stream has a page per
    /// video; Images only has the library. TrainWithDixon uploads open the
    /// Coach OS Media page.
    static func dashboardURL(kind: ExportRemoteKind?, remoteID: String?, accountID: String?,
                             coachOSMediaURL: URL? = ExportCoachOSSupport.mediaPageURL) -> URL? {
        if kind == .trainWithDixon { return coachOSMediaURL }
        guard let kind, let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty,
              accountID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        switch kind {
        case .stream:
            guard let remoteID, !remoteID.isEmpty, remoteID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return URL(string: "https://dash.cloudflare.com/\(accountID)/stream/videos/\(remoteID)")
        case .images:
            return URL(string: "https://dash.cloudflare.com/\(accountID)/images/images")
        case .trainWithDixon:
            return nil
        }
    }
}

/// Tells the editor when a Stream upload it started finished processing (or
/// failed to), so it can toast once. Fed record snapshots; remembers the last
/// state per preset.
struct ExportProcessingWatcher {
    enum Event: Equatable {
        case ready(presetKey: String)
        case failed(presetKey: String, message: String)
    }

    private var states: [String: ExportUploadState] = [:]

    /// Starts from the current records without reporting anything.
    mutating func prime(_ records: ExportRecords) {
        states = records.presets.compactMapValues(\.state)
    }

    /// Compares with the last snapshot. Only a `processing` -> `ready`/`failed`
    /// change counts; an upload that finished inside the run is reported by
    /// the run's own result.
    mutating func events(for records: ExportRecords) -> [Event] {
        var events: [Event] = []
        for (key, record) in records.presets.sorted(by: { $0.key < $1.key }) {
            let old = states[key]
            if old == .processing, record.state == .ready { events.append(.ready(presetKey: key)) }
            if old == .processing, record.state == .failed {
                events.append(.failed(presetKey: key, message: record.errorText ?? ""))
            }
        }
        states = records.presets.compactMapValues(\.state)
        return events
    }
}

// MARK: - Popover model

/// State of the export popover: which preset is selected, the Adjust fields,
/// and everything derived from them. The view renders this and forwards
/// clicks; `onChange` fires after any mutation.
@MainActor
final class ExportPopoverModel {
    /// What the model asks of the editor, as closures so tests supply fakes.
    struct Environment {
        var nativeSize: () -> CGSize?
        var outputSize: (VideoExportSettings) -> CGSize?
        var estimatedBytes: (VideoExportSettings) -> Int64?
        var outputDuration: () -> Double
        /// False under OFFLINE, and when no account is saved.
        var cloudflareConfigured: () -> Bool
        var cloudflareAccountID: () -> String?
        /// False under OFFLINE, and when no Coach OS address is saved.
        var coachOSConfigured: () -> Bool
        var now: () -> Date

        init(nativeSize: @escaping () -> CGSize? = { nil },
             outputSize: @escaping (VideoExportSettings) -> CGSize? = { _ in nil },
             estimatedBytes: @escaping (VideoExportSettings) -> Int64? = { _ in nil },
             outputDuration: @escaping () -> Double = { 0 },
             cloudflareConfigured: @escaping () -> Bool = { false },
             cloudflareAccountID: @escaping () -> String? = { nil },
             coachOSConfigured: @escaping () -> Bool = { false },
             now: @escaping () -> Date = { Date() }) {
            self.nativeSize = nativeSize
            self.outputSize = outputSize
            self.estimatedBytes = estimatedBytes
            self.outputDuration = outputDuration
            self.cloudflareConfigured = cloudflareConfigured
            self.cloudflareAccountID = cloudflareAccountID
            self.coachOSConfigured = coachOSConfigured
            self.now = now
        }
    }

    let environment: Environment
    private let defaults: UserDefaults
    private let offline: Bool
    private(set) var presets: [ExportPreset] = []
    private(set) var selectedID: UUID
    private(set) var adjust: ExportAdjustState
    var onChange: (() -> Void)?

    init(environment: Environment, defaults: UserDefaults = .standard, offline: Bool = BuildVariant.isOffline) {
        self.environment = environment
        self.defaults = defaults
        self.offline = offline
        let visible = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        let initial = ExportPresetStore.lastUsedPreset(defaults: defaults, offline: offline) ?? visible.first
            ?? ExportPresetStore.builtIns()[0]
        presets = visible
        selectedID = initial.id
        adjust = ExportAdjustState(preset: initial)
    }

    // MARK: Presets and selection

    var selectedPreset: ExportPreset { presets.first { $0.id == selectedID } ?? presets.first ?? ExportPresetStore.builtIns()[0] }

    /// Re-reads the stored presets (after Settings or Save as Preset changed
    /// them), keeping the selection when it still exists.
    func reloadPresets() {
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        if !presets.contains(where: { $0.id == selectedID }), let first = presets.first {
            selectedID = first.id
        }
        adjust = ExportAdjustState(preset: selectedPreset)
        onChange?()
    }

    func select(_ id: UUID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        if id != selectedID { selectedID = id; adjust = ExportAdjustState(preset: selectedPreset) }
        onChange?()
    }

    func shortcutText(for preset: ExportPreset) -> String? {
        ExportPresetShortcutStore.displayString(for: preset.id, defaults: defaults)
    }

    // MARK: Adjust

    func updateAdjust(_ body: (inout ExportAdjustState) -> Void) {
        var state = adjust
        body(&state)
        guard state != adjust else { return }
        adjust = state
        onChange?()
    }

    /// Puts the Adjust fields back to the selected preset's values.
    func resetAdjust() {
        adjust = ExportAdjustState(preset: selectedPreset)
        onChange?()
    }

    /// What differs from the selected preset. An unparsable bitrate is left
    /// out (and reported by `bitrateError`).
    var overrides: ExportOverrides {
        let preset = selectedPreset
        var result = ExportOverrides()
        if adjust.format != preset.format { result.format = adjust.format }
        if adjust.longEdgeCap != preset.longEdgeCap { result.longEdgeCap = adjust.longEdgeCap.map(ExportLimitOverride.value) ?? .removed }
        if adjust.fpsCap != preset.fpsCap { result.fpsCap = adjust.fpsCap.map(ExportLimitOverride.value) ?? .removed }
        if adjust.quality != preset.quality { result.quality = adjust.quality }
        switch ExportBitrateInput.parse(adjust.bitrateText) {
        case .bitsPerSecond(let bits): if bits != preset.explicitBitrate { result.explicitBitrate = .value(bits) }
        case .none: if preset.explicitBitrate != nil { result.explicitBitrate = .removed }
        case .invalid: break
        }
        if adjust.audio != preset.audio { result.audio = adjust.audio }
        if adjust.captions != preset.captions { result.captions = adjust.captions }
        return result
    }

    var hasAdjustments: Bool { !overrides.isEmpty }

    /// The selected preset with the Adjust changes applied.
    var effectivePreset: ExportPreset { overrides.applied(to: selectedPreset) }

    var bitrateError: String? {
        ExportBitrateInput.parse(adjust.bitrateText) == .invalid ? L("Enter a bitrate above 0 and up to 500 Mbps, or leave it empty.") : nil
    }

    // MARK: Availability

    /// Stream/Images need a Cloudflare account, TrainWithDixon a Coach OS
    /// address. Under OFFLINE they are hidden instead, so this is only ever
    /// true in the normal build.
    var needsUploadSetup: Bool {
        switch effectivePreset.destination {
        case .folder: return false
        case .stream, .images: return !environment.cloudflareConfigured()
        case .trainWithDixon: return !environment.coachOSConfigured()
        }
    }

    /// Why Export is unavailable, and the Settings link, when `needsUploadSetup`.
    var uploadSetupText: (message: String, link: String) {
        if effectivePreset.destination == .trainWithDixon {
            return (L("This preset uploads to TrainWithDixon, which isn't set up yet."), L("Set up TrainWithDixon in Settings"))
        }
        return (L("This preset uploads to Cloudflare, which isn't set up yet."), L("Set up Cloudflare in Settings"))
    }

    /// Whether Export / Save As are allowed right now (valid fields; Save As
    /// doesn't need an upload service, Export does when the destination uploads).
    var canExport: Bool { bitrateError == nil && !needsUploadSetup }
    var canSaveAs: Bool { bitrateError == nil }

    // MARK: Text

    var summaryText: String { ExportPresetDescription.summary(for: effectivePreset) }
    var destinationText: String { ExportPresetDescription.destination(for: effectivePreset) }

    /// `1920×1080 · 0:32 · ~45 MB`; what is known only.
    var detailText: String {
        let settings = effectivePreset.resolvedSettings(nativeSize: environment.nativeSize())
        var parts: [String] = []
        if let size = environment.outputSize(settings), size.width > 0 {
            parts.append("\(Int(size.width.rounded()))×\(Int(size.height.rounded()))")
        }
        let duration = environment.outputDuration()
        if duration > 0 { parts.append(Self.durationText(duration)) }
        if let bytes = environment.estimatedBytes(settings), bytes > 0 {
            parts.append("~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Status

    func statusLine(records: ExportRecordStore, processingPercent: [String: Double] = [:]) -> ExportStatusLine? {
        let preset = selectedPreset
        guard preset.destination.requiresNetwork else { return nil }
        return ExportStatusLine.make(record: records.record(for: preset.id),
                                     percent: processingPercent[preset.id.uuidString],
                                     now: environment.now(), accountID: environment.cloudflareAccountID())
    }

    // MARK: Save as Preset

    /// A new custom preset from the effective settings, saved and selected.
    /// The destination is the selected preset's.
    @discardableResult
    func saveAsPreset(named name: String) -> ExportPreset {
        var preset = effectivePreset
        preset.id = UUID()
        preset.isBuiltIn = false
        preset.name = ExportPresetNaming.uniqueName(name, among: ExportPresetStore.allPresets(defaults: defaults))
        ExportPresetStore.addOrReplace(preset, defaults: defaults)
        presets = ExportPresetStore.visiblePresets(defaults: defaults, offline: offline)
        selectedID = preset.id
        adjust = ExportAdjustState(preset: preset)
        onChange?()
        return preset
    }
}
