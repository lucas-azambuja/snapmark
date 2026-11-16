// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Capture overlay: area, window and full-screen modes

/// Animation timings (seconds). Tweak here.
enum Motion {
    static let overlayIn = 0.12      // dimming fades in
    static let overlayOut = 0.14     // dimming fades out on cancel
    static let flash = 0.20          // white flash over the captured area
    static let editorZoom = 0.22     // editor grows out of the captured area
    static let thumbIn = 0.35        // floating thumbnail slides in
    static let thumbOut = 0.25       // floating thumbnail slides out
    static let thumbStay = 6.0       // how long the thumbnail stays on screen
    static let dimAlpha: CGFloat = 0.35
}

/// What to capture. Rectangles are in global Cocoa coordinates (origin bottom-left).
enum CaptureTarget {
    case area(NSRect)
    case window(CGWindowID, NSRect)
    case screen(NSRect)

    var frame: NSRect {
        switch self {
        case .area(let r), .window(_, let r), .screen(let r): return r
        }
    }
}

/// What happens with a still capture.
enum CaptureOutput {
    case edit, copy, save
    /// Recognize the text in the capture and copy it.
    case text
}

enum SelectionResult {
    case capture(CaptureTarget, CaptureOutput, delay: Int)
    case record(CaptureTarget, delay: Int)
    case cancelled
}

enum CaptureMode {
    case area, window, screen
}

/// A window on screen that can be captured.
struct WindowTarget {
    let id: CGWindowID
    let frame: NSRect        // global Cocoa coordinates
    let pid: pid_t
    let appName: String

