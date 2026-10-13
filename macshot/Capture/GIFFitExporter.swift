import Foundation

/// One failed attempt: the rung that was tried and how far it got.
struct GIFFitAttempt: Sendable, Equatable {
    let rung: GIFFitRung
    /// Bytes written when the size budget tripped.
    let bytesWritten: Int64
}

enum GIFFitError: LocalizedError {
    /// No rung produced a GIF within the budget (or none passed the pixel
    /// budget, in which case `attempts` is empty). Suggest the Stream preset.
    case cannotFit(attempts: [GIFFitAttempt], budget: GIFFitBudget)

    nonisolated var errorDescription: String? {
        switch self {
        case .cannotFit(_, let budget):
            let limit = ByteCountFormatter.string(fromByteCount: budget.maxBytes, countStyle: .file)
            let floor = budget.fpsLadder.min().map { "\($0) fps at \(budget.minLongEdge) px" } ?? "the smallest size"
            return "This recording is too long or detailed to fit a GIF under \(limit), even at \(floor). "
                + "Use the Stream (video) preset instead."
        }
    }
}

/// Runs GIF exports down a `GIFFitPlanner` plan until one fits the byte budget.
///
/// Each attempt is a normal `GIFExporter` export straight to `destination`
/// with `maxBytes` set. An over-budget attempt aborts as soon as the file
/// exceeds the limit and (per `GIFExporter`/`AtomicMediaSave`) leaves nothing
/// published and any existing destination untouched, so failed attempts need no
/// cleanup and only the winner is ever published. One `MediaExportCancellation`
/// serves every attempt: a failed attempt never calls `beginPublication`, and
/// the winner's publication ends the run.
enum GIFFitExporter {
    struct Outcome: Sendable, Equatable {
        /// The settings that fit.
        let rung: GIFFitRung
        /// 1-based position of the winning attempt (1 means nothing changed).
        let attempt: Int
        let fileURL: URL
        let fileSize: Int64
        /// Earlier attempts that were over budget.
        let failedAttempts: [GIFFitAttempt]
    }

    struct Progress: Sendable, Equatable {
        /// 0-based index of the running attempt.
        let attemptIndex: Int
        let attemptCount: Int
        let rung: GIFFitRung
        /// Progress of this attempt, 0...1.
        let fraction: Double
    }

    /// `makeRequest` builds the export for a rung writing to the given URL
    /// (composition building lives in `VideoEditorExporter`); it is called once
    /// per attempt and the runner sets `maxBytes` on the result.
    nonisolated static func run(plan: [GIFFitRung], budget: GIFFitBudget = .cloudflareImages, destination: URL,
                                makeRequest: @Sendable (GIFFitRung, URL) async throws -> GIFExporter.Request,
                                cancellation: MediaExportCancellation = MediaExportCancellation(),
                                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        var failed: [GIFFitAttempt] = []
        for (index, rung) in plan.enumerated() {
            try Task.checkCancellation()
            try cancellation.check()
            var request = try await makeRequest(rung, destination)
            request.maxBytes = budget.maxBytes
            do {
                try await GIFExporter.export(request, cancellation: cancellation) { fraction in
                    progress(Progress(attemptIndex: index, attemptCount: plan.count, rung: rung, fraction: fraction))
                }
            } catch GIFEncoder.EncodingError.overByteBudget(let bytes) {
                failed.append(GIFFitAttempt(rung: rung, bytesWritten: bytes))
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            return Outcome(rung: rung, attempt: index + 1, fileURL: destination, fileSize: size, failedAttempts: failed)
        }
        throw GIFFitError.cannotFit(attempts: failed, budget: budget)
    }
}
