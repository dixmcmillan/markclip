// Used by probe-export-popover.sh. Compiles the real export popover, split
// button, model, queue and PopoverHelper from macshot/ into a tiny app with a
// fake top bar. Nothing here renders, encodes or uploads: the "renderer" below
// only waits, and no command starts a real export.
import Cocoa

func L(_ value: String) -> String { value }

enum ToolbarLayout {
    static let defaultAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static var accentColor: NSColor { defaultAccentColor }
    static var appearance: NSAppearance { NSAppearance(named: .darkAqua)! }
}

/// Stands in for the color picker popover, which the export popover never opens.
final class ColorPickerView: NSView {
    var onColorChanged: ((NSColor) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    func setColor(_ color: NSColor, opacity: CGFloat) {}
}

/// Never writes a file; reports a little progress and waits to be cancelled.
final class WaitingRenderer: ExportRenderer {
    var nativeSize: CGSize? { CGSize(width: 3840, height: 2160) }
    func captionsVTT() -> String? { nil }
    func render(_ request: ExportRenderRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportRenderOutput {
        progress(0.42)
        while true { try await Task.sleep(nanoseconds: 50_000_000) }
    }
}

@MainActor final class ProbeApp: NSObject, NSApplicationDelegate {
    let out = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? NSTemporaryDirectory()
    var window: NSWindow!
    var split: ExportSplitButton!
    var popoverView: ExportPopoverView?
    var settingsWindow: NSWindow?
    var settingsView: ExportSettingsTabView?
    var queue: ExportQueue!
    let records = ExportRecordStore(url: nil)
    let defaults = UserDefaults(suiteName: "export-popover-probe-" + UUID().uuidString)!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 900, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VideoEditorStyle.window
        window.isReleasedWhenClosed = false
        window.title = "Export popover probe"
        split = ExportSplitButton(target: self, runAction: #selector(runLast), menuAction: #selector(openPopover))
        split.setLastUsed(name: "Archive")
        let content = NSView()
        content.addSubview(split)
        split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        split.topAnchor.constraint(equalTo: content.topAnchor, constant: 12).isActive = true
        split.heightAnchor.constraint(equalToConstant: 30).isActive = true
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let env = ExportEnvironment(projectName: "Probe", renderer: WaitingRenderer(), records: records, remote: { nil },
                                    localFolderForUploads: { URL(fileURLWithPath: NSTemporaryDirectory()) },
                                    offline: true)
        queue = ExportQueue(environment: env)
        queue.observe { [weak self] state in self?.split.apply(state) }
        if let path = ProcessInfo.processInfo.environment["PROBE_COMMANDS"] { poll(path: path) }
    }

    @objc func runLast() { print("run-last-clicked") }

    @objc func openPopover() {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let model = ExportPopoverModel(environment: .init(
            nativeSize: { CGSize(width: 3840, height: 2160) },
            outputSize: { CGSize(width: 3840 * $0.scale, height: 2160 * $0.scale) },
            estimatedBytes: { _ in 187_000_000 },
            outputDuration: { 32 },
            cloudflareConfigured: { true }, cloudflareAccountID: { "acct" }), defaults: defaults, offline: false)
        var handlers = ExportPopoverView.Handlers()
        handlers.run = { preset, _ in print("popover-run \(preset.name)"); PopoverHelper.dismiss() }
        handlers.saveAs = { preset, _ in print("popover-saveas \(preset.name)") }
        handlers.cancelCurrent = { [weak self] in self?.queue.cancelCurrent(dropQueued: false) }
        handlers.cancelQueued = { [weak self] id in self?.queue.cancelQueued(ticket: id) }
        let view = ExportPopoverView(model: model, queue: queue, records: records, handlers: handlers)
        popoverView = view
        PopoverHelper.showAutoLayout(view, relativeTo: split.bounds, of: split, preferredEdge: .minY)
    }

    private func poll(path: String) {
        var consumed = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard lines.count - 1 > consumed else { return }
                let line = lines[consumed]
                consumed += 1
                guard !line.isEmpty else { return }
                print(self.run(line))
                fflush(stdout)
            }
        }
    }