    /// On-screen app windows, front to back, excluding Snapmark's own.
    static func list() -> [WindowTarget] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = getpid()
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  !["WindowManager", "Dock"].contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width >= 40, height >= 40 else { return nil }
            let frame = NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            return WindowTarget(id: id, frame: frame, pid: pid, appName: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

/// Frozen picture of each display, taken when the overlay opens. Used by the loupe.
enum ScreenSnapshot {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func capture(completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
        guard #available(macOS 14.0, *) else { completion([:]); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else { DispatchQueue.main.async { completion([:]) }; return }
            let me = content.applications.filter { $0.processID == getpid() }
            let lock = NSLock()
            var result: [CGDirectDisplayID: CGImage] = [:]
            let group = DispatchGroup()
            for d in content.displays {
                group.enter()
                let scale = NSScreen.screens.first { displayID(of: $0) == d.displayID }?.backingScaleFactor ?? 2
                let cfg = SCStreamConfiguration()
                cfg.width = Int(CGFloat(d.width) * scale)
                cfg.height = Int(CGFloat(d.height) * scale)
                cfg.showsCursor = false
                let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
                    if let img { lock.lock(); result[d.displayID] = img; lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(result) }
        }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if (contentView as? OverlayView)?.controller?.keyEquivalent(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
}

final class OverlayView: NSView {
    weak var controller: SelectionController?
    let screenFrame: NSRect
    var snapshot: CGImage? { didSet { needsDisplay = true } }
    private let flashLayer = CALayer()
    private var area: NSTrackingArea?

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        let c: NSCursor = controller?.locked == true ? .arrow : controller?.mode == .area ? .crosshair : .pointingHand
        addCursorRect(bounds, cursor: c)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    private func local(_ r: NSRect?) -> NSRect? {
        guard let r else { return nil }
        let l = r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
        return (l.isNull || l.isEmpty) ? nil : l
    }

    private var localCursor: NSPoint? {
        guard let c = controller?.cursor, NSMouseInRect(c, screenFrame, false) else { return nil }
        return NSPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let clear = local(controller.highlight)
        let dim = NSBezierPath(rect: bounds)
        if let r = clear {
            dim.append(NSBezierPath(rect: r))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Motion.dimAlpha).setFill()
        dim.fill()

        if let r = clear {
            // macOS lets clicks fall through fully transparent pixels. In window and screen
            // modes the capture doesn't go through this overlay, so an invisible tint is safe
            // and keeps the click from reaching the app underneath.
            if controller.showsAids {
                // Invisible tint: keeps clicks from reaching the app underneath. It's removed
                // (with everything else drawn here) right before the capture.
                NSColor.white.withAlphaComponent(0.004).setFill()
                r.fill()
                drawCornerMarks(around: r)
            }
        }
        guard controller.showsAids else { return }

        if controller.locked {
            if let r = clear {
                if controller.mode == .area { drawEdgeHandles(around: r) }
                if isPrimaryForHighlight { drawLabel(controller.lockedLabel, above: r) }
            }
            if controller.adjusting, let c = localCursor { drawLoupe(at: c) }
            if let bar = controller.toolbar, bar.frame.intersects(screenFrame) {
                CaptureToolbar.draw(bar, hovered: controller.hoveredAction,
                                    levels: (controller.levels.soundLevel, controller.levels.micLevel),
                                    offset: screenFrame.origin)
            }
            return
        }

        switch controller.mode {
        case .area:
            if controller.dragging, let full = controller.selection, let r = clear {
                drawLabel("\(Int(full.width)) × \(Int(full.height))", near: r)
            }
            if let c = localCursor {
                if clear == nil { drawCrosshair(at: c) }
                drawLoupe(at: c)
            }
        case .window:
            if let t = controller.hoveredWindow, let r = clear, isPrimaryForHighlight {
                drawLabel("\(t.appName)  ·  \(Int(t.frame.width)) × \(Int(t.frame.height))", near: r)
            }
        case .screen:
            if let r = clear {
                drawLabel("Full screen  ·  \(Int(r.width)) × \(Int(r.height))", centeredIn: r)
            }
        }
        if localCursor != nil, !controller.dragging { drawHints(controller.hints) }
    }

    /// Before the mouse moves, the cursor may be on another screen than the highlighted window.
    private var isPrimaryForHighlight: Bool {
        guard let h = controller?.highlight else { return false }
        return NSMouseInRect(NSPoint(x: h.midX, y: h.midY), screenFrame, false)
    }

    /// White corner brackets, like the ones in the app icon. Drawn outside the area so they never get captured.
    private func drawCornerMarks(around area: NSRect) {
        let r = area.insetBy(dx: -4, dy: -4)
        let len = max(8, min(26, min(r.width, r.height) / 4))
        let radius = min(7, len / 2)
        let p = NSBezierPath()
        for (corner, dx, dy) in [(NSPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (NSPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
                                 (NSPoint(x: r.maxX, y: r.minY), -1.0, 1.0), (NSPoint(x: r.minX, y: r.minY), 1.0, 1.0)] {
            let a = NSPoint(x: corner.x, y: corner.y + dy * len)
            let b = NSPoint(x: corner.x + dx * len, y: corner.y)
            p.move(to: a)
            p.line(to: NSPoint(x: corner.x, y: corner.y + dy * radius))
            p.curve(to: NSPoint(x: corner.x + dx * radius, y: corner.y), controlPoint1: corner, controlPoint2: corner)
            p.line(to: b)
        }
        p.lineWidth = 3.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        NSColor.white.setStroke()
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Small white bars on the edge midpoints: the side handles of a locked area.
    private func drawEdgeHandles(around area: NSRect) {
        let r = area.insetBy(dx: -4, dy: -4)
        guard r.width > 60, r.height > 60 else { return }
        let p = NSBezierPath()
        let half: CGFloat = 9
        p.move(to: NSPoint(x: r.midX - half, y: r.minY)); p.line(to: NSPoint(x: r.midX + half, y: r.minY))
        p.move(to: NSPoint(x: r.midX - half, y: r.maxY)); p.line(to: NSPoint(x: r.midX + half, y: r.maxY))
        p.move(to: NSPoint(x: r.minX, y: r.midY - half)); p.line(to: NSPoint(x: r.minX, y: r.midY + half))
        p.move(to: NSPoint(x: r.maxX, y: r.midY - half)); p.line(to: NSPoint(x: r.maxX, y: r.midY + half))
        p.lineWidth = 3.5
        p.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        NSColor.white.setStroke()
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Labels and hints

    /// A pill just above the rectangle (or inside its top edge when there's no room).
    private func drawLabel(_ s: String, above r: NSRect) {
        let t = labelText(s)
        let size = NSSize(width: ceil(t.size().width) + 18, height: ceil(t.size().height) + 8)
        var o = NSPoint(x: r.minX, y: r.maxY + 12)
        if o.y + size.height > bounds.height - 4 { o = NSPoint(x: r.minX + 12, y: r.maxY - size.height - 12) }
        o.x = min(max(4, o.x), bounds.width - size.width - 4)
        _ = pill(t, at: o)
    }

    private func pill(_ text: NSAttributedString, at origin: NSPoint) -> NSRect {
        let ts = text.size()
        let r = NSRect(x: origin.x, y: origin.y, width: ceil(ts.width) + 18, height: ceil(ts.height) + 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        text.draw(at: NSPoint(x: r.minX + 9, y: r.minY + 4))
        return r
    }

    private func labelText(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
    }

    /// A small pill just outside the rectangle (below it, or above if there's no room).
    private func drawLabel(_ s: String, near r: NSRect) {
        let t = labelText(s)
        let size = NSSize(width: ceil(t.size().width) + 18, height: ceil(t.size().height) + 8)
        var o = NSPoint(x: r.minX, y: r.minY - size.height - 12)   // clear of the corner marks
        if o.y < 4 { o.y = r.maxY + 12 }
        if o.y + size.height > bounds.height - 4 { o.y = r.maxY - size.height - 8; o.x = r.minX + 8 }
        o.x = min(max(4, o.x), bounds.width - size.width - 4)
        _ = pill(t, at: o)
    }

    private func drawLabel(_ s: String, centeredIn r: NSRect) {
        let t = labelText(s)
        let w = ceil(t.size().width) + 18
        _ = pill(t, at: NSPoint(x: r.midX - w / 2, y: r.midY))
    }

    /// Instruction bar at the bottom of the screen: key caps followed by what they do.
    private func drawHints(_ hints: [(String, String)]) {
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let gap: CGFloat = 18, capPad: CGFloat = 7, capH: CGFloat = 20
        var items: [(NSAttributedString, NSAttributedString, CGFloat)] = []
        var total: CGFloat = 0
        for (key, label) in hints {
            let k = NSAttributedString(string: key, attributes: [.font: keyFont, .foregroundColor: NSColor.white])
            let l = NSAttributedString(string: label, attributes: [.font: textFont, .foregroundColor: Theme.white(0.78)])
            let w = max(capH, ceil(k.size().width) + capPad * 2) + 7 + ceil(l.size().width)
            items.append((k, l, w))
            total += w
        }
        total += gap * CGFloat(max(0, items.count - 1))
        let bar = NSRect(x: bounds.midX - (total + 32) / 2, y: 36, width: total + 32, height: 40)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 20, yRadius: 20)
        NSColor(white: 0.08, alpha: 0.82).setFill()
        barPath.fill()
        Theme.white(0.1).setStroke()
        barPath.lineWidth = 1
        barPath.stroke()

        var x = bar.minX + 16
        for (k, l, _) in items {
            let ks = k.size()
            let cap = NSRect(x: x, y: bar.midY - capH / 2, width: max(capH, ceil(ks.width) + capPad * 2), height: capH)
            Theme.white(0.16).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5).fill()
            k.draw(at: NSPoint(x: cap.midX - ks.width / 2, y: cap.midY - ks.height / 2))
            x = cap.maxX + 7
            let ls = l.size()
            l.draw(at: NSPoint(x: x, y: bar.midY - ls.height / 2))
            x += ceil(ls.width) + gap
        }
    }

    // MARK: Crosshair and loupe

    private func drawCrosshair(at c: NSPoint) {
        let x = floor(c.x) + 0.5, y = floor(c.y) + 0.5
        let lines = NSBezierPath()
        lines.move(to: NSPoint(x: 0, y: y)); lines.line(to: NSPoint(x: bounds.width, y: y))
        lines.move(to: NSPoint(x: x, y: 0)); lines.line(to: NSPoint(x: x, y: bounds.height))
        lines.lineWidth = 1
        NSColor.black.withAlphaComponent(0.25).setStroke()
        lines.stroke()
        lines.setLineDash([5, 4], count: 2, phase: 0)
        Theme.white(0.7).setStroke()
        lines.stroke()
    }

    private func drawLoupe(at c: NSPoint) {
        guard let img = snapshot, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pixels = 15                               // odd, so there's a center pixel
        let size: CGFloat = 120
        let cell = size / CGFloat(pixels)
        let s = CGFloat(img.width) / bounds.width     // image pixels per point
        let px = Int(c.x * s), py = Int((bounds.height - c.y) * s)
        let half = pixels / 2
        let src = CGRect(x: px - half, y: py - half, width: pixels, height: pixels)
        guard let crop = img.cropping(to: src) else { return }

        // Bottom-right of the cursor; flips to stay on screen.
        let labelH: CGFloat = 22
        var r = NSRect(x: c.x + 22, y: c.y - 22 - size, width: size, height: size)
        if r.maxX > bounds.width - 8 { r.origin.x = c.x - 22 - size }
        if r.minY - labelH - 6 < 8 { r.origin.y = c.y + 22 + labelH + 6 }

        let circle = NSBezierPath(ovalIn: r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        NSColor.black.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        ctx.interpolationQuality = .none
        // Cropping near the screen edge returns fewer pixels; keep them aligned to the grid.
        let missingLeft: CGFloat = max(0, -src.minX)
        let missingTop: CGFloat = max(0, -src.minY)
        let cropW = CGFloat(crop.width), cropH = CGFloat(crop.height)
        let drawX: CGFloat = r.minX + missingLeft * cell
        let drawY: CGFloat = r.maxY - (missingTop + cropH) * cell
        ctx.draw(crop, in: NSRect(x: drawX, y: drawY, width: cropW * cell, height: cropH * cell))
        let grid = NSBezierPath()
        for i in 1..<pixels {
            let o = CGFloat(i) * cell
            grid.move(to: NSPoint(x: r.minX + o, y: r.minY)); grid.line(to: NSPoint(x: r.minX + o, y: r.maxY))
            grid.move(to: NSPoint(x: r.minX, y: r.minY + o)); grid.line(to: NSPoint(x: r.maxX, y: r.minY + o))
        }
        grid.lineWidth = 0.5
        Theme.white(0.08).setStroke()
        grid.stroke()
        let center = NSRect(x: r.minX + CGFloat(half) * cell, y: r.minY + CGFloat(half) * cell, width: cell, height: cell)
        let mark = NSBezierPath(rect: center.insetBy(dx: -0.5, dy: -0.5))
        mark.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.6).setStroke()
        mark.stroke()
        let inner = NSBezierPath(rect: center.insetBy(dx: 0.75, dy: 0.75))
        inner.lineWidth = 1
        NSColor.white.setStroke()
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        Theme.white(0.9).setStroke()
        ring.stroke()

        // Coordinates and the color under the cursor.
        var text = "\(Int(c.x)), \(Int(bounds.height - c.y))"
        let rep = NSBitmapImageRep(cgImage: crop)
        let cx = half - max(0, -Int(src.minX)), cy = half - max(0, -Int(src.minY))
        if cx >= 0, cy >= 0, cx < rep.pixelsWide, cy < rep.pixelsHigh,
           let color = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.sRGB) {
            text += String(format: "   #%02X%02X%02X", Int(color.redComponent * 255),
                           Int(color.greenComponent * 255), Int(color.blueComponent * 255))
        }
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let ls = label.size()
        let pillRect = NSRect(x: r.midX - (ls.width + 16) / 2, y: r.minY - labelH - 6, width: ls.width + 16, height: labelH)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: labelH / 2, yRadius: labelH / 2).fill()
        label.draw(at: NSPoint(x: pillRect.minX + 8, y: pillRect.midY - ls.height / 2))
    }

    func flash() {
        guard let r = local(controller?.highlight) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.frame = r
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.6
        a.toValue = 0
        a.duration = Motion.flash
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(a, forKey: "flash")
    }

    // MARK: Events

    private func globalPoint(_ e: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: e.locationInWindow) ?? .zero
    }
    override func mouseMoved(with e: NSEvent) { controller?.mouseMoved(to: globalPoint(e)) }
    override func mouseDown(with e: NSEvent) { controller?.mouseDown(at: globalPoint(e), screen: screenFrame, clickCount: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseDragged(to: globalPoint(e)) }
    override func mouseUp(with e: NSEvent) { controller?.mouseUp() }
    override func keyDown(with e: NSEvent) { controller?.keyDown(e) }
    override func flagsChanged(with e: NSEvent) { controller?.flagsChanged(e) }
}

/// Dark overlay on every screen. Area mode: drag a rectangle. Window mode (Space): click a window.
/// Full-screen mode (hold Shift): click a screen. The choice then stays on screen ("locked"),
/// can be adjusted, and an action bar offers capture, timer, copy, save and record.
final class SelectionController {
    private(set) var mode: CaptureMode = .area
    private var modeBeforeShift: CaptureMode = .area
    private(set) var selection: NSRect?
    private(set) var dragging = false
    private(set) var hoveredWindow: WindowTarget?
    private var lockedScreen: NSRect?
    /// The selection is chosen and shows handles and the action bar.
    private(set) var locked = false
    /// A handle or the whole selection is being dragged while locked.
    private(set) var adjusting = false
    private(set) var hoveredAction: ToolbarAction?
    /// Cursor position in global coordinates (for the crosshair, loupe and hints).
    private(set) var cursor: NSPoint?
    /// Everything drawn on top of the dimming; hidden right before capturing so it never shows up.
    private(set) var showsAids = true
    private var windowTargets: [WindowTarget] = []
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var start: NSPoint = .zero
    private var startScreen: NSRect = .zero
    private enum Adjust { case none, move(NSRect, NSPoint), resize(NSRect, Int) }
    private var adjust: Adjust = .none
    private var previousApp: NSRunningApplication?
    private var finished = false
    private var cursorPushed = false
    private let completion: (SelectionResult) -> Void
    /// Live microphone and system audio levels for the meters in the action bar.
    let levels = AudioLevelMonitor()
    private var meterTimer: Timer?
    private var menuTarget: MenuTarget?

    init(completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
    }

    /// The clear (not dimmed) rectangle for the current mode.
    var highlight: NSRect? {
        switch mode {
        case .area: return selection
        case .window: return hoveredWindow?.frame
        case .screen: return lockedScreen ?? screenUnderCursor?.frame
        }
    }

    var target: CaptureTarget? {
        guard let r = highlight else { return nil }
        switch mode {
        case .area: return .area(r)
        case .window: return hoveredWindow.map { .window($0.id, $0.frame) }
        case .screen: return .screen(r)
        }
    }

    private var screenUnderCursor: NSScreen? {
        let c = cursor ?? NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
    }

    private func screenFrame(containing r: NSRect) -> NSRect {
        let c = NSPoint(x: r.midX, y: r.midY)
        return (NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main)?.frame ?? r
    }

    var toolbar: ToolbarLayout? {
        guard locked, !adjusting, let r = highlight else { return nil }
        return CaptureToolbar.layout(around: r, on: screenFrame(containing: r))
    }

    var lockedLabel: String {
        guard let r = highlight else { return "" }
        let size = "\(Int(r.width)) × \(Int(r.height))"
        switch mode {
        case .area: return size
        case .window: return "\(hoveredWindow?.appName ?? "Window")  ·  \(size)"
        case .screen: return "Full screen  ·  \(size)"
        }
    }

    var hints: [(String, String)] {
        switch mode {
        case .area: return [("Drag", "Select area"), ("Space", "Window"), ("⇧ Hold", "Full screen"), ("Esc", "Cancel")]
        case .window: return [("Click", "Select window"), ("Space", "Area"), ("⇧ Hold", "Full screen"), ("Esc", "Cancel")]
        case .screen: return [("Click", "Select screen"), ("Release ⇧", "Back"), ("Esc", "Cancel")]
        }
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        cursor = NSEvent.mouseLocation
        var viewsByDisplay: [CGDirectDisplayID: OverlayView] = [:]
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            // Above the menu bar and the Dock, but below menus (for the microphone picker).
            w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.ignoresMouseEvents = false   // also catch clicks over the clear (transparent) cutout
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.alphaValue = 0
            let v = OverlayView(screenFrame: screen.frame)
            v.controller = self
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            views.append(v)
            if let id = ScreenSnapshot.displayID(of: screen) { viewsByDisplay[id] = v }
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        if let w = windows.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? windows.first {
            w.makeKey()
            w.makeFirstResponder(w.contentView)
        }
        NSCursor.crosshair.push()
        cursorPushed = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.overlayIn
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for w in windows { w.animator().alphaValue = 1 }
        }
        ScreenSnapshot.capture { images in
            for (id, img) in images { viewsByDisplay[id]?.snapshot = img }
        }
    }

    // MARK: Modes

    private func setMode(_ m: CaptureMode) {
        guard m != mode else { return }
        mode = m
        locked = false
        stopMeters()
        lockedScreen = nil
        if m == .window {
            windowTargets = WindowTarget.list()
            // Start with the front window of the app that was active before Snapmark.
            let pid = previousApp?.processIdentifier
            hoveredWindow = windowTargets.first { $0.pid == pid } ?? windowTarget(at: cursor)
        }
        if m != .area { selection = nil; dragging = false }
        setCursor(m == .area ? .crosshair : .pointingHand)
        redraw()
    }

    private func setCursor(_ c: NSCursor) {
        popCursor()
        c.push()
        cursorPushed = true
        windows.forEach { $0.invalidateCursorRects(for: $0.contentView!) }
    }

    private func windowTarget(at p: NSPoint?) -> WindowTarget? {
        guard let p else { return nil }
        return windowTargets.first { NSMouseInRect(p, $0.frame, false) }
    }

    private func lock() {
        locked = true
        if mode == .screen { lockedScreen = screenUnderCursor?.frame }
        setCursor(.arrow)
        startMeters()
        redraw()
    }

    // MARK: Meters

    private func startMeters() {
        levels.update(mic: CaptureOptions.mic && CaptureOptions.micAvailable, sound: CaptureOptions.sound)
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, CaptureOptions.mic || CaptureOptions.sound else { return }
            self.levels.decay()
            self.redraw()
        }
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels.stop()
    }

    private func showMicrophoneMenu() {
        guard let bar = toolbar, let b = bar.buttons.first(where: { $0.action == .micDevice }),
              let view = views.first(where: { NSMouseInRect(NSPoint(x: b.rect.midX, y: b.rect.midY), $0.screenFrame, false) })
        else { return }
        let target = MenuTarget { [weak self] id in
            CaptureOptions.micDeviceID = id
            if !CaptureOptions.mic { CaptureOptions.mic = true }
            self?.levels.update(mic: true, sound: CaptureOptions.sound)
            self?.levels.restartMic()
            self?.redraw()
        }
        menuTarget = target
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        let header = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let current = CaptureOptions.micDeviceID
        let def = NSMenuItem(title: "System Default", action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
        def.target = target
        def.state = current == nil ? .on : .off
        menu.addItem(def)
        menu.addItem(.separator())
        for d in CaptureOptions.microphones() {
            let item = NSMenuItem(title: d.localizedName, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = d.uniqueID
            item.state = d.uniqueID == current ? .on : .off
            menu.addItem(item)
        }
        let at = NSPoint(x: b.rect.minX - view.screenFrame.minX, y: b.rect.minY - view.screenFrame.minY - 4)
        menu.popUp(positioning: nil, at: at, in: view)
    }

    // MARK: Handles (area mode, locked)

    /// 0 bottom-left, 1 bottom, 2 bottom-right, 3 right, 4 top-right, 5 top, 6 top-left, 7 left.
    static func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: NSPoint) -> Int? {
        guard mode == .area, locked, let r = selection else { return nil }
        return Self.handlePoints(r).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 10 }
    }

    private func resized(_ r: NSRect, handle h: Int, to p: NSPoint) -> NSRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [0, 6, 7].contains(h) { minX = p.x }
        if [2, 3, 4].contains(h) { maxX = p.x }
        if [0, 1, 2].contains(h) { minY = p.y }
        if [4, 5, 6].contains(h) { maxY = p.y }
        let s = startScreen
        minX = max(s.minX, minX); maxX = min(s.maxX, maxX); minY = max(s.minY, minY); maxY = min(s.maxY, maxY)
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)).integral
    }

