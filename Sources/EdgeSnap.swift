// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Snap the selection to the visible edges of what's on screen

/// Brightness of a screen picture, used to find straight edges (borders of windows, cards, panels…)
/// near the selection. Coordinates passed in are the screen's local points (origin bottom-left).
final class EdgeMap {
    private let lum: [UInt8]
    private let width: Int
    private let height: Int
    /// Pixels per point.
    private let scale: CGFloat
    /// How far (in points) an edge can pull the selection.
    static let reach: CGFloat = 8
    /// Brightness step that counts as an edge.
    private static let threshold = 18

    init?(image: CGImage, pointWidth: CGFloat) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, pointWidth > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        lum = buf
        width = w
        height = h
        scale = CGFloat(w) / pointWidth
    }

    private func at(_ x: Int, _ y: Int) -> Int { Int(lum[y * width + x]) }
    /// Point y (bottom-left origin) → pixel row (top-left origin).
    private func row(_ y: CGFloat) -> Int { min(height - 1, max(0, Int((CGFloat(height) / scale - y) * scale))) }
    private func col(_ x: CGFloat) -> Int { min(width - 1, max(0, Int(x * scale))) }

    /// Picks the strongest candidate (the share of the span that shows an edge); among near-ties, the closest.
    private static func pick(_ scores: [(index: Int, score: Double)], near target: CGFloat) -> Int? {
        guard let top = scores.map(\.score).max(), top >= 0.6 else { return nil }
        return scores.filter { $0.score >= top - 0.05 }
            .min { abs(CGFloat($0.index) - target) < abs(CGFloat($1.index) - target) }?.index
    }

    /// The x (in points) of a vertical edge near `x` that runs along `span` (a y range), if any.
    func snapX(_ x: CGFloat, along span: ClosedRange<CGFloat>) -> CGFloat? {
        guard span.upperBound - span.lowerBound >= 12 else { return nil }
        let r0 = row(span.upperBound), r1 = row(span.lowerBound)
        let rows = Array(stride(from: min(r0, r1), through: max(r0, r1), by: 2))
        let lo = max(1, col(x - Self.reach)), hi = min(width - 1, col(x + Self.reach))
        guard lo < hi, !rows.isEmpty else { return nil }
        let scores = (lo...hi).map { c -> (index: Int, score: Double) in
            let hits = rows.reduce(0) { $0 + (abs(at(c, $1) - at(c - 1, $1)) > Self.threshold ? 1 : 0) }
            return (c, Double(hits) / Double(rows.count))
        }
        return Self.pick(scores, near: x * scale).map { CGFloat($0) / scale }
    }

    /// The y (in points) of a horizontal edge near `y` that runs along `span` (an x range), if any.
    func snapY(_ y: CGFloat, along span: ClosedRange<CGFloat>) -> CGFloat? {
        guard span.upperBound - span.lowerBound >= 12 else { return nil }
        let c0 = col(span.lowerBound), c1 = col(span.upperBound)
        let cols = Array(stride(from: min(c0, c1), through: max(c0, c1), by: 2))
        let top = max(1, row(y + Self.reach)), bottom = min(height - 1, row(y - Self.reach))
        guard top < bottom, !cols.isEmpty else { return nil }
        let scores = (top...bottom).map { r -> (index: Int, score: Double) in
            let hits = cols.reduce(0) { $0 + (abs(at($1, r) - at($1, r - 1)) > Self.threshold ? 1 : 0) }
            return (r, Double(hits) / Double(cols.count))
        }
        // Pixel row r is the first row below the edge; back to points with a bottom-left origin.
        return Self.pick(scores, near: (CGFloat(height) / scale - y) * scale)
            .map { CGFloat(height) / scale - CGFloat($0) / scale }
    }
}

extension CaptureOptions {
    /// Snapping is on unless the user turned it off.
    static var snap: Bool {
        get { UserDefaults.standard.object(forKey: "snapToEdges") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "snapToEdges") }
    }
    /// Edges come from the screen picture taken by ScreenCaptureKit (macOS 14+).
    static var snapAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }
}
