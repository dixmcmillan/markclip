import Foundation

/// Keeps the records of uploaded videos honest after a run is over:
///
/// - polls Stream every few seconds (while the app runs) until a processing
///   video is ready or failed;
/// - once the newest video is ready, deletes the ones it replaces
///   (`pendingDeleteUIDs`), and retries a delete that failed earlier;
/// - on request (`refreshAll`, called when the export popover opens) does one
///   pass over every record, and marks an upload that was cut off by a quit as
///   failed.
///
/// Nothing here is persisted beyond the records themselves, and it is not part
/// of the media-export quit drain: a video still processing never blocks Quit.
@MainActor
final class ExportRemoteSync {
    private let records: ExportRecordStore
    private let remote: () -> ExportRemoteService?
    private let clock: ExportClock
    private let interval: Double
    /// Consecutive polling passes that hit a network error before the loop
    /// gives up until the next `refreshAll`.
    private let maxConsecutiveFailures = 12
    private var pollTask: Task<Void, Never>?

    /// Presets with a run in flight; their `.uploading` state is genuine.
    var activePresetIDs: () -> Set<UUID> = { [] }
    /// Stream's reported encoding progress (0...100) per preset id string.
    private(set) var processingPercent: [String: Double] = [:]
    /// Called after any change a status line should redraw for.
    var onChange: (() -> Void)?

    init(records: ExportRecordStore, remote: @escaping () -> ExportRemoteService?,
         clock: ExportClock = SystemExportClock(), interval: Double = 5) {
        self.records = records
        self.remote = remote
        self.clock = clock
        self.interval = interval
    }

    var isPolling: Bool { pollTask != nil }

    /// The popover-open hook: one pass over every record, then polling resumes
    /// if anything is still processing.
    func refreshAll() async {
        let active = Set(activePresetIDs().map(\.uuidString))
        for key in records.records.presets.keys.sorted() {
            guard let record = records.record(forKey: key) else { continue }
            if record.state == .uploading, !active.contains(key) {
                records.update(key: key) {
                    $0.state = .failed
                    $0.errorText = "The upload was interrupted. Export again to retry."
                }
                onChange?()
            }
        }
        for key in records.records.presets.keys.sorted() {
            _ = await refresh(key: key)
        }
        startPollingIfNeeded()
    }

    /// Starts the poll loop when a Stream video is processing. No-op if it is
    /// already running or there is nothing to poll.
    func startPollingIfNeeded() {
        guard pollTask == nil, needsPolling, remote() != nil else { return }
        // Deliberately strong: polling continues after the editor that started
        // it closes, and ends by itself when nothing is processing.
        pollTask = Task {
            var failures = 0
            while true {
                let outcome = await pollPass()
                failures = outcome.networkError ? failures + 1 : 0
                guard outcome.keepGoing, failures < maxConsecutiveFailures, !Task.isCancelled else { break }
                do { try await clock.sleep(seconds: interval) } catch { break }
            }
            pollTask = nil
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Resolves when the poll loop has ended (tests).
    func waitForPolling() async {
        await pollTask?.value
    }

    private var needsPolling: Bool {
        records.records.presets.values.contains { $0.needsStatusPolling }
    }

    private func pollPass() async -> (keepGoing: Bool, networkError: Bool) {
        var networkError = false
        for key in records.records.presets.keys.sorted() where records.record(forKey: key)?.needsStatusPolling == true {
            if await refresh(key: key) == .networkError { networkError = true }
            if Task.isCancelled { return (false, networkError) }
        }
        return (needsPolling, networkError)
    }

    enum RefreshOutcome: Equatable { case unchanged, updated, networkError }

    /// One check of one record: status for a processing video, then the
    /// pending deletes if the video is ready.
    @discardableResult
    private func refresh(key: String) async -> RefreshOutcome {
        guard let service = remote(), let record = records.record(forKey: key) else { return .unchanged }
        var outcome = RefreshOutcome.unchanged
        if record.needsStatusPolling, let uid = record.remoteID {
            do {
                let status = try await service.streamStatus(uid: uid)
                // A newer upload may have replaced this one while we waited.
                guard records.record(forKey: key)?.remoteID == uid else { return .unchanged }
                switch status {
                case .processing(let percent):
                    if let percent { processingPercent[key] = percent }
                case .ready:
                    processingPercent[key] = nil
                    records.update(key: key) { $0.state = .ready; $0.errorText = nil }
                    outcome = .updated
                case .failed(let text):
                    processingPercent[key] = nil
                    records.update(key: key) {
                        $0.state = .failed
                        $0.errorText = text.isEmpty ? "Stream couldn't process the video." : text
                    }
                    outcome = .updated
                case .missing:
                    processingPercent[key] = nil
                    records.update(key: key) { $0.state = .failed; $0.errorText = "The video was removed from Stream." }
                    outcome = .updated
                }
            } catch {
                return .networkError
            }
        }
        if await deletePending(key: key, service: service) { outcome = .updated }
        if outcome == .updated { onChange?() }
        return outcome
    }

    /// Deletes superseded videos, only while the current one is ready. A delete
    /// that fails stays in the list for the next pass.
    private func deletePending(key: String, service: ExportRemoteService) async -> Bool {
        guard let record = records.record(forKey: key), record.state == .ready,
              record.remoteKind == .stream, !record.pendingDeleteUIDs.isEmpty else { return false }
        var changed = false
        for uid in record.pendingDeleteUIDs {
            do {
                try await service.deleteStream(uid: uid)
                records.update(key: key) { $0.pendingDeleteUIDs.removeAll { $0 == uid } }
                changed = true
            } catch {
                continue
            }
        }
        return changed
    }
}