    // MARK: Events

    func mouseMoved(to p: NSPoint) {
        guard !finished else { return }
        cursor = p
        if mode == .window, !locked, let t = windowTarget(at: p) { hoveredWindow = t }
        hoveredAction = toolbar?.buttons.first { $0.rect.contains(p) }?.action
        redraw()
    }

    func mouseDown(at p: NSPoint, screen: NSRect, clickCount: Int) {
        guard !finished else { return }
        cursor = p
        if let bar = toolbar {
            if let b = bar.buttons.first(where: { $0.rect.contains(p) }) { perform(b.action); return }
            if bar.frame.contains(p) { return }
        }
        switch mode {
        case .area:
            if locked, let r = selection {
                if let h = handle(at: p) { adjusting = true; adjust = .resize(r, h); redraw(); return }
                if r.contains(p) {
                    if clickCount == 2 { perform(.capture); return }
                    adjusting = true; adjust = .move(r, p); redraw(); return
                }
            }
            // Start a new selection.
            locked = false
            start = p
            startScreen = screen
            dragging = true
            setCursor(.crosshair)
            selection = NSRect(origin: p, size: .zero)
            redraw()
        case .window:
            if let t = windowTarget(at: p) {
                if locked, t.id == hoveredWindow?.id, clickCount == 2 { perform(.capture); return }
                hoveredWindow = t
                lock()
            } else if hoveredWindow != nil, !locked {
                lock()
            }
        case .screen:
            if locked, clickCount == 2 { perform(.capture); return }
            lock()
        }
    }

