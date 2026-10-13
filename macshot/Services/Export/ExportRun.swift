import Foundation

/// Progress of one run, for the UI.
nonisolated struct ExportRunProgress: Sendable, Equatable {
    var stage: ExportStage
    /// 0...1 within `stage`.
    var stageFraction: Double
    /// 0...1 across the stages this run will go through.
    var overall: Double
}

/// One preset applied to one project:
///
///     render -> publish locally -> upload -> captions -> record
///
/// then (outside the run, see `ExportRemoteSync`) poll Stream until the video
/// is ready and delete the video it replaces.
///
/// The run registers with `MediaExportCoordinator`, so it outlives the editor
/// window and the quit drain waits for it. It calls `beginPublication` right
/// before the local publish; after that the coordinator can no longer cancel
/// it, so the run cancels its own pipeline task instead (`cancel()`), which is
/// what stops an upload that follows a published local copy.
///
/// Every stage that encodes or talks to the network is behind
/// `ExportEnvironment`'s protocols, so tests drive the whole run with fakes.
@MainActor
final class ExportRun {
    let id = UUID()
    let preset: ExportPreset
    let overrides: ExportOverrides
    var onStage: ((ExportStage) -> Void)?
    var onProgress: ((ExportRunProgress) -> Void)?

    private let env: ExportEnvironment
    private let effective: ExportPreset
    private(set) var stage: ExportStage?
    private(set) var progress: ExportRunProgress?
    private var result: ExportRunResult
    private var job: MediaExportCoordinator.Job?
    private var pipelineTask: Task<Void, Error>?
    private var cancelRequested = false
    private var weights: [ExportStage: Double] = [:]

    init(preset: ExportPreset, overrides: ExportOverrides = ExportOverrides(), environment: ExportEnvironment) {
        self.preset = preset
        self.overrides = overrides
        env = environment
        effective = overrides.applied(to: preset)
        result = ExportRunResult(presetID: preset.id, presetName: preset.name)
    }

    var presetID: UUID { preset.id }
    var presetName: String { preset.name }

    // MARK: Driving

    /// Runs to completion (success, failure or cancellation) and returns what
    /// happened. Never throws: failures are in the result.
    func run() async -> ExportRunResult {
        if cancelRequested { result.cancelledAt = .preparing; return result }
        return await withCheckedContinuation { continuation in
            job = env.coordinator.start(
                title: "\(env.projectName) · \(preset.name)", status: effective.name,
                operation: { [self] cancellation, report in
                    let task = Task { @MainActor in try await self.pipeline(cancellation: cancellation, report: report) }
                    pipelineTask = task
                    if cancelRequested { task.cancel() }
                    try await withTaskCancellationHandler(operation: { try await task.value },
                                                          onCancel: { task.cancel() })
                },
                completion: { [self] outcome in
                    job = nil
                    pipelineTask = nil
                    if case .failure(let error) = outcome, result.failure == nil, result.cancelledAt == nil {
                        // Failed before the pipeline recorded anything (cancelled while queued).
                        if Self.isCancellation(error) || cancelRequested { result.cancelledAt = stage ?? .preparing }
                        else { result.failure = ExportRunFailure(stage: stage ?? .preparing, message: error.localizedDescription) }
                    }
                    continuation.resume(returning: result)
                })
        }
    }

    /// Stops the stage that is running. Work already finished stays: a local
    /// copy that was published is kept, an upload that completed stays recorded.
    func cancel() {
        cancelRequested = true
        pipelineTask?.cancel()
        job?.cancel()
    }

    // MARK: Pipeline

    private struct Plan {
        var settings: VideoExportSettings
        var upload: ExportRemoteKind?
        var localFolder: URL?
        var wantsVTT: Bool
        var remote: ExportRemoteService?
    }

    private func preflight() throws -> Plan {
        let settings = effective.resolvedSettings(nativeSize: env.renderer.nativeSize)
        var upload: ExportRemoteKind?
        var localFolder: URL?
        switch effective.destination {
        case .folder:
            guard let folder = effective.destination.resolvedFolderURL() else {
                throw ExportRunError.folderUnavailable(ExportDestination.defaultArchivePath)
            }
            localFolder = folder
        case .stream: upload = .stream
        case .images: upload = .images
        }
        var remote: ExportRemoteService?
        if let upload {
            if env.offline { throw ExportRunError.networkDestinationUnavailable }
            guard let service = env.remote() else { throw ExportRunError.cloudflareNotConfigured }
            remote = service
            switch upload {
            case .stream where effective.format.isGIF:
                throw ExportRunError.formatMismatch("Stream takes video. Use an H.264 or HEVC preset, or the Loop preset for a GIF.")
            case .images where !effective.format.isGIF:
                throw ExportRunError.formatMismatch("Images takes GIFs. Use a GIF preset, or the Stream preset for video.")
            default: break
            }
            if effective.alsoSaveLocally { localFolder = env.localFolderForUploads() }
        }
        let wantsVTT = effective.captions == .soft && (upload == .stream || localFolder != nil)
        return Plan(settings: settings, upload: upload, localFolder: localFolder, wantsVTT: wantsVTT, remote: remote)
    }

