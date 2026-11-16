// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Editor layout

final class EditorContentView: NSVisualEffectView {
    let left: PanelView
    let right: PanelView
    let bottom: PanelView
    let canvas: CanvasView
    let natural: NSSize
    private let canvasShadow = NSView()

    static let margin: CGFloat = 14
    static let topInset: CGFloat = 40      // room for the window buttons
    static let bottomHeight: CGFloat = 58

    init(left: PanelView, right: PanelView, bottom: PanelView, canvas: CanvasView, natural: NSSize) {
        self.left = left
        self.right = right
        self.bottom = bottom
        self.canvas = canvas
        self.natural = natural
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        canvasShadow.wantsLayer = true
        canvasShadow.layer?.backgroundColor = NSColor.black.cgColor
        canvasShadow.layer?.cornerRadius = 10
        canvasShadow.layer?.shadowColor = NSColor.black.cgColor
        canvasShadow.layer?.shadowOpacity = 0.5
        canvasShadow.layer?.shadowRadius = 24
        canvasShadow.layer?.shadowOffset = CGSize(width: 0, height: -8)
        [left, right, bottom, canvasShadow, canvas].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var leftWidth: CGFloat { left.fittingSize.width }
    var rightSize: NSSize { right.fittingSize }

    /// Space the interface takes around the image.
    var chrome: NSSize {
        let m = Self.margin
        return NSSize(width: leftWidth + rightSize.width + m * 4 + 16,
                      height: Self.topInset + Self.bottomHeight + m * 2 + 16)
    }
    var minimumSize: NSSize {
        NSSize(width: chrome.width + 360,
               height: max(left.fittingSize.height + Self.topInset + Self.margin, chrome.height + 240))
    }

    override func layout() {
        super.layout()
        let m = Self.margin
        let top = bounds.height - Self.topInset
        let lh = min(left.fittingSize.height, top - m)
        left.frame = NSRect(x: m, y: top - lh, width: leftWidth, height: lh)
        let rs = rightSize
        right.frame = NSRect(x: bounds.width - m - rs.width, y: top - rs.height, width: rs.width, height: rs.height)
        let midX = left.frame.maxX + m
        let midW = right.frame.minX - m - midX
        bottom.frame = NSRect(x: midX, y: m, width: max(0, midW), height: Self.bottomHeight)

        let area = NSRect(x: midX, y: bottom.frame.maxY + m, width: midW, height: top - bottom.frame.maxY - m)
            .insetBy(dx: 8, dy: 8)
        guard area.width > 10, area.height > 10 else { return }
        let s = min(1, area.width / natural.width, area.height / natural.height)
        let w = floor(natural.width * s), h = floor(natural.height * s)
        canvas.frame = NSRect(x: floor(area.midX - w / 2), y: floor(area.midY - h / 2), width: w, height: h)
        canvasShadow.frame = canvas.frame
    }
}

final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if firstResponder is NSTextView {
            // Return while editing text confirms the text instead of triggering Copy.
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

// MARK: - Editor window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?
    private var toolButtons: [IconButton] = []
    private var colorDots: [ColorDot] = []
    private var customDot: ColorDot!
    private var strokeButtons: [StrokeButton] = []
    private var deleteButton: IconButton!
    private var finished = false

    static let palette: [(NSColor, String)] = [
        (.systemRed, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"),
        (.systemGreen, "Green"), (.systemBlue, "Blue"), (.systemPurple, "Purple"),
        (.black, "Black"), (.white, "White"),
    ]
    static let widths: [(CGFloat, CGFloat, String)] = [   // (actual width, preview width, name)
        (2, 1.5, "Thin"), (4, 3, "Medium"), (7, 5, "Thick"), (12, 8, "Extra thick"),
    ]

    init(image: CGImage, pointScale: CGFloat) {
        canvas = CanvasView(image: image, pointScale: pointScale)
        let natural = NSSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        let win = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        super.init(window: win)
        win.editor = self
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.title = "Snapmark"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.tabbingMode = .disallowed

        let content = EditorContentView(left: buildLeftPanel(), right: buildRightPanel(),
                                        bottom: buildBottomBar(pixelSize: NSSize(width: image.width, height: image.height)),
                                        canvas: canvas, natural: natural)
        win.contentView = content

        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minSize = content.minimumSize
        let chrome = content.chrome
        let w = min(max(natural.width + chrome.width, minSize.width), screen.width * 0.94)
        let h = min(max(natural.height + chrome.height, minSize.height), screen.height * 0.94)
        win.setContentSize(NSSize(width: w, height: h))
        win.contentMinSize = minSize
        win.setFrameOrigin(NSPoint(x: screen.midX - win.frame.width / 2, y: screen.midY - win.frame.height / 2))

        canvas.onToolKey = { [weak self] t in self?.select(tool: t) }
        canvas.onEscape = { [weak self] in self?.window?.performClose(nil) }
        canvas.onReturn = { [weak self] in self?.copyImage() }
        canvas.onSelectionChange = { [weak self] a in self?.reflect(a) }
        select(tool: .arrow)
        showColor(Self.palette[0].0)
        canvas.color = Self.palette[0].0
        pickWidth(1)
        reflect(nil)
        win.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Panels

    private func grid(_ views: [NSView], columns: Int, spacing: CGFloat) -> NSGridView {
        var rows: [[NSView]] = []
        var i = 0
        while i < views.count {
            var row = Array(views[i..<min(i + columns, views.count)])
            while row.count < columns { row.append(NSGridCell.emptyContentView) }
            rows.append(row)
            i += columns
        }
        let g = NSGridView(views: rows)
        g.rowSpacing = spacing
        g.columnSpacing = spacing
        return g
    }

    private func buildLeftPanel() -> PanelView {
        for (i, (c, name)) in Self.palette.enumerated() {
            let d = ColorDot(color: c, tooltip: name, target: self, action: #selector(colorClicked(_:)))
            d.tag = i
            colorDots.append(d)
        }
        customDot = ColorDot(color: .systemPink, custom: true, tooltip: "Custom color…",
                             target: self, action: #selector(customColorClicked))
        let colors = grid(colorDots + [customDot], columns: 3, spacing: 10)

        for t in Tool.allCases {
            let b = IconButton(symbol: t.symbol, size: 54, iconSize: 20, tooltip: t.label,
                               target: self, action: #selector(toolClicked(_:)))
            b.tag = t.rawValue
            toolButtons.append(b)
        }
        let tools = grid(toolButtons, columns: 2, spacing: 8)

        let stack = NSStackView(views: [Theme.sectionLabel("Colors"), colors, Theme.sectionLabel("Tools"), tools])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: colors)
        let panel = PanelView()
        panel.embed(stack, insets: NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16))
        return panel
    }

    private func buildRightPanel() -> PanelView {
        for (i, w) in Self.widths.enumerated() {
            let b = StrokeButton(previewWidth: w.1, tooltip: w.2, target: self, action: #selector(widthClicked(_:)))
            b.tag = i
            strokeButtons.append(b)
        }
        let label = Theme.sectionLabel("Stroke")
        let stack = NSStackView(views: [label] + strokeButtons)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(12, after: label)
        let panel = PanelView()
        panel.embed(stack, insets: NSEdgeInsets(top: 18, left: 12, bottom: 14, right: 12))
        return panel
    }

    private func buildBottomBar(pixelSize: NSSize) -> PanelView {
        deleteButton = IconButton(symbol: "trash", size: 38, iconSize: 14, tooltip: "Delete selection (⌫)",
                                  target: self, action: #selector(deleteAction))
        let info = NSTextField(labelWithString: "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
        info.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        info.textColor = Theme.white(0.4)
        let save = PillButton(title: "Save", symbol: "square.and.arrow.down", hint: "⌘S", primary: false,
                              target: self, action: #selector(saveImage))
        save.toolTip = "Save as PNG or JPEG"
        let copy = PillButton(title: "Copy", symbol: "doc.on.doc", hint: "⌘C", primary: true,
                              target: self, action: #selector(copyImage))
        copy.toolTip = "Copy to the clipboard and close (Return)"

        let s1 = NSView(), s2 = NSView()
        for s in [s1, s2] {
            s.setContentHuggingPriority(.init(1), for: .horizontal)
            s.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let stack = NSStackView(views: [deleteButton, s1, info, s2, save, copy])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(10, after: save)
        s1.widthAnchor.constraint(equalTo: s2.widthAnchor).isActive = true
        let panel = PanelView()
        panel.layer?.cornerRadius = 22
        panel.embed(stack, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        return panel
    }

    // MARK: State

    func select(tool: Tool) {
        canvas.tool = tool
        for b in toolButtons { b.isSelected = (b.tag == tool.rawValue) }
    }

    /// Highlights a color in the palette (or the custom dot) without changing anything.
    private func showColor(_ c: NSColor) {
        let i = Self.palette.firstIndex { $0.0 == c }
        for d in colorDots { d.isSelected = (d.tag == i) }
        if i == nil { customDot.color = c }
        customDot.isSelected = (i == nil)
        strokeButtons.forEach { $0.color = c }
    }

    private func showWidth(_ index: Int) {
        for b in strokeButtons { b.isSelected = (b.tag == index) }
    }

    private func setColor(_ c: NSColor) {
        showColor(c)
        canvas.applyColor(c)
    }

    private func pickWidth(_ i: Int) {
        showWidth(i)
        canvas.applyStroke(Self.widths[i].0)
    }

    /// Updates the side panels to match the selected annotation.
    private func reflect(_ a: Annotation?) {
        deleteButton.isEnabled = a != nil
        deleteButton.alphaValue = a == nil ? 0.35 : 1
        guard let a else { return }
        if a.tool.usesColor {
            showColor(a.color)
            canvas.color = a.color
        }
        let pt: CGFloat = (a.tool == .text || a.tool == .counter)
            ? (a.fontSize / canvas.pointScale - 12) / 2.5
            : a.width / canvas.pointScale
        if let i = Self.widths.indices.min(by: { abs(Self.widths[$0].0 - pt) < abs(Self.widths[$1].0 - pt) }) {
            showWidth(i)
            canvas.strokePt = Self.widths[i].0
        }
    }

    @objc private func toolClicked(_ b: IconButton) {
        if let t = Tool(rawValue: b.tag) { select(tool: t) }
        window?.makeFirstResponder(canvas)
    }
    @objc private func colorClicked(_ d: ColorDot) { setColor(Self.palette[d.tag].0) }
    @objc private func customColorClicked() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = customDot.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
        setColor(customDot.color)
    }
    @objc private func colorPanelChanged(_ p: NSColorPanel) { setColor(p.color) }
    @objc private func widthClicked(_ b: StrokeButton) {
        pickWidth(b.tag)
        window?.makeFirstResponder(canvas)
    }
    @objc private func deleteAction() {
        canvas.deleteSelection()
        window?.makeFirstResponder(canvas)
    }

    // MARK: Output

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
        if let url = QuickAccess.temporaryFile(png: png) {
            showThumbnail(rep, fileURL: url, caption: "Copied to clipboard")
        }
    }

    private func showThumbnail(_ rep: NSBitmapImageRep, fileURL: URL, caption: String) {
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        QuickAccess.shared.show(image: img, fileURL: fileURL, caption: caption) { url in
            AppDelegate.shared?.openEditor(url: url, deleteAfter: false)
        }
    }

    @objc func saveImage() {
        guard let win = window, let rep = canvas.renderFinal() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
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
                self?.showThumbnail(rep, fileURL: url, caption: "Saved")
            } catch {
                NSAlert(error: error).beginSheetModal(for: win)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished || !canvas.hasAnnotations { return true }
        let alert = NSAlert()
        alert.messageText = "Discard your annotations?"
        alert.informativeText = "This image hasn't been saved or copied."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
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

    /// Shows the editor. With `source` (the captured area, in screen coordinates),
    /// the window grows out of it.
    func present(from source: NSRect?) {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let src = source, src.width > 1, src.height > 1 else {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let final = win.frame
        win.alphaValue = 0
        win.setFrame(src, display: false)
        win.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.editorZoom
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            win.animator().setFrame(final, display: true)
            win.animator().alphaValue = 1
        }
    }
}
