// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Geometry: bounds, hit testing, moving and resizing annotations

/// A grab point on a selected annotation.
enum Handle: Equatable {
    case endpoint(Int)   // line/arrow ends
    case corner(Int)     // 0 = bottom-left, 1 = bottom-right, 2 = top-right, 3 = top-left
}

func boundingBox(_ pts: [CGPoint]) -> CGRect {
    guard let f = pts.first else { return .null }
    var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
    for p in pts {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

func corners(of r: CGRect) -> [CGPoint] {
    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
}

/// Snaps `p` so the segment from `o` sits on a multiple of 45°.
func snap45(from o: CGPoint, to p: CGPoint) -> CGPoint {
    let dx = p.x - o.x, dy = p.y - o.y
    let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
    let len = hypot(dx, dy)
    return CGPoint(x: o.x + cos(ang) * len, y: o.y + sin(ang) * len)
}

/// Makes the rectangle from `o` to `p` a square.
func snapSquare(from o: CGPoint, to p: CGPoint) -> CGPoint {
    let dx = p.x - o.x, dy = p.y - o.y
    let s = max(abs(dx), abs(dy))
    return CGPoint(x: o.x + (dx < 0 ? -s : s), y: o.y + (dy < 0 ? -s : s))
}

extension Annotation {
    var isSegment: Bool { tool == .arrow || tool == .line }

    var textSize: CGSize {
        NSAttributedString(string: text.isEmpty ? " " : text,
                           attributes: Renderer.textAttributes(color: color, size: fontSize)).size()
    }

    /// The box the selection frame is drawn around, in image pixels.
    var selectionRect: CGRect {
        guard let p0 = points.first else { return .null }
        switch tool {
        case .rect, .ellipse, .blur, .arrow, .line, .select:
            return Renderer.rect(p0, points[points.count - 1])
        case .pencil, .highlight:
            return boundingBox(points)
        case .text:
            return CGRect(origin: p0, size: textSize)
        case .counter:
            let r = fontSize * 0.85
            return CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2)
        }
    }

    /// `strict` only accepts hits on the visible stroke; the loose pass also accepts the inside of shapes.
    func hit(_ p: CGPoint, tolerance tol: CGFloat, strict: Bool) -> Bool {
        guard let p0 = points.first else { return false }
        let p1 = points[points.count - 1]
        switch tool {
        case .select:
            return false
        case .arrow, .line:
            return distance(p, toSegment: p0, p1) <= width / 2 + tol + (tool == .arrow ? width : 0)
        case .pencil, .highlight:
            let reach = (tool == .highlight ? width * 2 : width / 2) + tol
            if points.count == 1 { return hypot(p.x - p0.x, p.y - p0.y) <= reach }
            for (a, b) in zip(points, points.dropFirst()) where distance(p, toSegment: a, b) <= reach { return true }
            return false
        case .rect:
            let r = Renderer.rect(p0, p1)
            if !strict { return r.contains(p) }
            let outer = r.insetBy(dx: -(tol + width / 2), dy: -(tol + width / 2))
            let inner = r.insetBy(dx: tol + width / 2, dy: tol + width / 2)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .ellipse:
            let r = Renderer.rect(p0, p1)
            if !strict { return r.contains(p) }
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            return abs(sqrt(nx * nx + ny * ny) - 1) * min(rx, ry) <= tol + width / 2
        case .blur, .text, .counter:
            return selectionRect.insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }

    func translated(by dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var a = self
        a.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return a
    }

    func resized(_ handle: Handle, to p: CGPoint, constrain: Bool) -> Annotation {
        var a = self
        switch handle {
        case .endpoint(let i):
            let other = points[i == 0 ? points.count - 1 : 0]
            a.points[i == 0 ? 0 : points.count - 1] = constrain ? snap45(from: other, to: p) : p
        case .corner(let c):
            let cs = corners(of: selectionRect)
            let anchor = cs[(c + 2) % 4], from = cs[c]
            switch tool {
            case .rect, .ellipse, .blur:
                a.points = [anchor, constrain ? snapSquare(from: anchor, to: p) : p]
            case .pencil, .highlight:
                var sx = abs(from.x - anchor.x) > 0.5 ? (p.x - anchor.x) / (from.x - anchor.x) : 1
                var sy = abs(from.y - anchor.y) > 0.5 ? (p.y - anchor.y) / (from.y - anchor.y) : 1
                if constrain {
                    let s = max(abs(sx), abs(sy))
                    sx = sx < 0 ? -s : s
                    sy = sy < 0 ? -s : s
                }
                a.points = points.map {
                    CGPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy)
                }
            case .text, .counter:
                let d0 = max(hypot(from.x - anchor.x, from.y - anchor.y), 1)
                let s = max(0.15, hypot(p.x - anchor.x, p.y - anchor.y) / d0)
                a.fontSize = max(6, fontSize * s)
                a.points = points.map {
                    CGPoint(x: anchor.x + ($0.x - anchor.x) * s, y: anchor.y + ($0.y - anchor.y) * s)
                }
            case .arrow, .line, .select:
                break
            }
        }
        return a
    }
}
