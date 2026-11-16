// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import AVFoundation

// MARK: - Trim bar: filmstrip, start/end handles and playhead

/// A filmstrip of the movie with two handles that set the start and end, and a playhead.
/// Positions are fractions of the duration (0…1).
final class TrimmerView: NSView {
    enum Edge { case start, end }

    var duration: Double = 1
    private(set) var lo: CGFloat = 0
    private(set) var hi: CGFloat = 1
    var playhead: CGFloat = 0 { didSet { if abs(playhead - oldValue) > 0.0005 { needsDisplay = true } } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }

    /// Called while a handle moves (with the edge) and once more when it's released (edge nil).
    var onTrim: ((CGFloat, CGFloat, Edge?) -> Void)?
    /// Called while scrubbing, and with `done` when the mouse goes up.
    var onScrub: ((CGFloat, _ done: Bool) -> Void)?

    static let handleWidth: CGFloat = 14
    private enum Drag { case none, start, end, scrub }
    private var drag: Drag = .none
    private var grabOffset: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isTrimmed: Bool { lo > 0.0005 || hi < 0.9995 }

    func setRange(_ lo: CGFloat, _ hi: CGFloat) {
        self.lo = lo
        self.hi = hi
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The filmstrip area; the handles sit just outside the selected range.
    private var strip: NSRect { bounds.insetBy(dx: Self.handleWidth, dy: 4) }
    private func x(_ f: CGFloat) -> CGFloat { strip.minX + f * strip.width }
    private func fraction(_ x: CGFloat) -> CGFloat { min(1, max(0, (x - strip.minX) / max(strip.width, 1))) }
    private var startHandle: NSRect { NSRect(x: x(lo) - Self.handleWidth, y: strip.minY - 4, width: Self.handleWidth, height: strip.height + 8) }
    private var endHandle: NSRect { NSRect(x: x(hi), y: strip.minY - 4, width: Self.handleWidth, height: strip.height + 8) }
    /// At least half a second stays selected.
    private var minGap: CGFloat { CGFloat(min(1, 0.5 / max(duration, 0.5))) }

    override func resetCursorRects() {
        addCursorRect(strip, cursor: .pointingHand)
        addCursorRect(startHandle.insetBy(dx: -4, dy: 0), cursor: .resizeLeftRight)
        addCursorRect(endHandle.insetBy(dx: -4, dy: 0), cursor: .resizeLeftRight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let s = strip
        let clip = NSBezierPath(roundedRect: s, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        s.fill()
        if !thumbnails.isEmpty {
            let tileW = s.width / CGFloat(thumbnails.count)
            for (i, img) in thumbnails.enumerated() {
                let tile = NSRect(x: s.minX + CGFloat(i) * tileW, y: s.minY, width: ceil(tileW), height: s.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: tile).addClip()
                img.draw(in: aspectFill(img.size, tile), from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // Dim what will be cut.
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSRect(x: s.minX, y: s.minY, width: x(lo) - s.minX, height: s.height).fill()
        NSRect(x: x(hi), y: s.minY, width: s.maxX - x(hi), height: s.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Selection frame with the two handles. White when untouched, accent once trimmed.
        let color = isTrimmed ? Theme.accent : NSColor.white
        let frame = NSRect(x: startHandle.minX, y: startHandle.minY, width: endHandle.maxX - startHandle.minX, height: startHandle.height)
        let outer = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        outer.append(NSBezierPath(rect: NSRect(x: x(lo), y: frame.minY + 3, width: x(hi) - x(lo), height: frame.height - 6)))
        outer.windingRule = .evenOdd
        color.setFill()
        outer.fill()
        for h in [startHandle, endHandle] {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let grip = NSRect(x: h.midX - 1, y: h.midY - 7, width: 2, height: 14)
            NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        }

        // Playhead.
        if playhead >= lo - 0.001, playhead <= hi + 0.001 {
            let px = x(playhead)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: px - 1, y: s.minY - 2, width: 2, height: s.height + 4), xRadius: 1, yRadius: 1).fill()
        }

        // Time bubble while dragging a handle.
        if drag == .start || drag == .end {
            let f = drag == .start ? lo : hi
            let t = NSAttributedString(string: Self.clock(Double(f) * duration), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let ts = t.size()
            var bx = x(f) - (ts.width + 12) / 2
            bx = min(max(bx, bounds.minX), bounds.maxX - ts.width - 12)
            let bubble = NSRect(x: bx, y: s.midY - 10, width: ts.width + 12, height: 20)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
            t.draw(at: NSPoint(x: bubble.minX + 6, y: bubble.midY - ts.height / 2))
        }
    }

    static func clock(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let s = Int(t)
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
    }

    private func aspectFill(_ size: NSSize, _ r: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return r }
        let k = max(r.width / size.width, r.height / size.height)
        return NSRect(x: r.midX - size.width * k / 2, y: r.midY - size.height * k / 2, width: size.width * k, height: size.height * k)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if startHandle.insetBy(dx: -4, dy: -4).contains(p) {
            drag = .start
            grabOffset = p.x - x(lo)
        } else if endHandle.insetBy(dx: -4, dy: -4).contains(p) {
            drag = .end
            grabOffset = p.x - x(hi)
        } else {
            drag = .scrub
            scrub(to: p.x, done: false)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .start:
            NSCursor.resizeLeftRight.set()
            lo = min(max(0, fraction(p.x - grabOffset)), hi - minGap)
            needsDisplay = true
            onTrim?(lo, hi, .start)
        case .end:
            NSCursor.resizeLeftRight.set()
            hi = max(min(1, fraction(p.x - grabOffset)), lo + minGap)
            needsDisplay = true
            onTrim?(lo, hi, .end)
        case .scrub:
            scrub(to: p.x, done: false)
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .start, .end:
            onTrim?(lo, hi, nil)
            window?.invalidateCursorRects(for: self)
        case .scrub:
            scrub(to: convert(e.locationInWindow, from: nil).x, done: true)
        case .none:
            break
        }
        drag = .none
        needsDisplay = true
    }

    private func scrub(to px: CGFloat, done: Bool) {
        let f = min(max(fraction(px), lo), hi)
        playhead = f
        onScrub?(f, done)
    }
}

/// Seeks without piling up requests: while one seek runs, only the latest target is kept.
final class SeekChaser {
    private let player: AVPlayer
    private var seeking = false
    private var pending: (CMTime, Bool)?

    init(player: AVPlayer) { self.player = player }

    func seek(to t: CMTime, exact: Bool) {
        if seeking { pending = (t, exact); return }
        seeking = true
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 20)
        player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if let (next, ex) = self.pending {
                    self.pending = nil
                    self.seek(to: next, exact: ex)
                }
            }
        }
    }
}
