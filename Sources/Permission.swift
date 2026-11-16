// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Tela de permissão

/// Ícone colorido do app, lido do .icns (o ícone do sistema pode vir na variante escura).
let brandIcon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    ?? NSApp.applicationIconImage ?? NSImage()

enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Registra o app na lista de Gravação de Tela (a primeira chamada mostra o aviso do macOS) e abre os Ajustes.
    static func openSettings() {
        let key = "requestedScreenCapture"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(settingsURL)
    }

    /// Fecha e abre o app de novo (o macOS só libera a captura depois de reabrir).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Texto com trechos em **negrito**.
private func richText(_ text: String, size: CGFloat, color: NSColor, align: NSTextAlignment = .left) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (i, part) in text.components(separatedBy: "**").enumerated() {
        out.append(NSAttributedString(string: part, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: i % 2 == 1 ? .semibold : .regular),
            .foregroundColor: i % 2 == 1 ? NSColor.white : color,
        ]))
    }
    let p = NSMutableParagraphStyle()
    p.lineSpacing = 2
    p.alignment = align
    out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
    return out
}

final class NumberBadge: NSView {
    let number: Int
    init(_ n: Int) {
        number = n
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.white(0.14).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let s = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }
}

/// Ilustração da linha do Snapmark nos Ajustes, com a chave ligando e desligando.
final class PermissionMockView: NSView {
    private let track = CALayer()
    private let knob = CALayer()
    private var on = false
    private var timer: Timer?
    static let size = NSSize(width: 420, height: 64)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        track.frame = CGRect(x: Self.size.width - 18 - 44, y: (Self.size.height - 26) / 2, width: 44, height: 26)
        track.cornerRadius = 13
        track.backgroundColor = Theme.white(0.18).cgColor
        knob.frame = CGRect(x: 2, y: 2, width: 22, height: 22)
        knob.cornerRadius = 11
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 0.3
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(track)
        track.addSublayer(knob)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: true) { [weak self] _ in self?.flip() }
    }

    func setOn(_ value: Bool) {
        on = value
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        track.backgroundColor = (on ? Theme.accent : Theme.white(0.18)).cgColor
        knob.frame.origin.x = on ? 20 : 2
        CATransaction.commit()
    }
    private func flip() { setOn(!on) }
    func stopAnimating(on value: Bool) {
        timer?.invalidate()
        timer = nil
        setOn(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let panel = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        Theme.white(0.06).setFill()
        panel.fill()
        Theme.white(0.1).setStroke()
        panel.stroke()
        brandIcon.draw(in: NSRect(x: 14, y: (bounds.height - 38) / 2, width: 38, height: 38))
        NSAttributedString(string: "Snapmark", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 62, y: bounds.midY + 1))
        NSAttributedString(string: "Privacy & Security › Screen Recording", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.white(0.45),
        ]).draw(at: NSPoint(x: 62, y: bounds.midY - 16))
    }
}

final class PermissionContentView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var timer: Timer?
    private let titleLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let mock = PermissionMockView()
    private var actions: NSStackView!
    private var doneButton: PillButton!

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: win)
        win.title = "Snapmark Permission"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = buildContent()
        let fit = win.contentView!.fittingSize
        win.setContentSize(NSSize(width: 520, height: max(fit.height, 520)))
        win.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: NSAttributedString, width: CGFloat, align: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = text
        f.alignment = align
        f.preferredMaxLayoutWidth = width
        f.isSelectable = false
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    private func buildContent() -> NSView {
        let root = PermissionContentView()

        let icon = NSImageView(image: brandIcon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        titleLabel.attributedStringValue = NSAttributedString(string: "One permission to go", attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let subtitle = label(richText("To capture your screen, macOS needs you to allow Snapmark under **Screen Recording**. It only takes a few seconds.",
                                      size: 13, color: Theme.white(0.62), align: .center), width: 400, align: .center)

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 14
        let texts = [
            "Click **Open Settings**.",
            "In **Screen Recording**, turn on **Snapmark**. If it already looks enabled, remove it with **–** and add it again with **+** (from the Applications folder).",
            "If macOS asks, click **Quit & Reopen**. If it doesn't, use **Restart Snapmark** below.",
        ]
        for (i, t) in texts.enumerated() {
            let row = NSStackView(views: [NumberBadge(i + 1), label(richText(t, size: 13, color: Theme.white(0.72)), width: 370)])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 12
            steps.addArrangedSubview(row)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        status.attributedStringValue = NSAttributedString(string: "Waiting for permission…", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.white(0.5),
        ])
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 8

        let restart = PillButton(title: "Restart Snapmark", symbol: "arrow.clockwise", hint: "", primary: false,
                                 target: self, action: #selector(restartApp))
        let open = PillButton(title: "Open Settings", symbol: "gearshape.fill", hint: "", primary: true,
                              target: self, action: #selector(openSettings))
        actions = NSStackView(views: [restart, open])
        actions.spacing = 12
        doneButton = PillButton(title: "Get Started", symbol: "checkmark", hint: "", primary: true,
                                target: self, action: #selector(finish))
        doneButton.isHidden = true

        let later = NSButton(title: "Not Now", target: self, action: #selector(finish))
        later.isBordered = false
        later.attributedTitle = NSAttributedString(string: "Not Now", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.white(0.45),
        ])

        let stack = NSStackView(views: [icon, titleLabel, subtitle, mock, steps, statusRow, actions, doneButton, later])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(26, after: mock)
        stack.setCustomSpacing(24, after: steps)
        stack.setCustomSpacing(16, after: statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
        ])
        return root
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if ScreenPermission.granted { self?.showGranted() }
        }
    }

    private func showGranted() {
        timer?.invalidate()
        timer = nil
        mock.stopAnimating(on: true)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        titleLabel.attributedStringValue = NSAttributedString(string: "You're all set!", attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white,
        ])
        status.attributedStringValue = NSAttributedString(string: "✓  Permission granted. Press ⌘⇧5 to capture.", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.accent,
        ])
        actions.isHidden = true
        doneButton.isHidden = false
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() { ScreenPermission.openSettings() }
    @objc private func restartApp() { ScreenPermission.relaunch() }
    @objc private func finish() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }
}
