// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Rendering (shared by the canvas and the export)

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
        case .select:
            return
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
