// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Theme

enum Theme {
    /// Brand magenta, used only as an accent (selection, primary action).
    static let accent = NSColor(srgbRed: 0.980, green: 0.024, blue: 0.557, alpha: 1)  // #FA068E

    static func white(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    static func drawCentered(_ img: NSImage?, in rect: NSRect) {
        guard let img else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    static func sectionLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: white(0.45),
            .kern: 1.3,
        ])
        return f
    }

    /// Translucent dark window background.
    static func glassBackground() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    /// Rounded tile used by the buttons. Selected tiles are lighter, with an accent outline.
    static func drawTile(_ rect: NSRect, radius: CGFloat, selected: Bool, hovering: Bool, pressing: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        white(selected ? 0.16 : pressing ? 0.14 : hovering ? 0.09 : 0.045).setFill()
        path.fill()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
        edge.lineWidth = selected ? 1.5 : 1
        (selected ? accent : white(hovering ? 0.13 : 0.07)).setStroke()
        edge.stroke()
    }

    /// Pixel mosaic, used as the Blur tool icon.
    static func drawMosaicIcon(in rect: NSRect, color: NSColor) {
        let n = 4
        let cell: CGFloat = 4.5, gap: CGFloat = 1
        let size = CGFloat(n) * cell + CGFloat(n - 1) * gap
        let origin = NSPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        let alphas: [[CGFloat]] = [
            [1.0, 0.45, 0.8, 0.3],
            [0.35, 0.9, 0.25, 0.7],
            [0.8, 0.3, 1.0, 0.45],
            [0.25, 0.7, 0.4, 0.95],
        ]
        for row in 0..<n {
            for col in 0..<n {
                let r = NSRect(x: origin.x + CGFloat(col) * (cell + gap), y: origin.y + CGFloat(row) * (cell + gap),
                               width: cell, height: cell)
                color.withAlphaComponent(alphas[row][col] * color.alphaComponent).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.2, yRadius: 1.2).fill()
            }
        }
    }
}

// MARK: - Controls

/// Base for the hand-drawn buttons: hover, click tracking and fixed size.
class PadControl: NSControl {
    var hovering = false { didSet { needsDisplay = true } }
    var pressing = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        var inside = true
        while let ev = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(ev.locationInWindow, from: nil))
            pressing = inside
            if ev.type == .leftMouseUp { break }
        }
        pressing = false
        if inside, let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

final class IconButton: PadControl {
    var symbol: String? { didSet { needsDisplay = true } }
    let iconSize: CGFloat
    let radius: CGFloat

    /// `symbol == nil` draws the pixel mosaic (Blur) icon.
    init(symbol: String?, size: CGFloat, iconSize: CGFloat, tooltip: String, target: AnyObject, action: Selector) {
        self.symbol = symbol
        self.iconSize = iconSize
        self.radius = size * 0.27
        super.init(size: NSSize(width: size, height: size))
        toolTip = tooltip
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.drawTile(bounds.insetBy(dx: 1, dy: 1), radius: radius, selected: isSelected, hovering: hovering, pressing: pressing)
        let c = isSelected ? NSColor.white : Theme.white(hovering ? 0.95 : 0.75)
        if let symbol {
            Theme.drawCentered(Theme.symbol(symbol, size: iconSize, color: c), in: bounds)
        } else {
            Theme.drawMosaicIcon(in: bounds, color: c)
        }
    }
}

final class ColorDot: PadControl {
    var color: NSColor { didSet { needsDisplay = true } }
    let isCustom: Bool

    init(color: NSColor, custom: Bool = false, tooltip: String, target: AnyObject, action: Selector) {
        self.color = color
        self.isCustom = custom
        super.init(size: NSSize(width: 30, height: 30))
        toolTip = tooltip
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        let inset: CGFloat = isSelected ? 5.5 : (hovering ? 3.5 : 4.5)
        let r = bounds.insetBy(dx: inset, dy: inset)
        if isCustom {
            // Color wheel; when a custom color is chosen, it shows in the middle.
            let c = NSPoint(x: r.midX, y: r.midY)
            let steps = 24
            for i in 0..<steps {
                let p = NSBezierPath()
                p.move(to: c)
                p.appendArc(withCenter: c, radius: r.width / 2,
                            startAngle: CGFloat(i) * 360 / CGFloat(steps), endAngle: CGFloat(i + 1) * 360 / CGFloat(steps) + 0.5)
                p.close()
                NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.85, brightness: 1, alpha: 1).setFill()
                p.fill()
            }
            if isSelected {
                color.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.26, dy: r.width * 0.26)).fill()
            }
        } else {
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
        }
        Theme.white(0.22).setStroke()
        let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

final class StrokeButton: PadControl {
    let previewWidth: CGFloat
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    init(previewWidth: CGFloat, tooltip: String, target: AnyObject, action: Selector) {
        self.previewWidth = previewWidth
        super.init(size: NSSize(width: 52, height: 52))
        toolTip = tooltip
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.drawTile(bounds.insetBy(dx: 1, dy: 1), radius: 14, selected: isSelected, hovering: hovering, pressing: pressing)
        // Sample "S" stroke with the current width and color.
        let s = NSBezierPath()
        s.move(to: NSPoint(x: 13, y: 17))
        s.curve(to: NSPoint(x: 39, y: 35), controlPoint1: NSPoint(x: 22, y: 40), controlPoint2: NSPoint(x: 30, y: 10))
        s.lineWidth = previewWidth
        s.lineCapStyle = .round
        (luminance(color) > 0.18 ? color : Theme.white(0.85)).setStroke()
        s.stroke()
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 1 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}

final class PillButton: PadControl {
    let title: String
    let symbol: String
    let hint: String
    let primary: Bool
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let hintFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(title: String, symbol: String, hint: String, primary: Bool, target: AnyObject, action: Selector) {
        self.title = title
        self.symbol = symbol
        self.hint = hint
        self.primary = primary
        let tw = (title as NSString).size(withAttributes: [.font: Self.font]).width
        let hw = (hint as NSString).size(withAttributes: [.font: Self.hintFont]).width
        super.init(size: NSSize(width: ceil(18 + 16 + 7 + tw + (hint.isEmpty ? 0 : 8 + hw) + 18), height: 38))
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if primary {
            Theme.accent.setFill()
            path.fill()
            if pressing { NSColor.black.withAlphaComponent(0.18).setFill(); path.fill() }
            else if hovering { Theme.white(0.1).setFill(); path.fill() }
        } else {
            Theme.white(pressing ? 0.16 : hovering ? 0.12 : 0.07).setFill()
            path.fill()
            Theme.white(0.12).setStroke()
            let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2 - 0.5, yRadius: r.height / 2 - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        }

        var x: CGFloat = 18
        if let icon = Theme.symbol(symbol, size: 13, weight: .semibold, color: .white) {
            icon.draw(in: NSRect(x: x, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            x += 16 + 7
        }
        let t = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
        let ts = t.size()
        t.draw(at: NSPoint(x: x, y: bounds.midY - ts.height / 2))
        x += ts.width + 8
        let h = NSAttributedString(string: hint, attributes: [.font: Self.hintFont, .foregroundColor: Theme.white(primary ? 0.75 : 0.45)])
        let hs = h.size()
        h.draw(at: NSPoint(x: x, y: bounds.midY - hs.height / 2))
    }
}

/// Subtle panel on top of the translucent background.
final class PanelView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.white(0.05).cgColor
        layer?.borderColor = Theme.white(0.08).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }

    func embed(_ content: NSView, insets: NSEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}