    private func run(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        let args = Array(parts.dropFirst())
        switch parts.first ?? "" {
        case "open": if !PopoverHelper.isVisible { openPopover() }; return "ok open"
        case "close": PopoverHelper.dismiss(); return "ok close"
        case "size":
            let s = PopoverHelper.activeContentSize
            return "size \(s.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none") fitting \(popoverView.map { "\(Int($0.fittingSize.width))x\(Int($0.fittingSize.height))" } ?? "none")"
        case "adjust": popoverView?.adjustToggleButton.performClick(nil); return "ok adjust \(popoverView?.isAdjustExpanded ?? false)"
        case "select":
            guard let view = popoverView, let i = Int(args.first ?? ""), view.model.presets.indices.contains(i) else { return "bad select" }
            view.model.select(view.model.presets[i].id); return "ok select \(view.model.selectedPreset.name)"
        case "busy":
            // A queue run that waits (no render, no encoding), plus one queued item.
            let folder = ExportDestination.folder(bookmark: nil, path: NSTemporaryDirectory() + "probe-out")
            queue.enqueue(ExportPreset(name: "Archive", destination: folder))
            queue.enqueue(ExportPreset(name: "Second", destination: folder))
            return "ok busy"
        case "cancel-all": queue.cancelCurrent(dropQueued: true); return "ok cancel-all"
        case "record":
            // record <ready|processing|failed> for Stream
            let state: ExportUploadState = args.first == "failed" ? .failed : (args.first == "processing" ? .processing : .ready)
            records.update(ExportPresetStore.streamID, { $0.remoteKind = .stream; $0.remoteID = "uid1"; $0.uploadedAt = Date().addingTimeInterval(-2 * 86_400); $0.state = state; $0.errorText = state == .failed ? "Couldn't reach Cloudflare" : nil })
            popoverView?.model.select(ExportPresetStore.streamID)
            return "ok record"
        case "hit":
            // hit x y: what a click at (x, y) points from the popover content's top-left reaches.
            guard let w = PopoverHelper.activeContentWindow, let content = w.contentView, let frameView = content.superview,
                  let x = Double(args.first ?? ""), args.count > 1, let y = Double(args[1]) else { return "bad hit" }
            let inContent = NSPoint(x: x, y: content.bounds.height - y)
            let v = frameView.hitTest(frameView.convert(inContent, from: content))
            return "hit \(v.map { String(describing: type(of: $0)) } ?? "nil") \((v as? NSButton).map { $0.attributedTitle.string.isEmpty ? $0.title : $0.attributedTitle.string } ?? "")"
        case "click":
            // click <title>: finds a visible control by its title and sends it a real click event.
            guard let content = PopoverHelper.activeContentWindow?.contentView, let w = PopoverHelper.activeContentWindow else { return "no popover" }
            let wanted = args.joined(separator: " ")
            func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(all) }
            guard let target = all(content).compactMap({ $0 as? NSButton }).first(where: { ($0.title == wanted || $0.attributedTitle.string.trimmingCharacters(in: .whitespaces).hasPrefix(wanted)) && !$0.isHiddenOrHasHiddenAncestor }) else { return "no button \(wanted)" }
            let center = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            let hit = w.contentView?.superview?.hitTest(w.contentView!.superview!.convert(center, from: nil))
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return "no event" }
            NSApp.postEvent(up, atStart: false)
            w.sendEvent(down)
            return "clicked \(wanted) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
        case "snapshot":
            let name = args.first ?? "popover"
            guard let content = PopoverHelper.activeContentWindow?.contentView else { return "no popover" }
            return write(content, name: name)
        case "snapshot-window":
            guard let content = window.contentView else { return "no window" }
            return write(content, name: args.first ?? "window")
        case "settings":
            // Settings > Export in a 720 x 520 window, pinned like SettingsWindowController.showTab does.
            // settings [light|dark] [offline]: the window follows the chosen system appearance.
            let view = ExportSettingsTabView(model: ExportSettingsModel(defaults: defaults, offline: args.contains("offline")))
            settingsWindow?.close()
            let w = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 720, height: 520), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = "Settings · Export"
            if args.contains("dark") { w.appearance = NSAppearance(named: .darkAqua) }
            else if args.contains("light") { w.appearance = NSAppearance(named: .aqua) }
            let container = NSView()
            w.contentView = container
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: container.topAnchor), view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                                         view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            w.makeKeyAndOrderFront(nil)
            settingsWindow = w
            settingsView = view
            return "ok settings"
        case "settings-select":
            guard let view = settingsView, let i = Int(args.first ?? ""), view.model.presets.indices.contains(i) else { return "bad select" }
            view.model.select(view.model.presets[i].id); return "ok settings-select \(view.model.selected?.name ?? "")"
        case "settings-add": _ = settingsView?.model.addPreset(); return "ok settings-add"
        case "snapshot-settings":
            guard let content = settingsWindow?.contentView else { return "no settings window" }
            return write(content, name: args.first ?? "settings")
        case "ring":
            var state = ExportQueueState()
            state.current = .init(presetID: UUID(), presetName: "Stream", stage: .uploading, stageFraction: 0.5, fraction: Double(args.first ?? "0.5") ?? 0.5, isCancelling: false)
            split.apply(state)
            return "ok ring"
        case "popover-window":
            // Which window owns the open popover, and whether it is key (the editor's keyController relies on this).
            guard let w = PopoverHelper.activeContentWindow else { return "no popover" }
            return "popover key=\(w.isKeyWindow) parent=\(w.parent === window) appKey=\(NSApp.keyWindow === w)"
        case "ring-off": split.apply(ExportQueueState()); return "ok ring-off"
        case "quit": NSApp.terminate(nil); return "bye"
        default: return "unknown \(line)"
        }
    }

    private func write(_ view: NSView, name: String) -> String {
        view.layoutSubtreeIfNeeded()
        // The popover material is the window's, not the view's, so a snapshot
        // of the view alone would be light text on nothing. Give the content a
        // dark backdrop of about that brightness for the snapshot only.
        let isSettings = view.window === settingsWindow && settingsWindow != nil
        let target = popoverView.flatMap { view.window === PopoverHelper.activeContentWindow ? $0 : nil } ?? view
        let wasLayered = target.wantsLayer
        let previous = target.layer?.backgroundColor
        target.wantsLayer = true
        var backdrop = (view.window === window ? VideoEditorStyle.window : NSColor(white: 0.2, alpha: 1)).cgColor
        if isSettings, let appearance = view.window?.effectiveAppearance {
            // The real window background for the chosen appearance, not a fixed dark.
            appearance.performAsCurrentDrawingAppearance { backdrop = NSColor.windowBackgroundColor.cgColor }
        }
        target.layer?.backgroundColor = backdrop
        defer {
            target.layer?.backgroundColor = previous
            target.wantsLayer = wasLayered
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no rep" }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return "snapshot \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))"
    }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
