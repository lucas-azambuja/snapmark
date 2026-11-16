// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Preferences

/// The global capture shortcut.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    /// What the key itself shows as (e.g. "5", "A", "Space").
    var keyName: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: [.command, .shift], keyName: "5")

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// For showing the shortcut next to the menu item (only plain character keys).
    var menuKeyEquivalent: String { keyName.count == 1 ? keyName.lowercased() : "" }

    static func keyName(for e: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(e.keyCode)] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

enum ImageFormat: String {
    case png, jpeg
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum Preferences {
    private static let d = UserDefaults.standard

    static var shortcut: Shortcut {
        get {
            guard d.object(forKey: "shortcutKeyCode") != nil else { return .default }
            return Shortcut(keyCode: UInt32(d.integer(forKey: "shortcutKeyCode")),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "shortcutModifiers"))),
                            keyName: d.string(forKey: "shortcutKeyName") ?? "?")
        }
        set {
            d.set(Int(newValue.keyCode), forKey: "shortcutKeyCode")
            d.set(Int(newValue.modifiers.rawValue), forKey: "shortcutModifiers")
            d.set(newValue.keyName, forKey: "shortcutKeyName")
        }
    }

    private static func bool(_ key: String, default value: Bool) -> Bool { d.object(forKey: key) as? Bool ?? value }

    static var playSounds: Bool { get { bool("playSounds", default: true) } set { d.set(newValue, forKey: "playSounds") } }
    static var rememberArea: Bool { get { bool("rememberArea", default: true) } set { d.set(newValue, forKey: "rememberArea") } }
    static var showLoupe: Bool { get { bool("showLoupe", default: true) } set { d.set(newValue, forKey: "showLoupe") } }
    static var windowShadow: Bool { get { bool("windowShadow", default: false) } set { d.set(newValue, forKey: "windowShadow") } }
    static var recordCursor: Bool { get { bool("recordCursor", default: true) } set { d.set(newValue, forKey: "recordCursor") } }
    static var recordFPS: Int {
        get { [30, 60].contains(d.integer(forKey: "recordFPS")) ? d.integer(forKey: "recordFPS") : 60 }
        set { d.set(newValue, forKey: "recordFPS") }
    }
    static var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat") }
    }
    /// Folder for direct saves and the default in save panels.
    static var saveFolder: URL {
        get {
            if let p = d.string(forKey: "saveFolder") { return URL(fileURLWithPath: p) }
            if let p = d.string(forKey: "lastSaveDir") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }
    /// The last area captured, in global coordinates.
    static var lastArea: NSRect? {
        get { d.string(forKey: "lastArea").map { NSRectFromString($0) }.flatMap { $0.width >= 4 ? $0 : nil } }
        set { d.set(newValue.map { NSStringFromRect($0) }, forKey: "lastArea") }
    }
}

/// The capture "pop", unless sounds are off.
enum Sounds {
    static func pop() { if Preferences.playSounds { NSSound(named: "Pop")?.play() } }
}

// MARK: - Shortcut recorder

