// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Seleção de área

/// Tempos das animações (em segundos). Ajuste aqui.
enum Motion {
    static let overlayIn = 0.12      // escurecimento aparecendo
    static let overlayOut = 0.14     // escurecimento sumindo ao cancelar
    static let flash = 0.20          // brilho branco na área capturada
    static let editorZoom = 0.22     // editor crescendo a partir da área
    static let dimAlpha: CGFloat = 0.35
}

enum SelectionResult {
    case area(NSRect)   // coordenadas globais do Cocoa (origem embaixo à esquerda)
    case window
    case cancelled
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    weak var controller: SelectionController?
    let screenFrame: NSRect
    private let flashLayer = CALayer()

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

    private var localSelection: NSRect? {
        guard let s = controller?.selection else { return nil }
        let r = s.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
        return (r.isNull || r.isEmpty) ? nil : r
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

        guard let r = sel else { return }
        // Borda desenhada por fora da área, para não entrar na captura.
        Theme.accent.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
        if controller?.dragging == true, let full = controller?.selection {
            drawSizeLabel(near: r, size: full.size)
        }
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
        if origin.y < 4 { origin.y = r.maxY + 6 }                       // sem espaço embaixo: vai para cima
        if origin.y + pill.height > bounds.height - 4 { return }       // sem espaço fora da área: não mostra
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
    override func mouseDown(with e: NSEvent) { controller?.mouseDown(at: globalPoint(e), screen: screenFrame) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseDragged(to: globalPoint(e)) }
    override func mouseUp(with e: NSEvent) { controller?.mouseUp() }
    override func keyDown(with e: NSEvent) { controller?.keyDown(e) }
}

/// Overlay escuro em todas as telas; a área selecionada fica sem escurecimento.
final class SelectionController {
    private(set) var selection: NSRect?
    private(set) var dragging = false
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
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.alphaValue = 0
            let v = OverlayView(screenFrame: screen.frame)
            v.controller = self
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            views.append(v)
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
    }

    func mouseDown(at p: NSPoint, screen: NSRect) {
        guard !finished else { return }
        start = p
        startScreen = screen
        dragging = true
        selection = NSRect(origin: p, size: .zero)
        redraw()
    }

    func mouseDragged(to p: NSPoint) {
        guard dragging else { return }
        // A seleção fica restrita à tela onde começou.
        let q = NSPoint(x: min(max(p.x, startScreen.minX), startScreen.maxX),
                        y: min(max(p.y, startScreen.minY), startScreen.maxY))
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
        redraw()
        finish(.area(r))
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

    /// Some com o overlay. Com `flash`, a área capturada pisca em branco.
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
}
