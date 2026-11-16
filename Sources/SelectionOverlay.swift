// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - Area selection

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

enum SelectionResult {
    case area(NSRect)   // global Cocoa coordinates (origin bottom-left)
    case window
    case cancelled
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    private var localSelection: NSRect? {
        guard let s = controller?.selection else { return nil }
        let r = s.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
        return (r.isNull || r.isEmpty) ? nil : r
    }

    private var localCursor: NSPoint? {
        guard let c = controller?.cursor, NSMouseInRect(c, screenFrame, false) else { return nil }
        return NSPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let sel = localSelection
        if let r = sel {
            dim.append(NSBezierPath(rect: r))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Motion.dimAlpha).setFill()
        dim.fill()

        if let r = sel {
            // The border is drawn outside the area so it never ends up in the capture.
            Theme.accent.setStroke()
            let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            if controller?.dragging == true, let full = controller?.selection {
                drawSizeLabel(near: r, size: full.size)
            }
        }

        guard controller?.showsAids == true, let c = localCursor else { return }
        if sel == nil { drawCrosshair(at: c) }
        drawLoupe(at: c)
    }

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
        let drawRect = NSRect(x: drawX, y: drawY, width: cropW * cell, height: cropH * cell)
        ctx.draw(crop, in: drawRect)
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
        let pill = NSRect(x: r.midX - (ls.width + 16) / 2, y: r.minY - labelH - 6, width: ls.width + 16, height: labelH)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: labelH / 2, yRadius: labelH / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 8, y: pill.midY - ls.height / 2))
    }

    private func drawSizeLabel(near r: NSRect, size: NSSize) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: "\(Int(size.width)) × \(Int(size.height))", attributes: attrs)
        let ts = s.size()
        let pill = NSSize(width: ceil(ts.width) + 16, height: ceil(ts.height) + 6)
        var origin = NSPoint(x: r.minX, y: r.minY - pill.height - 6)
        if origin.y < 4 { origin.y = r.maxY + 6 }                       // no room below: go above
        if origin.y + pill.height > bounds.height - 4 { return }       // no room outside the area: skip
        origin.x = min(max(4, origin.x), bounds.width - pill.width - 4)
        let pr = NSRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pr, xRadius: pr.height / 2, yRadius: pr.height / 2).fill()
        s.draw(at: NSPoint(x: pr.minX + 8, y: pr.minY + 3))
    }

    func flash() {
        guard let r = localSelection else { return }
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

    private func globalPoint(_ e: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: e.locationInWindow) ?? .zero
    }
    override func mouseMoved(with e: NSEvent) { controller?.mouseMoved(to: globalPoint(e)) }
    override func mouseDown(with e: NSEvent) { controller?.mouseDown(at: globalPoint(e), screen: screenFrame) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseDragged(to: globalPoint(e)) }
    override func mouseUp(with e: NSEvent) { controller?.mouseUp() }
    override func keyDown(with e: NSEvent) { controller?.keyDown(e) }
}

/// Dark overlay on every screen; the selected area stays clear.
final class SelectionController {
    private(set) var selection: NSRect?
    private(set) var dragging = false
    /// Cursor position in global coordinates (for the crosshair and loupe).
    private(set) var cursor: NSPoint?
    /// Crosshair and loupe; hidden right before the capture so they never show up in it.
    private(set) var showsAids = true
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var start: NSPoint = .zero
    private var startScreen: NSRect = .zero
    private var previousApp: NSRunningApplication?
    private var finished = false
    private var cursorPushed = false
    private let completion: (SelectionResult) -> Void

    init(completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        cursor = NSEvent.mouseLocation
        var viewsByDisplay: [CGDirectDisplayID: OverlayView] = [:]
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
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

    func mouseMoved(to p: NSPoint) {
        guard !finished else { return }
        cursor = p
        redraw()
    }

    func mouseDown(at p: NSPoint, screen: NSRect) {
        guard !finished else { return }
        start = p
        startScreen = screen
        dragging = true
        cursor = p
        selection = NSRect(origin: p, size: .zero)
        redraw()
    }

    func mouseDragged(to p: NSPoint) {
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
        guard dragging else { return }
        dragging = false
        guard let r = selection, r.width >= 4, r.height >= 4 else {
            selection = nil
            redraw()
            return
        }
        // Hide the crosshair and loupe, let the window server draw that, then capture.
        showsAids = false
        views.forEach { $0.display() }
        CATransaction.flush()
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.completion(.area(r)) }
    }

    func keyDown(_ e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape: finish(.cancelled)
        case kVK_Space where !dragging: finish(.window)
        default: break
        }
    }

    private func finish(_ r: SelectionResult) {
        guard !finished else { return }
        finished = true
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
    static func renderPreview(snapshot: CGImage, size: NSSize, cursor: NSPoint, output: URL) {
        let c = SelectionController { _ in }
        c.cursor = cursor
        let v = OverlayView(screenFrame: NSRect(origin: .zero, size: size))
        v.controller = c
        v.snapshot = snapshot
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
    }
}
