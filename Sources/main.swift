// Snapmark — captura de tela com editor de anotações para macOS.
// https://github.com/lucas-azambuja/snapmark — Licença MIT
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Modelo

enum Tool: Int, CaseIterable {
    case arrow, line, rect, ellipse, pencil, highlight, blur, text, counter

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pencil: return "scribble"
        case .highlight: return "highlighter"
        case .blur: return "square.grid.3x3"
        case .text: return "textformat"
        case .counter: return "1.circle"
        }
    }
    var label: String {
        switch self {
        case .arrow: return "Seta (A)"
        case .line: return "Reta (L)"
        case .rect: return "Retângulo (R)"
        case .ellipse: return "Círculo (O)"
        case .pencil: return "Lápis (P)"
        case .highlight: return "Marca-texto (H)"
        case .blur: return "Borrar (B)"
        case .text: return "Texto (T)"
        case .counter: return "Contador numerado (N)"
        }
    }
    var key: String {
        switch self {
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pencil: return "p"
        case .highlight: return "h"
        case .blur: return "b"
        case .text: return "t"
        case .counter: return "n"
        }
    }
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat          // em pixels da imagem
    var points: [CGPoint]       // em pixels da imagem (origem embaixo à esquerda)
    var text: String = ""
    var number: Int = 0
    var fontSize: CGFloat = 0   // em pixels da imagem
}

// MARK: - Renderização (usada pela tela e pela exportação)

enum Renderer {
    static func draw(base: CGImage, blurred: CGImage, annotations: [Annotation], in ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: full)
        let m = ctx.ctm
        let deviceScale = max(0.01, sqrt(m.a * m.a + m.b * m.b))
        for a in annotations { draw(a, blurred: blurred, full: full, deviceScale: deviceScale, in: ctx) }
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func draw(_ a: Annotation, blurred: CGImage, full: CGRect, deviceScale: CGFloat, in ctx: CGContext) {
        guard let first = a.points.first, let last = a.points.last else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        let w = a.width
        if a.tool != .blur && a.tool != .highlight {
            ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.25 * deviceScale),
                          blur: w * 1.2 * deviceScale,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .arrow:
            drawArrow(from: first, to: last, width: w, ctx)
        case .line:
            ctx.move(to: first); ctx.addLine(to: last); ctx.strokePath()
        case .rect:
            let r = rect(first, last)
            let c = min(w, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.strokeEllipse(in: rect(first, last))
        case .pencil, .highlight:
            if a.tool == .highlight {
                ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(w * 4)
                ctx.setBlendMode(.multiply)
            }
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .blur:
            let r = rect(first, last).intersection(full)
            guard !r.isNull, r.width > 0, r.height > 0 else { return }
            ctx.clip(to: r)
            ctx.draw(blurred, in: full)
        case .text:
            drawString(a.text, at: first, attrs: textAttributes(color: a.color, size: a.fontSize), ctx)
        case .counter:
            let r = a.fontSize * 0.85
            let circle = CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(r * 0.12)
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: isLight(a.color) ? NSColor.black : NSColor.white,
            ]
            let s = NSAttributedString(string: "\(a.number)", attributes: attrs)
            let sz = s.size()
            drawString("\(a.number)", at: CGPoint(x: first.x - sz.width / 2, y: first.y - sz.height / 2), attrs: attrs, ctx)
        }
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
    }

    static func drawString(_ str: String, at p: CGPoint, attrs: [NSAttributedString.Key: Any], _ ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: str, attributes: attrs).draw(at: p)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func isLight(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.7
    }

    static func drawArrow(from p0: CGPoint, to p1: CGPoint, width w: CGFloat, _ ctx: CGContext) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let headLen = min(len, w * 3.2 + 10)
        let hh = headLen * 0.55
        let bx = len - headLen
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: w * 0.2))
        path.addLine(to: CGPoint(x: bx, y: w * 0.5))
        path.addLine(to: CGPoint(x: bx - headLen * 0.15, y: hh))
        path.addLine(to: CGPoint(x: len, y: 0))
        path.addLine(to: CGPoint(x: bx - headLen * 0.15, y: -hh))
        path.addLine(to: CGPoint(x: bx, y: -w * 0.5))
        path.addLine(to: CGPoint(x: 0, y: -w * 0.2))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: -w * 0.2, y: -w * 0.2, width: w * 0.4, height: w * 0.4))
        var t = CGAffineTransform(translationX: p0.x, y: p0.y).rotated(by: atan2(dy, dx))
        if let p = path.copy(using: &t) { ctx.addPath(p); ctx.fillPath() }
    }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let f = pts.first else { return path }
        path.move(to: f)
        if pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
            if pts.count == 1 { path.addLine(to: f) }
            return path
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func makeBlurred(_ img: CGImage, scale: CGFloat) -> CGImage {
        let ci = CIImage(cgImage: img)
        let px = CIFilter.pixellate()
        px.inputImage = ci.clampedToExtent()
        px.scale = Float(10 * scale)
        px.center = .zero
        let g = CIFilter.gaussianBlur()
        g.inputImage = px.outputImage
        g.radius = Float(3 * scale)
        let out = (g.outputImage ?? ci).cropped(to: ci.extent)
        return CIContext().createCGImage(out, from: ci.extent) ?? img
    }
}

