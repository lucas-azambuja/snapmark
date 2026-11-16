// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Floating thumbnail after copying or saving

final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The thumbnail itself: drag it into another app, click to reopen in the editor.
final class ThumbnailView: NSView, NSDraggingSource {
    let image: NSImage
    let fileURL: URL
    let caption: String
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var downPoint: NSPoint?
    private var area: NSTrackingArea?
    static let padding: CGFloat = 6

    init(image: NSImage, fileURL: URL, caption: String, size: NSSize) {
        self.image = image
        self.fileURL = fileURL
        self.caption = caption
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: NSRect { NSRect(x: 12, y: bounds.height - 34, width: 22, height: 22) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor(white: 0.12, alpha: 1).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: aspectFill(image.size, in: card), from: .zero, operation: .sourceOver, fraction: 1)
        // Caption on a dark gradient at the bottom.
        let band = NSRect(x: card.minX, y: card.minY, width: card.width, height: 34)
        NSGradient(starting: NSColor.black.withAlphaComponent(0.65), ending: NSColor.black.withAlphaComponent(0))?
            .draw(in: band, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        let label = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let check = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, Theme.accent])))
        var x = card.minX + 10
        if let check {
            check.draw(in: NSRect(x: x, y: card.minY + 9, width: check.size.width, height: check.size.height))
            x += check.size.width + 5
        }
        label.draw(at: NSPoint(x: x, y: card.minY + 8))

        Theme.white(0.18).setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        edge.lineWidth = 1
        edge.stroke()

        if hovering {
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: closeRect).fill()
            Theme.drawCentered(Theme.symbol("xmark", size: 9, weight: .bold, color: .white), in: closeRect)
        }
    }

    private func aspectFill(_ s: NSSize, in r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let scale = max(r.width / s.width, r.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    override func mouseDown(with e: NSEvent) { downPoint = convert(e.locationInWindow, from: nil) }

    override func mouseDragged(with e: NSEvent) {
        guard let d = downPoint else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - d.x, p.y - d.y) > 4 else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: Self.padding, dy: Self.padding), contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = downPoint else { return }
        downPoint = nil
        if hovering, closeRect.insetBy(dx: -4, dy: -4).contains(d) { onClose?() } else { onOpen?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(operation != [])
    }
}

/// Shows one floating thumbnail at a time in the bottom-left corner of the screen.
final class QuickAccess {
    static let shared = QuickAccess()
    private var panel: ThumbnailPanel?
    private var timer: Timer?

    /// `fileURL` is what gets dragged out; for copies it's a temporary PNG.
    func show(image: NSImage, fileURL: URL, caption: String, onOpen: @escaping (URL) -> Void) {
        dismiss(animated: false)
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW: CGFloat = 240, maxH: CGFloat = 160
        let s = image.size
        let scale = min(maxW / max(s.width, 1), maxH / max(s.height, 1), 1)
        let pad = ThumbnailView.padding
        let size = NSSize(width: max(150, s.width * scale) + pad * 2, height: max(100, s.height * scale) + pad * 2)
        let final = NSRect(x: screen.minX + 18, y: screen.minY + 18, width: size.width, height: size.height)

        let p = ThumbnailPanel(contentRect: final, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = ThumbnailView(image: image, fileURL: fileURL, caption: caption, size: size)
        v.onOpen = { [weak self] in self?.dismiss(animated: true); onOpen(fileURL) }
        v.onClose = { [weak self] in self?.dismiss(animated: true) }
        v.onHover = { [weak self] inside in
            if inside { self?.timer?.invalidate() } else { self?.scheduleDismiss(after: 3) }
        }
        v.onDragEnded = { [weak self] dropped in
            if dropped { self?.dismiss(animated: true) } else { self?.scheduleDismiss(after: 3) }
        }
        p.contentView = v
        panel = p

        // Slide in from the left edge with a little overshoot.
        p.setFrame(final.offsetBy(dx: -(size.width + 30), dy: 0), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.thumbIn
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)
            p.animator().setFrame(final, display: true)
            p.animator().alphaValue = 1
        }
        scheduleDismiss(after: Motion.thumbStay)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        timer?.invalidate()
        timer = nil
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.thumbOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(p.frame.offsetBy(dx: -(p.frame.width + 30), dy: 0), display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    /// Writes the PNG to a temporary file so it can be dragged into other apps.
    static func temporaryFile(png: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Screenshot \(fmt.string(from: Date())).png")
        do { try png.write(to: url); return url } catch { return nil }
    }
}
