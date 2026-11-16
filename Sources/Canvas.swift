// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox

// MARK: - Canvas

final class CanvasView: NSView, NSTextFieldDelegate {
    let base: CGImage
    let blurred: CGImage
    let pointScale: CGFloat

    private(set) var annotations: [Annotation] = [] { didSet { needsDisplay = true; onChange?() } }
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var current: Annotation? { didSet { needsDisplay = true } }

    /// Index of the selected annotation, if any.
    private(set) var selectedIndex: Int? {
        didSet {
            needsDisplay = true
            if oldValue != selectedIndex { onSelectionChange?(selected) }
        }
    }
    var selected: Annotation? {
        guard let i = selectedIndex, i < annotations.count else { return nil }
        return annotations[i]
    }

    var tool: Tool = .arrow {
        didSet { commitText(); window?.invalidateCursorRects(for: self) }
    }
    /// Color and stroke used for new annotations. Use `applyColor`/`applyStroke` to also change the selection.
    var color: NSColor = .systemRed
    var strokePt: CGFloat = 4

    var onToolKey: ((Tool) -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    var onSelectionChange: ((Annotation?) -> Void)?
    var onChange: (() -> Void)?

    private enum Drag {
        case none
        case drawing
        case moving(orig: Annotation, start: CGPoint)
        case resizing(orig: Annotation, handle: Handle)
    }
    private var drag: Drag = .none
    private var snapshotTaken = false

    private var editingField: NSTextField?
    private var editingIndex: Int?
    private var editingColor: NSColor = .systemRed
    private var editingFontSize: CGFloat = 0

    init(image: CGImage, pointScale: CGFloat) {
        base = image
        self.pointScale = pointScale
        blurred = Renderer.makeBlurred(image, scale: pointScale)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Image pixels per view point.
    var k: CGFloat { bounds.width > 0 ? CGFloat(base.width) / bounds.width : 1 }
    func toImage(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
    func toView(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x / k, y: p.y / k) }
    func fontSize(for pt: CGFloat) -> CGFloat { (12 + pt * 2.5) * pointScale }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasAnnotations: Bool { !annotations.isEmpty }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        let c: NSCursor = tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: c)
    }
    override func setFrameSize(_ newSize: NSSize) {
        commitText()
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        var list = annotations
        if let i = editingIndex, i < list.count { list.remove(at: i) }
        if let c = current { list.append(c) }
        Renderer.draw(base: base, blurred: blurred, annotations: list, in: ctx)
        ctx.restoreGState()
        drawSelection()
    }

    /// Selection frame and handles, in view coordinates so they stay crisp at any zoom.
    private func viewHandles(for a: Annotation) -> [(Handle, NSPoint)] {
        if a.isSegment {
            return [(.endpoint(0), toView(a.points[0])), (.endpoint(1), toView(a.points[a.points.count - 1]))]
        }
        let r = viewFrame(for: a)
        return corners(of: r).enumerated().map { (.corner($0.offset), $0.element) }
    }

    private func viewFrame(for a: Annotation) -> NSRect {
        let r = a.selectionRect
        return NSRect(x: r.minX / k, y: r.minY / k, width: r.width / k, height: r.height / k).insetBy(dx: -4, dy: -4)
    }

    private func drawSelection() {
        guard let a = selected, editingIndex == nil else { return }
        if !a.isSegment {
            let frame = NSBezierPath(rect: viewFrame(for: a).insetBy(dx: 0.5, dy: 0.5))
            frame.lineWidth = 1
            NSColor.black.withAlphaComponent(0.35).setStroke()
            frame.stroke()
            frame.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            frame.stroke()
        }
        for (_, p) in viewHandles(for: a) {
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            Theme.accent.setStroke()
            dot.stroke()
        }
    }

    // MARK: Editing operations (all undoable)

    private func takeSnapshot() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func undo() {
        if editingField != nil { cancelText(); return }
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(annotations)
        selectedIndex = nil
        annotations = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(annotations)
        selectedIndex = nil
        annotations = next
    }

    func deleteSelection() {
        guard let i = selectedIndex else { NSSound.beep(); return }
        takeSnapshot()
        selectedIndex = nil
        annotations.remove(at: i)
    }

