// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import AVFoundation

// MARK: - Action bar shown next to a locked selection

enum ToolbarAction {
    case close
    // Video
    case sound, mic, micDevice, record
    // Screenshot
    case timer, copyText, copy, save, capture
}

struct ToolbarButton {
    let action: ToolbarAction
    let rect: NSRect          // global coordinates
    let symbol: String
    let title: String?
    let primary: Bool
    let on: Bool
    let tint: NSColor?
    /// Shows a live level meter on the right side of the button.
    let meter: Bool
}

struct ToolbarGroup {
    let title: String?
    let rect: NSRect
}

struct ToolbarLayout {
    let frame: NSRect
    let groups: [ToolbarGroup]
    let buttons: [ToolbarButton]
}

/// Options that are remembered between captures.
enum CaptureOptions {
    static let delays = [0, 3, 5, 10]
    static var delay: Int {
        get { UserDefaults.standard.integer(forKey: "captureDelay") }
        set { UserDefaults.standard.set(newValue, forKey: "captureDelay") }
    }
    static var sound: Bool {
        get { UserDefaults.standard.bool(forKey: "recordSound") }
        set { UserDefaults.standard.set(newValue, forKey: "recordSound") }
    }
    static var mic: Bool {
        get { UserDefaults.standard.bool(forKey: "recordMic") }
        set { UserDefaults.standard.set(newValue, forKey: "recordMic") }
    }
    /// `uniqueID` of the chosen microphone; nil means the system default.
    static var micDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "recordMicDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "recordMicDevice") }
    }
    static func nextDelay() {
        let i = delays.firstIndex(of: delay) ?? 0
        delay = delays[(i + 1) % delays.count]
    }
    /// Microphone capture through ScreenCaptureKit needs macOS 15.
    static var micAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static func microphones() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
    }

    static var selectedMicrophone: AVCaptureDevice? {
        if let id = micDeviceID, let d = microphones().first(where: { $0.uniqueID == id }) { return d }
        return AVCaptureDevice.default(for: .audio)
    }
}

enum CaptureToolbar {
    static let height: CGFloat = 44
    static let buttonHeight: CGFloat = 32
    static let meterWidth: CGFloat = 20
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let groupGap: CGFloat = 10
    private static let pad: CGFloat = 6

    private static func width(title: String?, meter: Bool) -> CGFloat {
        let base: CGFloat
        if let title {
            base = ceil(12 + 16 + 6 + (title as NSString).size(withAttributes: [.font: font]).width + 12)
        } else {
            base = buttonHeight
        }
        return base + (meter ? meterWidth : 0)
    }

    private typealias Spec = (action: ToolbarAction, symbol: String, title: String?, primary: Bool, on: Bool,
                              tint: NSColor?, meter: Bool, width: CGFloat?)

    /// Lays the bar out below the target (above it, or inside it, when there's no room).
    /// Three pills: close, Video, Screenshot.
    static func layout(around target: NSRect, on screen: NSRect) -> ToolbarLayout {
        let delay = CaptureOptions.delay
        let close: [Spec] = [(.close, "xmark", nil, false, false, nil, false, nil)]
        var video: [Spec] = [
            (.sound, CaptureOptions.sound ? "speaker.wave.2.fill" : "speaker.slash", nil, false, CaptureOptions.sound,
             nil, CaptureOptions.sound, nil),
        ]
        if CaptureOptions.micAvailable {
            video.append((.mic, CaptureOptions.mic ? "mic.fill" : "mic.slash", nil, false, CaptureOptions.mic,
                          nil, CaptureOptions.mic, nil))
            video.append((.micDevice, "chevron.down", nil, false, false, nil, false, 26))
        }
        video.append((.record, "record.circle.fill", "Record", false, false, .systemRed, false, nil))
        let shot: [Spec] = [
            (.timer, "timer", delay == 0 ? nil : "\(delay)s", false, delay > 0, nil, false, nil),
            (.copyText, "text.viewfinder", nil, false, false, nil, false, nil),
            (.copy, "doc.on.doc", nil, false, false, nil, false, nil),
            (.save, "square.and.arrow.down", nil, false, false, nil, false, nil),
            (.capture, "camera.fill", "Capture", true, false, nil, false, nil),
        ]
        let groups: [(String?, [Spec])] = [(nil, close), ("Video", video), ("Screenshot", shot)]
        func w(_ s: Spec) -> CGFloat { s.width ?? width(title: s.title, meter: s.meter) }
        let groupWidths = groups.map { g in g.1.reduce(pad * 2) { $0 + w($1) } + CGFloat(max(0, g.1.count - 1)) * 2 }
        let total = groupWidths.reduce(0, +) + groupGap * CGFloat(groups.count - 1)

        let labelSpace: CGFloat = 16
        // Room for the group tags above the pills, so they don't touch the selection.
        var y = target.minY - 14 - labelSpace - height
        if y < screen.minY + 8 { y = target.maxY + 14 }
        if y + height + labelSpace > screen.maxY - 8 { y = target.minY + 16 }
        let x = min(max(target.midX - total / 2, screen.minX + 8), screen.maxX - total - 8)
        let frame = NSRect(x: x, y: y, width: total, height: height)

        var gx = frame.minX
        var outGroups: [ToolbarGroup] = []
        var buttons: [ToolbarButton] = []
        for (i, g) in groups.enumerated() {
            let gr = NSRect(x: gx, y: frame.minY, width: groupWidths[i], height: height)
            outGroups.append(ToolbarGroup(title: g.0, rect: gr))
            var bx = gr.minX + pad
            for s in g.1 {
                let bw = w(s)
                buttons.append(ToolbarButton(action: s.action, rect: NSRect(x: bx, y: gr.midY - buttonHeight / 2, width: bw, height: buttonHeight),
                                             symbol: s.symbol, title: s.title, primary: s.primary, on: s.on, tint: s.tint, meter: s.meter))
                bx += bw + 2
            }
            gx = gr.maxX + groupGap
        }
        return ToolbarLayout(frame: frame, groups: outGroups, buttons: buttons)
    }