// MARK: - Canvas

final class CanvasView: NSView, NSTextFieldDelegate {
    let base: CGImage
    let blurred: CGImage
    let pointScale: CGFloat

    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var redoStack: [Annotation] = []
    var current: Annotation? { didSet { needsDisplay = true } }
    var tool: Tool = .arrow {
        didSet { commitText(); window?.invalidateCursorRects(for: self) }
    }
    var color: NSColor = .systemRed {
        didSet { editingField?.textColor = color; editingColor = color }
    }
    var strokePt: CGFloat = 4
    var onToolKey: ((Tool) -> Void)?
    var onEscape: (() -> Void)?

    private var editingField: NSTextField?
    private var editingColor: NSColor = .systemRed
    private var editingFontSize: CGFloat = 0

    init(image: CGImage, pointScale: CGFloat) {
        base = image
        self.pointScale = pointScale
        blurred = Renderer.makeBlurred(image, scale: pointScale)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// pixels da imagem por ponto da view
    var k: CGFloat { bounds.width > 0 ? CGFloat(base.width) / bounds.width : 1 }
    func toImage(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
    var fontSize: CGFloat { (12 + strokePt * 2.5) * pointScale }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }
    override func setFrameSize(_ newSize: NSSize) {
        commitText()
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        var list = annotations
        if let c = current { list.append(c) }
        Renderer.draw(base: base, blurred: blurred, annotations: list, in: ctx)
        ctx.restoreGState()
    }

    func add(_ a: Annotation) {
        annotations.append(a)
        redoStack.removeAll()
    }
    func undo() {
        if editingField != nil { cancelText(); return }
        if let a = annotations.popLast() { redoStack.append(a) }
    }
    func redo() {
        if let a = redoStack.popLast() { annotations.append(a) }
    }

    // Mouse
    override func mouseDown(with e: NSEvent) {
        if editingField != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let p = toImage(convert(e.locationInWindow, from: nil))
        let w = strokePt * pointScale
        switch tool {
        case .text:
            beginText(at: p)
        case .counter:
            let n = (annotations.filter { $0.tool == .counter }.map { $0.number }.max() ?? 0) + 1
            add(Annotation(tool: .counter, color: color, width: w, points: [p], number: n, fontSize: fontSize))
        case .pencil, .highlight:
            current = Annotation(tool: tool, color: color, width: w, points: [p])
        default:
            current = Annotation(tool: tool, color: color, width: w, points: [p, p])
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard var c = current else { return }
        var p = toImage(convert(e.locationInWindow, from: nil))
        if c.tool == .pencil || c.tool == .highlight {
            c.points.append(p)
        } else {
            if e.modifierFlags.contains(.shift) { p = constrain(c.points[0], p, c.tool) }
            c.points[1] = p
        }
        current = c
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = current else { return }
        current = nil
        let a = c.points[0], b = c.points[c.points.count - 1]
        if c.tool == .pencil || c.tool == .highlight || hypot(a.x - b.x, a.y - b.y) > 3 * pointScale {
            add(c)
        }
    }

    private func constrain(_ o: CGPoint, _ p: CGPoint, _ t: Tool) -> CGPoint {
        let dx = p.x - o.x, dy = p.y - o.y
        switch t {
        case .line, .arrow:
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: o.x + cos(ang) * len, y: o.y + sin(ang) * len)
        case .rect, .ellipse, .blur:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: o.x + (dx < 0 ? -s : s), y: o.y + (dy < 0 ? -s : s))
        default:
            return p
        }
    }

