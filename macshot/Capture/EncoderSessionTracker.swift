import AVFoundation

/// Test-only bookkeeping of encoder sessions, so the suite can assert that no
/// test leaves an `AVAssetWriter` or `AVAssetExportSession` mid-encode. A
/// hardware session orphaned that way kept timing out frames in
/// `VTEncoderXPCService` and preceded a kernel panic
/// (docs/feedback/2026-10-13-ave-dart-panic.md).
///
/// Inactive outside XCTest: `track` returns immediately, so the app never
/// retains writers here. Under XCTest the tracker holds strong references
/// until a check sees the session in a terminal (or never-started) state.
nonisolated enum EncoderSessionTracker {
    static let isEnabled = NSClassFromString("XCTestCase") != nil

    private static let lock = NSLock()
    nonisolated(unsafe) private static var writers: [(AVAssetWriter, String)] = []
    nonisolated(unsafe) private static var exports: [(AVAssetExportSession, String)] = []

    static func track(_ writer: AVAssetWriter, _ label: String) {
        guard isEnabled else { return }
        lock.withLock { writers.append((writer, label)) }
    }

    static func track(_ session: AVAssetExportSession, _ label: String) {
        guard isEnabled else { return }
        lock.withLock { exports.append((session, label)) }
    }

    /// Descriptions of sessions still encoding. Sessions that finished,
    /// failed, were cancelled or never started are forgotten.
    static func inFlight() -> [String] {
        lock.withLock {
            writers.removeAll { $0.0.status != .writing }
            exports.removeAll { ![.waiting, .exporting].contains($0.0.status) }
            return writers.map { "AVAssetWriter (\($0.1)) still writing to \($0.0.outputURL.lastPathComponent)" }
                + exports.map { "AVAssetExportSession (\($0.1)) still exporting" }
        }
    }
}