    static func tooltip(_ a: ToolbarAction) -> String {
        switch a {
        case .close: return "Cancel  Esc"
        case .sound: return "Record system audio"
        case .mic: return "Record microphone"
        case .micDevice: return "Choose microphone"
        case .record: return "Record screen  R"
        case .timer: return "Screenshot timer  T"
        case .copyText: return "Copy text (OCR)  ⌘⇧C"
        case .copy: return "Copy screenshot  ⌘C"
        case .save: return "Save screenshot  ⌘S"
        case .capture: return "Capture screenshot  ⏎"
        }
    }

    /// Draws the bar. `offset` converts global coordinates to the view's.
    static func draw(_ layout: ToolbarLayout, hovered: ToolbarAction?, levels: (sound: Float, mic: Float), offset: NSPoint) {
        func local(_ r: NSRect) -> NSRect { r.offsetBy(dx: -offset.x, dy: -offset.y) }

        for g in layout.groups {
            let f = local(g.rect)
            let pill = NSBezierPath(roundedRect: f, xRadius: f.height / 2, yRadius: f.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.set()
            NSColor(white: 0.09, alpha: 0.9).setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.white(0.1).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            if let title = g.title {
                let t = NSAttributedString(string: title.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Theme.white(0.6), .kern: 1.1,
                ])
                let ts = t.size()
                let tag = NSRect(x: f.minX + 16, y: f.maxY + 4, width: ts.width + 12, height: ts.height + 4)
                NSColor(white: 0.09, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
                t.draw(at: NSPoint(x: tag.minX + 6, y: tag.minY + 2))
            }
        }

        for b in layout.buttons {
            let r = local(b.rect)
            // Narrow buttons get a round (not oval) highlight.
            let d = min(r.width, r.height)
            let path = r.width < r.height
                ? NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
                : NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if b.primary {
                Theme.accent.setFill()
                path.fill()
                if hovered == b.action { Theme.white(0.12).setFill(); path.fill() }
            } else if b.on || hovered == b.action {
                Theme.white(hovered == b.action ? 0.14 : 0.1).setFill()
                path.fill()
            }
            let iconColor = b.tint ?? (b.primary || b.on || hovered == b.action ? NSColor.white : Theme.white(0.8))
            let iconSize: CGFloat = b.action == .micDevice ? 9 : 13
            guard let icon = Theme.symbol(b.symbol, size: iconSize, weight: .semibold, color: iconColor) else { continue }
            if let title = b.title {
                icon.draw(in: NSRect(x: r.minX + 12, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
                let t = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
                let ts = t.size()
                t.draw(at: NSPoint(x: r.minX + 12 + 16 + 6, y: r.midY - ts.height / 2))
            } else if b.meter {
                let iconBox = NSRect(x: r.minX, y: r.minY, width: buttonHeight, height: r.height)
                Theme.drawCentered(icon, in: iconBox)
                let level = b.action == .mic ? levels.mic : levels.sound
                drawMeter(level: level, in: NSRect(x: iconBox.maxX - 6, y: r.minY + 8, width: meterWidth - 2, height: r.height - 16))
            } else {
                Theme.drawCentered(icon, in: r)
            }
        }

        // Tooltip above the hovered button (above the group tags).
        if let h = hovered, let b = layout.buttons.first(where: { $0.action == h }) {
            let r = local(b.rect)
            let f = local(layout.frame)
            let t = NSAttributedString(string: tooltip(h), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
            ])
            let ts = t.size()
            let tip = NSRect(x: r.midX - (ts.width + 16) / 2, y: f.maxY + 24, width: ts.width + 16, height: 22)
            NSColor(white: 0.09, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: tip, xRadius: 11, yRadius: 11).fill()
            t.draw(at: NSPoint(x: tip.minX + 8, y: tip.midY - ts.height / 2))
        }
    }

    /// Five bars, lit from left to right with the level (0…1).
    static func drawMeter(level: Float, in r: NSRect) {
        let n = 5
        let gap: CGFloat = 1.5
        let bw = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let h = r.height * (0.35 + 0.65 * CGFloat(i) / CGFloat(n - 1))
            let bar = NSRect(x: r.minX + CGFloat(i) * (bw + gap), y: r.midY - h / 2, width: bw, height: h)
            let lit = level >= Float(i + 1) / Float(n + 1)
            (lit ? (i >= n - 1 ? NSColor.systemOrange : NSColor.systemGreen) : Theme.white(0.18)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bw / 2, yRadius: bw / 2).fill()
        }
    }
}