    // Teclado
    override func keyDown(with e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { onEscape?(); return }
        if e.keyCode == UInt16(kVK_Delete) || e.keyCode == UInt16(kVK_ForwardDelete) { undo(); return }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased(),
           let t = Tool.allCases.first(where: { $0.key == ch }) {
            onToolKey?(t)
            return
        }
        super.keyDown(with: e)
    }

    // Texto
    private func beginText(at p: CGPoint) {
        let fs = fontSize
        let viewFont = NSFont.systemFont(ofSize: fs / k, weight: .bold)
        let f = NSTextField(string: "")
        f.font = viewFont
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = self
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        let vp = NSPoint(x: p.x / k, y: p.y / k)
        let h = ceil(viewFont.ascender - viewFont.descender + viewFont.leading) + 4
        f.frame = NSRect(x: vp.x - 2, y: vp.y - h / 2, width: max(160, bounds.width - vp.x + 2), height: h)
        addSubview(f)
        editingField = f
        editingColor = color
        editingFontSize = fs
        window?.makeFirstResponder(f)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    func commitText() {
        guard let f = editingField else { return }
        editingField = nil
        let t = f.stringValue
        let origin = f.frame.origin
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !t.trimmingCharacters(in: .whitespaces).isEmpty {
            add(Annotation(tool: .text, color: editingColor, width: strokePt * pointScale,
                           points: [CGPoint(x: (origin.x + 2) * k, y: (origin.y + 2) * k)],
                           text: t, fontSize: editingFontSize))
        }
    }

    private func cancelText() {
        guard let f = editingField else { return }
        editingField = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    // Exportação
    func renderFinal() -> NSBitmapImageRep? {
        commitText()
        let w = base.width, h = base.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = (base.colorSpace?.model == .rgb) ? base.colorSpace! : srgb
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        Renderer.draw(base: base, blurred: blurred, annotations: annotations, in: ctx)
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = NSSize(width: CGFloat(w) / pointScale, height: CGFloat(h) / pointScale)
        return rep
    }
}

// MARK: - UI do editor

final class ColorSwatch: NSButton {
    let swatchColor: NSColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: NSColor, target: AnyObject, action: Selector) {
        swatchColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        swatchColor.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(ovalIn: r); edge.lineWidth = 0.5; edge.stroke()
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class EditorContentView: NSView {
    let toolbar: NSView
    let canvas: CanvasView
    let natural: NSSize
    static let toolbarHeight: CGFloat = 50

    init(toolbar: NSView, canvas: CanvasView, natural: NSSize) {
        self.toolbar = toolbar
        self.canvas = canvas
        self.natural = natural
        super.init(frame: .zero)
        addSubview(toolbar)
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let th = Self.toolbarHeight
        toolbar.frame = NSRect(x: 0, y: bounds.height - th, width: bounds.width, height: th)
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - th).insetBy(dx: 20, dy: 20)
        guard area.width > 10, area.height > 10 else { return }
        let s = min(1, area.width / natural.width, area.height / natural.height)
        let w = floor(natural.width * s), h = floor(natural.height * s)
        canvas.frame = NSRect(x: floor(area.midX - w / 2), y: floor(area.midY - h / 2), width: w, height: h)
    }
}

final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if firstResponder is NSTextView {
            // Enter durante a edição de texto confirma o texto, não aciona o botão Copiar.
            if e.keyCode == UInt16(kVK_Return) || e.keyCode == UInt16(kVK_ANSI_KeypadEnter) { return false }
            return super.performKeyEquivalent(with: e)
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased(), let ed = editor
        else { return super.performKeyEquivalent(with: e) }
        switch ch {
        case "c": ed.copyImage(); return true
        case "s": ed.saveImage(); return true
        case "z":
            if flags.contains(.shift) { ed.canvas.redo() } else { ed.canvas.undo() }
            return true
        case "w": performClose(nil); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?
    private var toolControl: NSSegmentedControl!
    private var swatches: [ColorSwatch] = []
    private var colorWell: NSColorWell!
    private var finished = false

    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                     .systemBlue, .systemPurple, .black, .white]
    static let widths: [CGFloat] = [2, 4, 7, 12]

    init(image: CGImage, pointScale: CGFloat) {
        canvas = CanvasView(image: image, pointScale: pointScale)
        let natural = NSSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        let win = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        super.init(window: win)
        win.editor = self
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.title = "Snapmark — \(image.width)×\(image.height)"
        win.tabbingMode = .disallowed

        let toolbar = buildToolbar()
        win.contentView = EditorContentView(toolbar: toolbar, canvas: canvas, natural: natural)

        let tbW = toolbar.fittingSize.width
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(natural.width + 40, tbW, 520), screen.width * 0.92)
        let h = min(max(natural.height + 40 + EditorContentView.toolbarHeight, 320), screen.height * 0.92)
        win.setContentSize(NSSize(width: w, height: h))
        win.contentMinSize = NSSize(width: max(tbW, 520), height: 300)
        win.setFrameOrigin(NSPoint(x: screen.midX - win.frame.width / 2, y: screen.midY - win.frame.height / 2))

        canvas.onToolKey = { [weak self] t in self?.select(tool: t) }
        canvas.onEscape = { [weak self] in self?.window?.performClose(nil) }
        select(tool: .arrow)
        pickSwatch(0)
        win.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildToolbar() -> NSView {
        let bar = NSView()

        let images = Tool.allCases.map {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage()
        }
        toolControl = NSSegmentedControl(images: images, trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged(_:)))
        for t in Tool.allCases { toolControl.setToolTip(t.label, forSegment: t.rawValue) }

        let colors = NSStackView()
        colors.spacing = 0
        for (i, c) in Self.palette.enumerated() {
            let s = ColorSwatch(color: c, target: self, action: #selector(swatchClicked(_:)))
            s.tag = i
            swatches.append(s)
            colors.addArrangedSubview(s)
        }
        colorWell = NSColorWell()
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.target = self
        colorWell.action = #selector(customColor(_:))
        colorWell.toolTip = "Outra cor"
        colors.addArrangedSubview(colorWell)

        let widthControl = NSSegmentedControl(labels: ["Fino", "Médio", "Grosso", "Extra"], trackingMode: .selectOne,
                                              target: self, action: #selector(widthChanged(_:)))
        widthControl.selectedSegment = 1
        widthControl.toolTip = "Espessura"

        let undoBtn = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Desfazer")!,
                               target: self, action: #selector(undoAction))
        undoBtn.toolTip = "Desfazer (⌘Z)"
        let redoBtn = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Refazer")!,
                               target: self, action: #selector(redoAction))
        redoBtn.toolTip = "Refazer (⇧⌘Z)"
        let saveBtn = NSButton(title: "Salvar…", target: self, action: #selector(saveImage))
        saveBtn.toolTip = "Salvar (⌘S)"
        let copyBtn = NSButton(title: "Copiar", target: self, action: #selector(copyImage))
        copyBtn.toolTip = "Copiar para a área de transferência e fechar (⌘C)"
        copyBtn.bezelColor = .controlAccentColor
        copyBtn.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [toolControl, colors, widthControl, spacer, undoBtn, redoBtn, saveBtn, copyBtn])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.setCustomSpacing(4, after: undoBtn)
        stack.setCustomSpacing(8, after: saveBtn)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    func select(tool: Tool) {
        canvas.tool = tool
        toolControl.selectedSegment = tool.rawValue
    }

    private func pickSwatch(_ i: Int) {
        for s in swatches { s.isChosen = (s.tag == i) }
        if i >= 0 { canvas.color = Self.palette[i] }
    }

    @objc private func toolChanged(_ s: NSSegmentedControl) {
        if let t = Tool(rawValue: s.selectedSegment) { canvas.tool = t }
        window?.makeFirstResponder(canvas)
    }
    @objc private func swatchClicked(_ s: ColorSwatch) { pickSwatch(s.tag) }
    @objc private func customColor(_ w: NSColorWell) {
        pickSwatch(-1)
        canvas.color = w.color
    }
    @objc private func widthChanged(_ s: NSSegmentedControl) {
        canvas.strokePt = Self.widths[max(0, s.selectedSegment)]
        window?.makeFirstResponder(canvas)
    }
    @objc private func undoAction() { canvas.undo() }
    @objc private func redoAction() { canvas.redo() }

    @objc func copyImage() {
        guard let rep = canvas.renderFinal(), let png = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep(); return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        NSSound(named: "Pop")?.play()
        finished = true
        window?.close()
    }

    @objc func saveImage() {
        guard let win = window, let rep = canvas.renderFinal() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        panel.nameFieldStringValue = "Screenshot \(fmt.string(from: Date())).png"
        if let last = UserDefaults.standard.string(forKey: "lastSaveDir") {
            panel.directoryURL = URL(fileURLWithPath: last)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            let data = isJPEG
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:])
            do {
                try data?.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastSaveDir")
                self?.finished = true
                self?.window?.close()
            } catch {
                NSAlert(error: error).beginSheetModal(for: win)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished || canvas.annotations.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = "Descartar as anotações?"
        alert.informativeText = "A imagem não foi salva nem copiada."
        alert.addButton(withTitle: "Descartar")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: sender) { [weak self] r in
            if r == .alertFirstButtonReturn {
                self?.finished = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

// MARK: - App

private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { AppDelegate.shared?.capture() }
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?
    private var statusItem: NSStatusItem!
    private var editors: [EditorWindowController] = []
    private var capturing = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyOK = false
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        setupMainMenu()
        setupStatusItem()
        registerHotKey()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            openEditor(url: URL(fileURLWithPath: args[i + 1]), deleteAfter: false)
        }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sair do Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapmark")
        img?.isTemplate = true
        statusItem.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        let cap = NSMenuItem(title: "Capturar área", action: #selector(capture), keyEquivalent: "5")
        cap.keyEquivalentModifierMask = [.command, .shift]
        cap.target = self
        menu.addItem(cap)
        let open = NSMenuItem(title: "Abrir imagem no editor…", action: #selector(openImage), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Iniciar com o sistema", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let cap = menu.items.first {
            cap.title = hotKeyOK ? "Capturar área" : "Capturar área (atalho ⌘⇧5 indisponível)"
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x534E_4150), id: 1) // 'SNAP'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_5), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        hotKeyOK = (status == noErr)
    }

    @objc func capture() {
        guard !capturing else { return }
        capturing = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapmark-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.capturing = false
                if FileManager.default.fileExists(atPath: url.path) {
                    self.openEditor(url: url, deleteAfter: true)
                }
            }
        }
        do { try p.run() } catch { capturing = false; NSSound.beep() }
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { openEditor(url: url, deleteAfter: false) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    func openEditor(url: URL, deleteAfter: Bool) {
        defer { if deleteAfter { try? FileManager.default.removeItem(at: url) } }
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { NSSound.beep(); return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(1, CGFloat(dpi) / 72)

        let ed = EditorWindowController(image: img, pointScale: scale)
        ed.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(ed)
        NSApp.activate(ignoringOtherApps: true)
        ed.showWindow(nil)
        ed.window?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
