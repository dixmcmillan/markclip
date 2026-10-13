import Foundation

/// What the export UI (top-bar ring, popover status line) draws from.
struct ExportQueueState: Equatable {
    struct Current: Equatable {
        var presetID: UUID
        var presetName: String
        var stage: ExportStage
        /// Progress within `stage`, 0...1.
        var stageFraction: Double
        /// Progress across the whole run, 0...1 (drives the ring).
        var fraction: Double
        /// True once Cancel was requested and the stage is winding down.
        var isCancelling: Bool
    }

    struct Waiting: Equatable, Identifiable {
        var id: UUID
        var presetID: UUID
        var presetName: String
    }

    var current: Current?
    var waiting: [Waiting] = []
    /// The most recent run to finish (success, failure or cancel).
    var lastResult: ExportRunResult?

    var isBusy: Bool { current != nil }
    var queuedCount: Int { waiting.count }
}

/// Serial export queue for one editor. Triggering a preset while another is
/// running queues it; runs execute one at a time in order.
///
/// The queue keeps itself alive while it has work, so closing the editor
/// window does not drop queued exports (the running one is also held by
/// `MediaExportCoordinator`).
@MainActor
final class ExportQueue {
    private struct Item {
        let id: UUID
        let preset: ExportPreset
        let overrides: ExportOverrides
    }

    private let environment: ExportEnvironment
    /// Builds the run for an item. Tests substitute their own.
    private let makeRun: @MainActor (ExportPreset, ExportOverrides, ExportEnvironment) -> ExportRun
    private var pending: [Item] = []
    private var currentRun: ExportRun?
    private var isCancelling = false
    private var observers: [UUID: (ExportQueueState) -> Void] = [:]
    private var keepAlive: ExportQueue?

    /// Records of this project's exports (the status line reads these).
    var records: ExportRecordStore { environment.records }
    let sync: ExportRemoteSync

    private(set) var state = ExportQueueState() {
        didSet { if state != oldValue { for handler in observers.values { handler(state) } } }
    }

    /// Called once per finished run (toasts: "Saved", "Uploaded to Stream").
    var onResult: ((ExportRunResult) -> Void)?

    init(environment: ExportEnvironment,
         makeRun: @escaping @MainActor (ExportPreset, ExportOverrides, ExportEnvironment) -> ExportRun = { ExportRun(preset: $0, overrides: $1, environment: $2) }) {
        self.environment = environment
        self.makeRun = makeRun
        sync = ExportRemoteSync(records: environment.records, remote: environment.remote,
                                clock: environment.clock, interval: environment.pollInterval)
        sync.activePresetIDs = { [weak self] in self?.currentRun.map { [$0.presetID] } ?? [] }
        sync.onChange = { [weak self] in self?.notifyRecordsChanged() }
    }

    var isBusy: Bool { state.isBusy }
    var queuedCount: Int { pending.count }

    // MARK: Observing

    /// Registers for state changes (progress, stage, queue length, results).
    /// The handler runs on the main actor; the current state is not replayed.
    @discardableResult
    func observe(_ handler: @escaping (ExportQueueState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    // MARK: Enqueueing

    /// Runs `preset` now, or queues it behind the running export. An identical
    /// request (same preset and overrides) that is already waiting is not
    /// queued twice; its ticket is returned. The ticket is the id shown in
    /// `state.waiting`.
    @discardableResult
    func enqueue(_ preset: ExportPreset, overrides: ExportOverrides = ExportOverrides()) -> UUID {
        if currentRun != nil, let existing = pending.first(where: { $0.preset.id == preset.id && $0.overrides == overrides }) {
            return existing.id
        }
        let item = Item(id: UUID(), preset: preset, overrides: overrides)
        pending.append(item)
        keepAlive = self
        publishWaiting()
        startNextIfIdle()
        return item.id
    }

    /// Removes one waiting export. The running one is untouched.
    func cancelQueued(ticket: UUID) {
        pending.removeAll { $0.id == ticket }
        publishWaiting()
    }

    /// Stops the running export at whatever stage it is in, and optionally
    /// drops everything waiting behind it. With `dropQueued` false the next
    /// queued export starts once the cancelled one has wound down.
    func cancelCurrent(dropQueued: Bool = false) {
        if dropQueued { pending.removeAll(); publishWaiting() }
        guard let run = currentRun else { return }
        isCancelling = true
        if var current = state.current { current.isCancelling = true; state.current = current }
        run.cancel()
    }

    // MARK: Popover hook

    /// Call when the export popover opens: refreshes every record still
    /// processing and retries a pending delete of a replaced Stream video.
    func refreshRemoteState() async {
        await sync.refreshAll()
    }

    // MARK: Running

    private func startNextIfIdle() {
        guard currentRun == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let run = makeRun(item.preset, item.overrides, environment)
        currentRun = run
        isCancelling = false
        state.current = ExportQueueState.Current(presetID: item.preset.id, presetName: item.preset.name, stage: .preparing,
                                                 stageFraction: 0, fraction: 0, isCancelling: false)
        publishWaiting()
        run.onProgress = { [weak self] progress in
            guard let self, var current = self.state.current else { return }
            current.stage = progress.stage
            current.stageFraction = progress.stageFraction
            current.fraction = progress.overall
            current.isCancelling = self.isCancelling
            self.state.current = current
        }
        run.onStage = { [weak self] stage in
            guard let self, var current = self.state.current else { return }
            current.stage = stage
            self.state.current = current
        }
        Task { [weak self] in
            let result = await run.run()
            self?.finish(run, result: result)
        }
    }

    private func finish(_ run: ExportRun, result: ExportRunResult) {
        guard currentRun === run else { return }
        currentRun = nil
        isCancelling = false
        state.current = nil
        state.lastResult = result
        // A Stream upload keeps processing after the run; follow it.
        sync.startPollingIfNeeded()
        onResult?(result)
        if pending.isEmpty { keepAlive = nil } else { startNextIfIdle() }
    }

    private func publishWaiting() {
        state.waiting = pending.map { .init(id: $0.id, presetID: $0.preset.id, presetName: $0.preset.name) }
    }

    /// Record changes (status polling) don't alter `state`; observers that
    /// show the status line re-read `records`, so nudge them.
    private func notifyRecordsChanged() {
        for handler in observers.values { handler(state) }
    }
}