/// Click it, then press the new shortcut. Esc cancels; it needs at least one of ⌘ ⌃ ⌥.
final class ShortcutRecorder: PadControl {
    var shortcut: Shortcut { didSet { needsDisplay = true } }
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var recording = false { didSet { needsDisplay = true; onRecordingChange?(recording) } }
    private var monitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(size: NSSize(width: 170, height: 30))
        toolTip = "Click, then press the new shortcut"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return nil }
            let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods, keyName: Shortcut.keyName(for: e))
            self.shortcut = s
            self.onChange?(s)
            self.stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.white(recording ? 0.14 : hovering ? 0.1 : 0.06).setFill()
        path.fill()
        (recording ? Theme.accent : Theme.white(0.12)).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()
        let text = recording ? "Press shortcut…" : shortcut.display
        let t = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: recording ? 12 : 13, weight: .semibold),
            .foregroundColor: recording ? Theme.white(0.7) : NSColor.white,
        ])
        let ts = t.size()
        t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onShortcutChange: ((Shortcut) -> Void)?
    var onShortcutRecording: ((Bool) -> Void)?
    private let folderLabel = NSTextField(labelWithString: "")
    private var loginSwitch: NSSwitch!

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: win)
        win.title = "Snapmark Settings"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = build()
        if let fit = win.contentView?.fittingSize { win.setContentSize(NSSize(width: 560, height: fit.height)) }
        win.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Building blocks

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        l.textColor = .white
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = Theme.white(0.45)
        l.preferredMaxLayoutWidth = 260
        return l
    }

    private func toggle(_ on: Bool, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.target = self
        s.action = action
        s.controlSize = .small
        return s
    }

    private func section(_ title: String, _ rows: [(String, NSView, String?)]) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        for (name, control, hint) in rows {
            let left: NSView
            if let hint {
                let s = NSStackView(views: [label(name), note(hint)])
                s.orientation = .vertical
                s.alignment = .leading
                s.spacing = 2
                left = s
            } else {
                left = label(name)
            }
            grid.addRow(with: [left, control])
            grid.row(at: grid.numberOfRows - 1).yPlacement = .center
        }
        grid.column(at: 0).width = 300
        let panel = PanelView()
        panel.embed(grid, insets: NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18))
        let hug = grid.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)
        hug.priority = .defaultHigh
        hug.isActive = true
        let v = NSStackView(views: [Theme.sectionLabel(title), panel])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        return v
    }

    private func build() -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active

        let recorder = ShortcutRecorder(shortcut: Preferences.shortcut)
        recorder.onChange = { [weak self] s in
            Preferences.shortcut = s
            self?.onShortcutChange?(s)
        }
        recorder.onRecordingChange = { [weak self] r in self?.onShortcutRecording?(r) }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.toolTip = "Back to \(Shortcut.default.display)"
        reset.setContentCompressionResistancePriority(.required, for: .horizontal)
        let shortcutBox = NSStackView(views: [reset, recorder])
        shortcutBox.spacing = 8
        reset.tag = 99
        self.recorder = recorder

        loginSwitch = toggle(SMAppService.mainApp.status == .enabled, #selector(loginChanged(_:)))

        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ["PNG", "JPEG"])
        format.selectItem(at: Preferences.imageFormat == .png ? 0 : 1)
        format.target = self
        format.action = #selector(formatChanged(_:))
        format.controlSize = .small

        folderLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        folderLabel.textColor = Theme.white(0.7)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 130).isActive = true
        updateFolderLabel()
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.controlSize = .small
        let folderBox = NSStackView(views: [folderLabel, choose])
        folderBox.spacing = 8

        let fps = NSSegmentedControl(labels: ["30 fps", "60 fps"], trackingMode: .selectOne, target: self, action: #selector(fpsChanged(_:)))
        fps.selectedSegment = Preferences.recordFPS == 30 ? 0 : 1
        fps.controlSize = .small

        let general = section("General", [
            ("Capture shortcut", shortcutBox, "Starts a capture from anywhere. If it's taken, turn off the macOS one in Keyboard settings."),
            ("Launch at login", loginSwitch, nil),
            ("Play sounds", toggle(Preferences.playSounds, #selector(soundsChanged(_:))), nil),
            ("Check for updates", toggle(UpdateChecker.shared.automatic, #selector(updatesChanged(_:))),
             "Looks for new releases on GitHub once a day."),
        ])
        let capture = section("Capture", [
            ("Remember last area", toggle(Preferences.rememberArea, #selector(rememberChanged(_:))),
             "Starts with the previous selection, unless it was a whole screen."),
            ("Snap to edges", toggle(CaptureOptions.snap, #selector(snapChanged(_:))), "Also toggled with G while selecting."),
            ("Crosshair and loupe", toggle(Preferences.showLoupe, #selector(loupeChanged(_:))), nil),
            ("Window shadow", toggle(Preferences.windowShadow, #selector(shadowChanged(_:))),
             "Include the shadow when capturing a window."),
        ])
        let saving = section("Saving", [
            ("Save folder", folderBox, "Used by Save in the action bar, and suggested in save dialogs."),
            ("Image format", format, nil),
        ])
        let recording = section("Recording", [
            ("Frame rate", fps, nil),
            ("Show cursor", toggle(Preferences.recordCursor, #selector(cursorChanged(_:))), nil),
        ])

        let stack = NSStackView(views: [general, capture, saving, recording])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for v in [general, capture, saving, recording] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        return root
    }

    private var recorder: ShortcutRecorder?

    private func updateFolderLabel() {
        folderLabel.stringValue = Preferences.saveFolder.lastPathComponent
        folderLabel.toolTip = Preferences.saveFolder.path
    }

    // Actions

    @objc private func resetShortcut(_ sender: NSButton) {
        Preferences.shortcut = .default
        recorder?.shortcut = .default
        onShortcutChange?(.default)
    }
    @objc private func loginChanged(_ s: NSSwitch) {
        do {
            if s.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            s.state = SMAppService.mainApp.status == .enabled ? .on : .off
            if let win = window { NSAlert(error: error).beginSheetModal(for: win) }
        }
    }
    @objc private func soundsChanged(_ s: NSSwitch) { Preferences.playSounds = s.state == .on }
    @objc private func updatesChanged(_ s: NSSwitch) { UpdateChecker.shared.automatic = s.state == .on }
    @objc private func rememberChanged(_ s: NSSwitch) {
        Preferences.rememberArea = s.state == .on
        if s.state == .off { Preferences.lastArea = nil }
    }
    @objc private func snapChanged(_ s: NSSwitch) { CaptureOptions.snap = s.state == .on }
    @objc private func loupeChanged(_ s: NSSwitch) { Preferences.showLoupe = s.state == .on }
    @objc private func shadowChanged(_ s: NSSwitch) { Preferences.windowShadow = s.state == .on }
    @objc private func cursorChanged(_ s: NSSwitch) { Preferences.recordCursor = s.state == .on }
    @objc private func formatChanged(_ p: NSPopUpButton) { Preferences.imageFormat = p.indexOfSelectedItem == 0 ? .png : .jpeg }
    @objc private func fpsChanged(_ c: NSSegmentedControl) { Preferences.recordFPS = c.selectedSegment == 0 ? 30 : 60 }
    @objc private func chooseFolder() {
        guard let win = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Preferences.saveFolder
        panel.prompt = "Choose"
        panel.beginSheetModal(for: win) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Preferences.saveFolder = url
            self?.updateFolderLabel()
        }
    }

    func present() {
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
