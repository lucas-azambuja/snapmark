// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Model

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, ellipse, pencil, highlight, blur, text, counter

    /// SF Symbol name; nil means the icon is drawn by hand (see `IconButton`).
    var symbol: String? {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pencil: return "scribble"
        case .highlight: return "highlighter"
        case .blur: return nil
        case .text: return "textformat"
        case .counter: return "1.circle"
        }
    }
    var label: String {
        switch self {
        case .select: return "Select (V)"
        case .arrow: return "Arrow (A)"
        case .line: return "Line (L)"
        case .rect: return "Rectangle (R)"
        case .ellipse: return "Ellipse (O)"
        case .pencil: return "Pen (P)"
        case .highlight: return "Highlighter (H)"
        case .blur: return "Blur (B)"
        case .text: return "Text (T)"
        case .counter: return "Counter (N)"
        }
    }
    var key: String {
        switch self {
        case .select: return "v"
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
    /// Whether the color setting applies to this kind of annotation.
    var usesColor: Bool { self != .blur && self != .select }
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat          // in image pixels
    var points: [CGPoint]       // in image pixels (origin bottom-left)
    var text: String = ""
    var number: Int = 0
    var fontSize: CGFloat = 0   // in image pixels
}