    func mouseDragged(to p: NSPoint) {
        guard !finished else { return }
        cursor = p
        switch adjust {
        case .move(let orig, let from):
            let s = startScreen
            var r = orig.offsetBy(dx: p.x - from.x, dy: p.y - from.y)
            r.origin.x = min(max(r.minX, s.minX), s.maxX - r.width)
            r.origin.y = min(max(r.minY, s.minY), s.maxY - r.height)
            selection = r.integral
            redraw()
            return
        case .resize(let orig, let h):
            selection = resized(orig, handle: h, to: p)
            redraw()
            return
        case .none:
            break
        }
        guard dragging else { return }
        // The selection stays on the screen where it started.
        let q = NSPoint(x: min(max(p.x, startScreen.minX), startScreen.maxX),
                        y: min(max(p.y, startScreen.minY), startScreen.maxY))
        cursor = q
        selection = NSRect(x: min(start.x, q.x), y: min(start.y, q.y),
                           width: abs(q.x - start.x), height: abs(q.y - start.y)).integral
        redraw()
    }

    func mouseUp() {
        if case .none = adjust {} else {
            adjust = .none
            adjusting = false
            if let r = selection, r.width < 4 || r.height < 4 { selection = nil; locked = false }
            redraw()
            return
        }
        guard dragging else { return }
        dragging = false
        guard let r = selection, r.width >= 4, r.height >= 4 else {
            selection = nil
            redraw()
            return
        }
        lock()
    }