    private func pipeline(cancellation: MediaExportCancellation, report: @escaping @Sendable (Double) -> Void) async throws {
        var staging: URL?
        var retained: ExportRenderOutput?
        defer {
            if let staging { Self.discard(staging) }
            withExtendedLifetime(retained) {}
        }
        do {
            enter(.preparing, report: report)
            try checkCancelled(cancellation)
            let plan = try preflight()
            configureWeights(plan)

            let directory = env.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            staging = directory
            let base = Self.fileBase(env.projectName)

            // Soft captions: the WebVTT is taken now, from the same project
            // state the render sees.
            var vttURL: URL?
            if plan.wantsVTT, let vtt = env.renderer.captionsVTT() {
                let url = directory.appendingPathComponent(base + ".vtt")
                try Data(vtt.utf8).write(to: url)
                vttURL = url
            }

            // Render
            enter(.rendering, report: report)
            try checkCancelled(cancellation)
            let ext = plan.settings.format == .gif ? "gif" : "mp4"
            let request = ExportRenderRequest(settings: plan.settings,
                                              outputURL: directory.appendingPathComponent(base + "." + ext),
                                              fitGIF: effective.format.isGIF && effective.destination == .images)
            let output = try await env.renderer.render(request, progress: stageProgress(.rendering, report: report))
            retained = output
            try checkCancelled(cancellation)
            result.fitSummary = output.fitSummary
            let rendered = output.fileURL

            // Publish locally
            if let folder = plan.localFolder {
                enter(.publishing, report: report)
                try await publishLocally(rendered, vtt: vttURL, folder: folder, base: base, cancellation: cancellation)
            } else if let summary = output.fitSummary {
                env.records.update(preset.id) { $0.fitSummary = summary }
            }

            // Upload (always from the staged/rendered file, not the published copy)
            if let kind = plan.upload, let remote = plan.remote {
                enter(.uploading, report: report)
                try checkCancelled(cancellation)
                try await upload(kind, file: rendered, remote: remote, report: report)
                if kind == .stream, let vttURL, let uid = result.remoteID {
                    enter(.captions, report: report)
                    try await uploadCaptions(uid: uid, vtt: vttURL, remote: remote)
                }
            }
            finishProgress(report: report)
        } catch {
            if Self.isCancellation(error) || cancelRequested || Task.isCancelled {
                result.cancelledAt = stage ?? .preparing
                throw CancellationError()
            }
            result.failure = ExportRunFailure(stage: stage ?? .preparing, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: Local publish

    private func publishLocally(_ source: URL, vtt: URL?, folder: URL, base: String,
                                cancellation: MediaExportCancellation) async throws {
        try await MediaExportIO.perform { try ExportLocalDestination.ensureFolder(folder) }
        let choice = ExportLocalDestination.choose(folder: folder, base: base, ext: source.pathExtension,
                                                   recorded: env.records.record(for: preset.id)?.localFile)
        let destination = choice.url
        let overwrites = choice.overwrites
        try await MediaExportIO.perform {
            try cancellation.check()
            let save = try AtomicMediaSave(destinationURL: destination)
            try save.copySource(source, checkCancellation: { try cancellation.check() })
            // First (and only) publication of the run: Cancel can't report a saved file as cancelled.
            try save.commit(overwritingExisting: overwrites, beforePublish: { try cancellation.beginPublication() })
        }
        result.localFile = destination
        if let described = ExportFileRecord.describing(destination) {
            env.records.update(preset.id) { $0.localFile = described }
        }
        if let vtt {
            let sidecar = destination.deletingPathExtension().appendingPathExtension("vtt")
            try await MediaExportIO.perform {
                let save = try AtomicMediaSave(destinationURL: sidecar)
                try save.copySource(vtt)
                try save.commit(overwritingExisting: true)
            }
            result.captionsSidecar = sidecar
        }
    }

    // MARK: Upload

    private func upload(_ kind: ExportRemoteKind, file: URL, remote: ExportRemoteService,
                        report: @escaping @Sendable (Double) -> Void) async throws {
        let before = env.records.record(for: preset.id)
        env.records.update(preset.id) { $0.state = .uploading; $0.errorText = nil }
        let progress = stageProgress(.uploading, report: report)
        let remoteID: String
        do {
            switch kind {
            case .stream:
                remoteID = try await remote.uploadStream(fileURL: file, name: env.projectName,
                                                         requireSignedURLs: effective.requireSignedURLs, progress: progress)
            case .images:
                remoteID = try await remote.uploadImage(fileURL: file, name: env.projectName, progress: progress)
            }
        } catch {
            if Self.isCancellation(error) || cancelRequested || Task.isCancelled {
                // Cancelled upload: whatever was there before is still what exists.
                env.records.update(preset.id) { $0.state = before?.state; $0.errorText = before?.errorText }
                throw CancellationError()
            }
            env.records.update(preset.id) { $0.state = .failed; $0.errorText = error.localizedDescription }
            throw error
        }
        let now = env.now()
        env.records.update(preset.id) { record in
            if kind == .stream, record.remoteKind == .stream, let previous = record.remoteID, previous != remoteID,
               !record.pendingDeleteUIDs.contains(previous) {
                // Replaced only once the new video is ready (`ExportRemoteSync`).
                record.pendingDeleteUIDs.append(previous)
            }
            record.remoteKind = kind
            record.remoteID = remoteID
            record.uploadedAt = now
            record.state = kind == .stream ? .processing : .ready
            record.errorText = nil
            record.captionsLanguage = nil
        }
        result.remoteKind = kind
        result.remoteID = remoteID
    }

    /// A missing caption track doesn't fail an upload that already succeeded.
    private func uploadCaptions(uid: String, vtt: URL, remote: ExportRemoteService) async throws {
        let language = env.captionsLanguage
        do {
            try await remote.putCaptions(uid: uid, language: language, vttFileURL: vtt)
            env.records.update(preset.id) { $0.captionsLanguage = language }
        } catch {
            if Self.isCancellation(error) || cancelRequested || Task.isCancelled { throw CancellationError() }
            result.captionsError = error.localizedDescription
        }
    }

    // MARK: Progress

    private func configureWeights(_ plan: Plan) {
        var raw: [ExportStage: Double] = [.rendering: 0.55]
        if plan.localFolder != nil { raw[.publishing] = 0.10 }
        if plan.upload != nil { raw[.uploading] = 0.30 }
        if plan.upload == .stream && plan.wantsVTT { raw[.captions] = 0.05 }
        let total = raw.values.reduce(0, +)
        weights = raw.mapValues { $0 / total }
    }

    private func offset(of stage: ExportStage) -> Double {
        let order: [ExportStage] = [.rendering, .publishing, .uploading, .captions]
        guard let index = order.firstIndex(of: stage) else { return 0 }
        return order[..<index].reduce(0) { $0 + (weights[$1] ?? 0) }
    }

    private func enter(_ new: ExportStage, report: @Sendable (Double) -> Void) {
        stage = new
        emit(stage: new, fraction: 0, report: report)
        onStage?(new)
    }

    private func emit(stage: ExportStage, fraction: Double, report: @Sendable (Double) -> Void) {
        let clamped = max(0, min(1, fraction.isFinite ? fraction : 0))
        // Callbacks hop threads, so a stale one can land after a newer value.
        if let current = progress, current.stage == stage, clamped < current.stageFraction { return }
        let overall = min(1, offset(of: stage) + (weights[stage] ?? 0) * clamped)
        let value = ExportRunProgress(stage: stage, stageFraction: clamped, overall: overall)
        progress = value
        report(overall)
        onProgress?(value)
    }

    private func finishProgress(report: @Sendable (Double) -> Void) {
        guard let stage else { return }
        emit(stage: stage, fraction: 1, report: report)
    }

    /// A progress callback for `stage`, safe to call from any thread. Late
    /// callbacks from a finished stage are dropped.
    private func stageProgress(_ stage: ExportStage, report: @escaping @Sendable (Double) -> Void) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.stage == stage else { return }
                    self.emit(stage: stage, fraction: fraction, report: report)
                }
            }
        }
    }

    // MARK: Helpers

    private func checkCancelled(_ cancellation: MediaExportCancellation) throws {
        if cancelRequested { throw CancellationError() }
        try Task.checkCancellation()
        try cancellation.check()
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// The local file name (without extension) for a project.
    nonisolated static func fileBase(_ projectName: String) -> String {
        let cleaned = FilenameSanitizer.sanitize(projectName).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Export" : cleaned
    }

    /// Removes the staging folder (may hold a multi-GB render) off the main thread.
    private nonisolated static func discard(_ directory: URL) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
    }
}
