import AppKit

/// What the user hears about an export, as plain values so the wording is
/// testable without a toast on screen.
struct ExportToastContent: Equatable {
    enum Kind: Equatable { case saved(URL), notice, failure }

    var kind: Kind
    var title: String
    var detail: String
    /// Set for uploads: where "Open in dashboard" goes.
    var dashboardURL: URL?

    /// The toast for a finished run, or nil when none is due (cancelled).
    static func forResult(_ result: ExportRunResult, projectName: String, accountID: String?) -> ExportToastContent? {
        if let failure = result.failure {
            return ExportToastContent(kind: .failure, title: L("Export failed"),
                                      detail: String(format: L("Export failed: %@"), failure.message), dashboardURL: nil)
        }
        if result.wasCancelled { return nil }
        if let kind = result.remoteKind {
            var detail = [projectName]
            if let fit = result.fitSummary { detail.append(fit) }
            if let captions = result.captionsError {
                detail.append(String(format: L("Captions weren't added: %@"), captions))
            }
            let title = kind == .stream ? L("Uploaded to Stream") : L("Uploaded to Images")
            return ExportToastContent(
                kind: .notice, title: title, detail: detail.joined(separator: " · "),
                dashboardURL: ExportStatusLine.dashboardURL(kind: kind, remoteID: result.remoteID, accountID: accountID))
        }
        if let file = result.localFile {
            return ExportToastContent(kind: .saved(file), title: L("Saved"), detail: file.lastPathComponent, dashboardURL: nil)
        }
        return nil
    }

    /// "Ready" for a Stream upload that finished processing after its run.
    static func ready(projectName: String, presetName: String, dashboardURL: URL?) -> ExportToastContent {
        ExportToastContent(kind: .notice, title: L("Ready to stream"),
                           detail: projectName + " · " + presetName, dashboardURL: dashboardURL)
    }
}

/// Shows the export toasts for one editor's queue, independent of the editor
/// window: an export outlives its window, and so does the toast. It is retained
/// by the queue (as an observer), not by the window.
@MainActor
final class ExportCompletionNotifier {
    private var watcher = ExportProcessingWatcher()
    private let projectName: String
    private weak var queue: ExportQueue?

    /// Hooks `queue`'s results and Stream status changes up to the toasts.
    static func attach(to queue: ExportQueue, projectName: String) {
        let notifier = ExportCompletionNotifier(queue: queue, projectName: projectName)
        queue.onResult = { [weak notifier] result in notifier?.present(result) }
        // The queue's observer table keeps the notifier alive.
        queue.observe { _ in notifier.recordsMayHaveChanged() }
    }

    private init(queue: ExportQueue, projectName: String) {
        self.queue = queue
        self.projectName = projectName
        watcher.prime(queue.records.records)
    }

    func present(_ result: ExportRunResult) {
        guard let content = ExportToastContent.forResult(result, projectName: projectName,
                                                         accountID: ExportCloudflareSupport.accountID) else { return }
        show(content)
    }

    func recordsMayHaveChanged() {
        guard let queue else { return }
        for event in watcher.events(for: queue.records.records) {
            switch event {
            case .ready(let key):
                let record = queue.records.record(forKey: key)
                let name = UUID(uuidString: key).flatMap { ExportPresetStore.preset(id: $0)?.name } ?? ""
                let url = ExportStatusLine.dashboardURL(kind: record?.remoteKind, remoteID: record?.remoteID,
                                                        accountID: ExportCloudflareSupport.accountID)
                show(.ready(projectName: projectName, presetName: name, dashboardURL: url))
            case .failed(_, let message):
                let content = ExportToastContent(
                    kind: .failure, title: L("Export failed"),
                    detail: String(format: L("Stream couldn't process the video: %@"), message), dashboardURL: nil)
                show(content)
            }
        }
    }

    private func show(_ content: ExportToastContent) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        switch content.kind {
        case .failure:
            delegate.showFailureToast(content.detail)
        case .saved(let url):
            delegate.showExportNoticeToast(title: content.title, detail: content.detail, actionTitle: L("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .notice:
            if let url = content.dashboardURL {
                delegate.showExportNoticeToast(title: content.title, detail: content.detail,
                                               actionTitle: L("Open in dashboard")) { NSWorkspace.shared.open(url) }
            } else {
                delegate.showExportNoticeToast(title: content.title, detail: content.detail)
            }
        }
    }
}
