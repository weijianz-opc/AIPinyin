import AppKit

/// Borderless, non-activating floating panel shown under the insertion point.
final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()

    /// The input controller currently showing the panel.
    weak var owner: AnyObject?
    let view = CandidateView()

    var onSelect: ((Int) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }

    /// The scroll wheel or trackpad over the panel: rows to move (down is positive).
    var onScroll: ((Int) -> Void)? {
        get { view.onScroll }
        set { view.onScroll = newValue }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        // Just below the cursor level: stays above full-screen apps and popup menus.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 100)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ model: CandidateView.Model, anchor: NSRect) {
        view.model = model
        let size = view.contentSize
        setFrame(NSRect(origin: Self.origin(for: size, anchor: anchor), size: size), display: true)
        if !isVisible { orderFrontRegardless() }
        invalidateShadow()
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }

    /// Places the panel's top-left just below the line rect, flipping above when there is no room,
    /// and keeps it on the anchor's screen.
    static func origin(for size: NSSize, anchor rawAnchor: NSRect) -> NSPoint {
        var anchor = rawAnchor
        // Some clients report an empty rect at the origin; fall back to the mouse position.
        if anchor.origin == .zero || !anchor.origin.x.isFinite || !anchor.origin.y.isFinite {
            let mouse = NSEvent.mouseLocation
            anchor = NSRect(x: mouse.x, y: mouse.y - 18, width: 0, height: 18)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 4
        var x = anchor.minX - CandidateView.Metrics.textInsetX
        var y = anchor.minY - gap - size.height
        if y < visible.minY { y = anchor.maxY + gap }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

/// Draws the candidate list. Layout is computed when the model changes; drawing is appearance-aware.
final class CandidateView: NSView {
    struct Row: Equatable {
        enum Style: Equatable {
            /// Level-one pinyin candidate.
            case candidate
            /// The sentence as typed (level two, row 0).
            case original
            /// A version or rewrite from the model (level two).
            case translation
        }

        var label: String
        var text: String
        var comment: String = ""
        var style: Style
        var isComplete: Bool = true
        /// A symbol in a colored rounded square before the text, like the icons of iOS Settings.
        var icon: Icon? = nil
    }

    /// An SF Symbol, drawn white on `color`.
    struct Icon: Equatable {
        var symbol: String
        var color: NSColor
    }

    enum Status: Equatable {
        case none
        case loading(String)
        case hint(String)
        case error(String)
    }

    struct Model: Equatable {
        var rows: [Row] = []
        var highlighted: Int?
        var status: Status = .none
        var footer = ""
        var detail: String?
    }

    enum Metrics {
        static let padding: CGFloat = 6
        static let rowInsetX: CGFloat = 8
        static let rowInsetY: CGFloat = 4
        static let labelGap: CGFloat = 8
        static let maxTextWidth: CGFloat = 520
        static let minWidth: CGFloat = 280
        static let cornerRadius: CGFloat = 10
        static let rowRadius: CGFloat = 6
        static let footerGap: CGFloat = 6
        static let labelWidth: CGFloat = ceil(("0" as NSString).size(withAttributes: [.font: Fonts.label]).width)
        static let iconSize: CGFloat = 20
        static let iconGap: CGFloat = 8
        /// Distance from the panel's left edge to where candidate text starts.
        static let textInsetX: CGFloat = padding + rowInsetX + labelWidth + labelGap
    }

    enum Fonts {
        static let candidate = NSFont.systemFont(ofSize: 16)
        static let english = NSFont.systemFont(ofSize: 15)
        static let chinese = NSFont.systemFont(ofSize: 14)
        static let comment = NSFont.systemFont(ofSize: 12)
        static let label = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        static let status = NSFont.systemFont(ofSize: 13)
        static let footer = NSFont.systemFont(ofSize: 11)

        static func text(for style: Row.Style) -> NSFont {
            switch style {
            case .candidate: return candidate
            case .original: return chinese
            case .translation: return english
            }
        }
    }

    static let background = NSColor(name: "AllInOneIMEPanelBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 0.98) : NSColor(white: 0.995, alpha: 0.98)
    }

    private struct RowLayout {
        var frame: NSRect
        var textFrame: NSRect
        var labelOrigin: NSPoint
        var iconFrame: NSRect?
    }

    var model = Model() {
        didSet { if model != oldValue { relayout() } }
    }

    var onSelect: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    /// Scrolling not yet a whole row (a trackpad's small steps add up).
    private var pendingScroll: CGFloat = 0
    private(set) var contentSize = NSSize(width: Metrics.minWidth, height: 40)
    private var rowLayouts: [RowLayout] = []
    private var statusFrame: NSRect?
    private var footerY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    private func relayout() {
        let p = Metrics.padding
        var y = p
        var widest: CGFloat = 0
        rowLayouts = []
        // A column for the icons when any row has one: the text moves right by it.
        let iconColumn = model.rows.contains { $0.icon != nil } ? Metrics.iconSize + Metrics.iconGap : 0
        for row in model.rows {
            let (_, text) = strings(for: row, highlighted: false)
            let font = Fonts.text(for: row.style)
            let size = Self.measure(text, minHeight: max(ceil(font.ascender - font.descender + font.leading),
                                                          iconColumn > 0 ? Metrics.iconSize : 0))
            widest = max(widest, size.width + iconColumn)
            // Drawn at the width it was measured at: laid out only as wide as its longest line, the
            // text can wrap once more and lose its last line.
            // One line next to an icon is centered on it.
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let textY = y + Metrics.rowInsetY + (iconColumn > 0 && size.height <= Metrics.iconSize ? (Metrics.iconSize - lineHeight) / 2 : 0)
            let textFrame = NSRect(x: Metrics.textInsetX + iconColumn, y: textY, width: Metrics.maxTextWidth, height: size.height)
            let labelOrigin = NSPoint(
                x: p + Metrics.rowInsetX,
                y: textFrame.minY + (font.ascender - Fonts.label.ascender))
            let iconFrame = row.icon.map { _ in
                NSRect(x: Metrics.textInsetX, y: y + Metrics.rowInsetY, width: Metrics.iconSize, height: Metrics.iconSize)
            }
            rowLayouts.append(RowLayout(
                frame: NSRect(x: p, y: y, width: 0, height: size.height + 2 * Metrics.rowInsetY),
                textFrame: textFrame, labelOrigin: labelOrigin, iconFrame: iconFrame))
            y += size.height + 2 * Metrics.rowInsetY
        }

        statusFrame = nil
        let compact = model.rows.isEmpty && model.footer.isEmpty
        let statusX = model.rows.isEmpty ? p + Metrics.rowInsetX : Metrics.textInsetX
        if let status = statusString() {
            let size = Self.measure(status, minHeight: 0)
            widest = max(widest, size.width + statusX - Metrics.textInsetX)
            statusFrame = NSRect(x: statusX, y: y + Metrics.rowInsetY, width: Metrics.maxTextWidth, height: size.height)
            y += size.height + 2 * Metrics.rowInsetY
        }

        var width = max(compact ? 0 : Metrics.minWidth, Metrics.textInsetX + widest + Metrics.rowInsetX + p)
        if !model.footer.isEmpty {
            let footer = footerStrings()
            let footerWidth = footer.left.size().width + (footer.right.map { $0.size().width + 16 } ?? 0)
            width = max(width, ceil(footerWidth) + 2 * (p + Metrics.rowInsetX))
            footerY = y + Metrics.footerGap
            y = footerY + 1 + Metrics.footerGap + ceil(footer.left.size().height)
        }
        for i in rowLayouts.indices {
            rowLayouts[i].frame.size.width = width - 2 * p
        }
        contentSize = NSSize(width: ceil(width), height: ceil(y + p))
        needsDisplay = true
    }

    private static func measure(_ text: NSAttributedString, minHeight: CGFloat) -> NSSize {
        let rect = text.boundingRect(
            with: NSSize(width: Metrics.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(rect.width), height: max(ceil(rect.height), minHeight))
    }

    // MARK: - Strings

    private func strings(for row: Row, highlighted: Bool) -> (NSAttributedString, NSAttributedString) {
        let primary: NSColor = highlighted ? .white : (row.style == .original ? .secondaryLabelColor : .labelColor)
        let secondary: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        let font = Fonts.text(for: row.style)
        let label = NSAttributedString(string: row.label, attributes: [.font: Fonts.label, .foregroundColor: secondary])
        let text = NSMutableAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: primary])
        if !row.isComplete {
            let caret: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.6) : .tertiaryLabelColor
            text.append(NSAttributedString(string: row.text.isEmpty ? "▍" : " ▍", attributes: [.font: font, .foregroundColor: caret]))
        }
        if !row.comment.isEmpty {
            let color: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
            // No-break spaces and word joiners: when the line wraps, the comment ("黑话", jargon) moves as one
            // piece together with the last word instead of breaking between its characters.
            let glued = "\u{00A0}\u{00A0}" + row.comment.map(String.init).joined(separator: "\u{2060}")
            text.append(NSAttributedString(string: glued, attributes: [.font: Fonts.comment, .foregroundColor: color]))
        }
        return (label, text)
    }

    private func statusString() -> NSAttributedString? {
        switch model.status {
        case .none:
            return nil
        case let .loading(text):
            return NSAttributedString(string: text, attributes: [
                .font: Fonts.status, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        case let .hint(text):
            return NSAttributedString(string: text, attributes: [
                .font: Fonts.status, .foregroundColor: NSColor.labelColor,
            ])
        case let .error(message):
            return NSAttributedString(string: "⚠︎ \(message)", attributes: [
                .font: Fonts.status, .foregroundColor: NSColor.systemRed,
            ])
        }
    }

    private func footerStrings() -> (left: NSAttributedString, right: NSAttributedString?) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Fonts.footer, .foregroundColor: NSColor.tertiaryLabelColor]
        return (
            NSAttributedString(string: model.footer, attributes: attributes),
            model.detail.map { NSAttributedString(string: $0, attributes: attributes) })
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        Self.background.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        for (index, layout) in rowLayouts.enumerated() where index < model.rows.count {
            let highlighted = index == model.highlighted
            if highlighted {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: layout.frame, xRadius: Metrics.rowRadius, yRadius: Metrics.rowRadius).fill()
            }
            let (label, text) = strings(for: model.rows[index], highlighted: highlighted)
            label.draw(at: layout.labelOrigin)
            if let icon = model.rows[index].icon, let frame = layout.iconFrame { Self.draw(icon, in: frame) }
            text.draw(with: layout.textFrame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        if let statusFrame, let status = statusString() {
            status.draw(with: statusFrame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        if !model.footer.isEmpty {
            let inset = Metrics.padding + Metrics.rowInsetX
            NSColor.separatorColor.setFill()
            NSRect(x: inset, y: footerY, width: bounds.width - 2 * inset, height: 1).fill()
            let footer = footerStrings()
            let textY = footerY + 1 + Metrics.footerGap
            footer.left.draw(at: NSPoint(x: inset, y: textY))
            if let right = footer.right {
                right.draw(at: NSPoint(x: bounds.width - inset - right.size().width, y: textY))
            }
        }
    }

    /// A white symbol on a colored rounded square (a missing symbol: a generic one).
    static func draw(_ icon: Icon, in frame: NSRect) {
        icon.color.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.width * 0.24, yRadius: frame.height * 0.24).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: frame.height * 0.55, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = (NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)
                           ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }

    // MARK: - Mouse

    override func scrollWheel(with event: NSEvent) {
        // A row per notch of a wheel; a trackpad adds up its small steps (about a row per 24 points).
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24 : event.scrollingDeltaY
        pendingScroll -= delta  // content up = further down the list
        let rows = Int(pendingScroll.rounded(.towardZero))
        guard rows != 0 else { return }
        pendingScroll -= CGFloat(rows)
        onScroll?(rows)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = rowLayouts.firstIndex(where: { $0.frame.contains(point) }) {
            onSelect?(index)
        }
    }
}
