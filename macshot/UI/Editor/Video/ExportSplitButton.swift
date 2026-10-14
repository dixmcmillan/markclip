import AppKit

/// The top bar's Export control: a main segment that runs the last-used
/// preset and a chevron segment that opens the export popover. While an
/// export runs, a progress ring is drawn around the main segment's glyph.
final class ExportSplitButton: NSView {
    let mainButton: VideoPillButton
    let menuButton: VideoPillButton
    private let divider = NSView()
    private var lastUsedName: String?
    private var queueState = ExportQueueState()
    private var legacyBusy = false

    init(target: AnyObject, runAction: Selector, menuAction: Selector) {
        mainButton = VideoPillButton(title: L("Export"), symbol: "square.and.arrow.up", target: target, action: runAction)
        menuButton = VideoPillButton(title: "", symbol: "chevron.down", target: target, action: menuAction)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The segments draw only hover highlights; the pill itself is ours.
        mainButton.fill = .clear
        menuButton.fill = .clear
        mainButton.textColor = .white
        menuButton.textColor = .white
        menuButton.toolTip = L("Export options")
        menuButton.setAccessibilityLabel(L("Export options"))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [mainButton, divider, menuButton] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            mainButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainButton.topAnchor.constraint(equalTo: topAnchor),
            mainButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            menuButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 30),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = VideoEditorStyle.accentFill
        (isEnabled ? color : color.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    /// False while the old Save path is writing a file.
    var isEnabled: Bool {
        get { mainButton.isEnabled }
        set {
            mainButton.isEnabled = newValue
            menuButton.isEnabled = newValue
            needsDisplay = true
        }
    }

    /// The preset the main segment runs, for the tooltip.
    func setLastUsed(name: String?) {
        lastUsedName = name
        refreshAppearance()
    }

    func apply(_ state: ExportQueueState) {
        queueState = state
        refreshAppearance()
    }

    /// Ring progress for tests and probes: nil when idle.
    var ringFraction: Double? { queueState.current.map { max(0, min(1, $0.fraction)) } }

    private func refreshAppearance() {
        let waiting = queueState.queuedCount
        if let current = queueState.current {
            let fraction = max(0, min(1, current.fraction.isFinite ? current.fraction : 0))
            mainButton.customImage = Self.ringImage(fraction: fraction)
            let percent = Int((fraction * 100).rounded())
            let description = current.isCancelling
                ? L("Cancelling…")
                : String(format: L("Exporting %@… %d%%"), current.presetName, percent)
            mainButton.toolTip = description + (waiting > 0 ? " · " + String(format: L("%d queued"), waiting) : "")
            mainButton.setAccessibilityLabel(mainButton.toolTip)
        } else {
            mainButton.customImage = nil
            if let lastUsedName {
                mainButton.toolTip = String(format: L("Export with %@ (⇧⌘E)"), lastUsedName)
            } else {
                mainButton.toolTip = L("Export (⇧⌘E)")
            }
            mainButton.setAccessibilityLabel(mainButton.toolTip)
        }
        mainButton.title = waiting > 0 ? String(format: L("Export +%d"), waiting) : L("Export")
    }

    /// The export glyph inside a progress ring. `fraction` is 0...1; the arc
    /// starts at 12 o'clock and runs clockwise.
    static func ringImage(fraction: Double, side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if let glyph = VideoEditorStyle.symbol("square.and.arrow.up", size: 9, weight: .semibold) {
                let size = glyph.size
                let glyphRect = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5,
                                       width: size.width, height: size.height)
                glyph.draw(in: glyphRect)
                NSColor.white.set()
                glyphRect.fill(using: .sourceIn)
            }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = side / 2 - 1.3
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor(white: 1, alpha: 0.32).setStroke()
            track.stroke()
            let shown = max(0.04, min(1, fraction))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * shown, clockwise: true)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            NSColor.white.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