    func deselect() { selectedIndex = nil }

    /// Development only (`--snapshot`): adds sample annotations and selects the last one.
    func loadPreviewSample() {
        let w = base.width, h = base.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: Double(w) * x, y: Double(h) * y) }
        let s = pointScale
        annotations = [
            Annotation(tool: .arrow, color: .systemRed, width: 4 * s, points: [p(0.15, 0.25), p(0.4, 0.55)]),
            Annotation(tool: .blur, color: .systemRed, width: 4 * s, points: [p(0.55, 0.15), p(0.85, 0.3)]),
            Annotation(tool: .counter, color: .systemRed, width: 4 * s, points: [p(0.12, 0.8)], number: 1, fontSize: fontSize(for: 4)),
            Annotation(tool: .rect, color: .systemYellow, width: 4 * s, points: [p(0.5, 0.5), p(0.85, 0.85)]),
        ]
        selectedIndex = annotations.count - 1
    }

    func applyColor(_ c: NSColor) {
        color = c
        if editingField != nil {
            editingField?.textColor = c
            editingColor = c
            return
        }
        guard let i = selectedIndex, annotations[i].tool.usesColor else { return }
        takeSnapshot()
        annotations[i].color = c
    }

    func applyStroke(_ pt: CGFloat) {
        strokePt = pt
        guard let i = selectedIndex, editingField == nil else { return }
        var a = annotations[i]
        switch a.tool {
        case .blur, .select: return
        case .text, .counter: a.fontSize = fontSize(for: pt)
        default: a.width = pt * pointScale
        }
        takeSnapshot()
        annotations[i] = a
    }

    private func append(_ a: Annotation) {
        takeSnapshot()
        annotations.append(a)
        selectedIndex = annotations.count - 1
    }

    private func hitIndex(_ p: CGPoint) -> Int? {
        let tol = 5 * k
        for strict in [true, false] {
            for i in annotations.indices.reversed() where annotations[i].hit(p, tolerance: tol, strict: strict) {
                return i
            }
        }
        return nil
    }

    private func handle(atView v: NSPoint) -> Handle? {
        guard let a = selected else { return nil }
        return viewHandles(for: a).first { hypot($0.1.x - v.x, $0.1.y - v.y) <= 7 }?.0
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        if editingField != nil { commitText(); return }
        window?.makeFirstResponder(self)
        let v = convert(e.locationInWindow, from: nil)
        let p = toImage(v)
        snapshotTaken = false
        drag = .none

        // The selected annotation's handles work with any tool.
        if let h = handle(atView: v), let a = selected {
            drag = .resizing(orig: a, handle: h)
            return
        }

        switch tool {
        case .select:
            if let i = hitIndex(p) {
                if e.clickCount == 2, annotations[i].tool == .text { beginEditing(i); return }
                selectedIndex = i
                drag = .moving(orig: annotations[i], start: p)
            } else {
                selectedIndex = nil
            }
        case .text:
            if let i = hitIndex(p), annotations[i].tool == .text { beginEditing(i); return }
            selectedIndex = nil
            beginText(at: p)
        case .counter:
            let n = (annotations.filter { $0.tool == .counter }.map { $0.number }.max() ?? 0) + 1
            append(Annotation(tool: .counter, color: color, width: strokePt * pointScale, points: [p],
                              number: n, fontSize: fontSize(for: strokePt)))
            if let a = selected {
                drag = .moving(orig: a, start: p)
                snapshotTaken = true
            }
        case .pencil, .highlight:
            selectedIndex = nil
            current = Annotation(tool: tool, color: color, width: strokePt * pointScale, points: [p])
            drag = .drawing
        default:
            selectedIndex = nil
            current = Annotation(tool: tool, color: color, width: strokePt * pointScale, points: [p, p])
            drag = .drawing
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = toImage(convert(e.locationInWindow, from: nil))
        let shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .drawing:
            guard var c = current else { return }
            if c.tool == .pencil || c.tool == .highlight {
                c.points.append(p)
            } else if c.isSegment {
                c.points[1] = shift ? snap45(from: c.points[0], to: p) : p
            } else {
                c.points[1] = shift ? snapSquare(from: c.points[0], to: p) : p
            }
            current = c
        case .moving(let orig, let start):
            guard let i = selectedIndex else { return }
            if !snapshotTaken { takeSnapshot(); snapshotTaken = true }
            annotations[i] = orig.translated(by: p.x - start.x, p.y - start.y)
        case .resizing(let orig, let h):
            guard let i = selectedIndex else { return }
            if !snapshotTaken { takeSnapshot(); snapshotTaken = true }
            annotations[i] = orig.resized(h, to: p, constrain: shift)
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none }
        guard case .drawing = drag, let c = current else { return }
        current = nil
        let a = c.points[0], b = c.points[c.points.count - 1]
        if c.tool == .pencil || c.tool == .highlight || hypot(a.x - b.x, a.y - b.y) > 3 * pointScale {
            append(c)
        }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape:
            if selectedIndex != nil { selectedIndex = nil } else { onEscape?() }
            return
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelection()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onReturn?()
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            if let i = selectedIndex {
                let step = (e.modifierFlags.contains(.shift) ? 10 : 1) * k
                let code = Int(e.keyCode)
                let dx: CGFloat = code == kVK_LeftArrow ? -step : code == kVK_RightArrow ? step : 0
                let dy: CGFloat = code == kVK_DownArrow ? -step : code == kVK_UpArrow ? step : 0
                takeSnapshot()
                annotations[i] = annotations[i].translated(by: dx, dy)
                return
            }
        default:
            break
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased(),
           let t = Tool.allCases.first(where: { $0.key == ch }) {
            onToolKey?(t)
            return
        }
        super.keyDown(with: e)
    }

    // MARK: Text

    private func makeField(text: String, color: NSColor, fontSize fs: CGFloat, viewOrigin: NSPoint) {
        let viewFont = NSFont.systemFont(ofSize: fs / k, weight: .bold)
        let f = NSTextField(string: text)
        f.font = viewFont
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = self
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        let h = ceil(viewFont.ascender - viewFont.descender + viewFont.leading) + 4
        let textW = (text as NSString).size(withAttributes: [.font: viewFont]).width
        f.frame = NSRect(x: viewOrigin.x, y: viewOrigin.y, width: max(180, textW + 60, bounds.width - viewOrigin.x), height: h)
        addSubview(f)
        editingField = f
        editingColor = color
        editingFontSize = fs
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    private func beginText(at p: CGPoint) {
        let fs = fontSize(for: strokePt)
        let viewFont = NSFont.systemFont(ofSize: fs / k, weight: .bold)
        let h = ceil(viewFont.ascender - viewFont.descender + viewFont.leading) + 4
        let v = toView(p)
        editingIndex = nil
        makeField(text: "", color: color, fontSize: fs, viewOrigin: NSPoint(x: v.x - 2, y: v.y - h / 2))
    }

    private func beginEditing(_ i: Int) {
        let a = annotations[i]
        selectedIndex = i
        editingIndex = i
        let v = toView(a.points[0])
        makeField(text: a.text, color: a.color, fontSize: a.fontSize, viewOrigin: NSPoint(x: v.x - 2, y: v.y - 2))
        needsDisplay = true
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
        let origin = CGPoint(x: (f.frame.minX + 2) * k, y: (f.frame.minY + 2) * k)
        let index = editingIndex
        editingIndex = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        let empty = t.trimmingCharacters(in: .whitespaces).isEmpty
        if let i = index, i < annotations.count {
            if empty {
                takeSnapshot()
                selectedIndex = nil
                annotations.remove(at: i)
            } else if t != annotations[i].text || editingColor != annotations[i].color {
                takeSnapshot()
                annotations[i].text = t
                annotations[i].color = editingColor
                selectedIndex = i
            } else {
                needsDisplay = true
            }
        } else if !empty {
            append(Annotation(tool: .text, color: editingColor, width: strokePt * pointScale,
                              points: [origin], text: t, fontSize: editingFontSize))
        }
    }

    private func cancelText() {
        guard let f = editingField else { return }
        editingField = nil
        editingIndex = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Export

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