    func keyDown(_ e: NSEvent) {
        guard !finished else { return }
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape:
            finish(.cancelled)
        case kVK_Space where !dragging && !e.isARepeat:
            setMode(mode == .window ? .area : .window)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if locked { perform(.capture) } else if mode != .area { lock() }
        case kVK_ANSI_C where cmd && locked: perform(e.modifierFlags.contains(.shift) ? .copyText : .copy)
        case kVK_ANSI_S where cmd && locked: perform(.save)
        case kVK_ANSI_R where !cmd && locked: perform(.record)
        case kVK_ANSI_T where !cmd && locked: perform(.timer)
        default:
            break
        }
    }

    /// ⌘ shortcuts arrive as key equivalents.
    func keyEquivalent(_ e: NSEvent) -> Bool {
        guard locked, e.modifierFlags.contains(.command) else { return false }
        switch Int(e.keyCode) {
        case kVK_ANSI_C: perform(e.modifierFlags.contains(.shift) ? .copyText : .copy); return true
        case kVK_ANSI_S: perform(.save); return true
        default: return false
        }
    }

    func flagsChanged(_ e: NSEvent) {
        guard !finished, !dragging, !locked else { return }
        let shift = e.modifierFlags.contains(.shift)
        if shift, mode != .screen {
            modeBeforeShift = mode
            setMode(.screen)
        } else if !shift, mode == .screen {
            setMode(modeBeforeShift)
        }
    }

    // MARK: Actions

    private func perform(_ a: ToolbarAction) {
        guard let t = target else { return }
        switch a {
        case .close: finish(.cancelled)
        case .timer: CaptureOptions.nextDelay(); redraw()
        case .sound: CaptureOptions.sound.toggle(); startMeters(); redraw()
        case .mic: CaptureOptions.mic.toggle(); startMeters(); redraw()
        case .micDevice: showMicrophoneMenu()
        case .record: done(.record(t, delay: CaptureOptions.delay))
        case .copy: done(.capture(t, .copy, delay: CaptureOptions.delay))
        case .copyText: done(.capture(t, .text, delay: CaptureOptions.delay))
        case .save: done(.capture(t, .save, delay: CaptureOptions.delay))
        case .capture: done(.capture(t, .edit, delay: CaptureOptions.delay))
        }
    }

    /// Hides everything drawn on top of the dimming, lets the window server draw that, then reports.
    private func done(_ result: SelectionResult) {
        guard !finished else { return }
        finished = true
        stopMeters()
        showsAids = false
        views.forEach { $0.display() }
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.completion(result) }
    }

    private func finish(_ r: SelectionResult) {
        guard !finished else { return }
        finished = true
        stopMeters()
        completion(r)
    }

    private func redraw() { views.forEach { $0.needsDisplay = true } }

    private func popCursor() {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    /// Fades the overlay out. With `flash`, the captured area flashes white.
    func dismiss(flash: Bool, completion: (() -> Void)? = nil) {
        popCursor()
        if flash { views.forEach { $0.flash() } }
        let wins = windows
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = flash ? Motion.flash : Motion.overlayOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for w in wins { w.animator().alphaValue = 0 }
        }, completionHandler: {
            wins.forEach { $0.orderOut(nil) }
            self.windows.removeAll()
            self.views.removeAll()
            completion?()
        })
    }

    func dismissImmediately() {
        popCursor()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    func restorePreviousApp() {
        previousApp?.activate()
    }

    /// Development only (`--snapshot-overlay`): draws an overlay view with a fake cursor into a PNG.
    static func renderPreview(snapshot: CGImage, size: NSSize, cursor: NSPoint, output: URL,
                              mode: CaptureMode = .area, fakeWindow: NSRect? = nil, locked: Bool = false) {
        let c = SelectionController { _ in }
        c.cursor = cursor
        c.mode = mode
        if let f = fakeWindow {
            c.hoveredWindow = WindowTarget(id: 0, frame: f, pid: 0, appName: "Safari")
            if mode == .area { c.selection = f }
        }
        c.locked = locked
        let v = OverlayView(screenFrame: NSRect(origin: .zero, size: size))
        v.controller = c
        v.snapshot = snapshot
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
    }
}

/// Target for menu items, since the overlay controller isn't an NSObject.
final class MenuTarget: NSObject {
    let onPick: (String?) -> Void
    init(onPick: @escaping (String?) -> Void) { self.onPick = onPick }
    @objc func pick(_ item: NSMenuItem) { onPick(item.representedObject as? String) }
}
