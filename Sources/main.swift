// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App

enum AppInfo {
    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
    static var version: String { info("SnapmarkVersion") ?? info("CFBundleShortVersionString") ?? "dev" }
    static var build: String { info("CFBundleVersion") ?? "0" }
    static var commit: String { info("SnapmarkCommit") ?? "local" }
    static var summary: String { "Version \(version) · build \(build) (\(commit))" }
}

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
    private var overlay: SelectionController?
    private var permissionWindow: PermissionWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        setupMainMenu()
        setupStatusItem()
        registerHotKey()

        let args = CommandLine.arguments
        // Só para desenvolvimento: --snapshot <imagem> <saida.png> desenha o editor num PNG e sai.
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            snapshotEditor(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]))
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-permission"), i + 1 < args.count {
            let w = PermissionWindowController()
            if let view = w.window?.contentView {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            NSApp.terminate(nil)
            return
        }
        if !ScreenPermission.granted { showPermissionWindow() }
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            openEditor(url: URL(fileURLWithPath: args[i + 1]), deleteAfter: false)
        }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapmark")
        img?.isTemplate = true
        img?.accessibilityDescription = "Snapmark"
        statusItem.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        let cap = NSMenuItem(title: "Capture Area", action: #selector(capture), keyEquivalent: "5")
        cap.keyEquivalentModifierMask = [.command, .shift]
        cap.target = self
        menu.addItem(cap)
        let open = NSMenuItem(title: "Open Image in Editor…", action: #selector(openImage), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Snapmark", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let version = NSMenuItem(title: AppInfo.summary, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let cap = menu.items.first {
            cap.title = hotKeyOK ? "Capture Area" : "Capture Area (⌘⇧5 shortcut unavailable)"
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
        guard ensureScreenCapturePermission() else { return }
        capturing = true
        let sel = SelectionController { [weak self] result in self?.handleSelection(result) }
        overlay = sel
        sel.begin()
    }

    private func handleSelection(_ result: SelectionResult) {
        guard let sel = overlay else { return }
        switch result {
        case .cancelled:
            sel.dismiss(flash: false) { [weak self] in
                self?.overlay = nil
                self?.capturing = false
            }
            sel.restorePreviousApp()
        case .window:
            // Barra de espaço: modo de captura de janela do próprio macOS.
            sel.dismissImmediately()
            overlay = nil
            runScreencapture(["-i", "-W"]) { [weak self] url in
                if let url { self?.openEditor(url: url, deleteAfter: true) } else { sel.restorePreviousApp() }
            }
        case .area(let r):
            // A área selecionada não tem overlay por cima, então dá para capturar
            // com o overlay ainda na tela e só depois animar a saída.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let region = "\(Int(r.minX)),\(Int(primaryHeight - r.maxY)),\(Int(r.width)),\(Int(r.height))"
            runScreencapture(["-R", region]) { [weak self] url in
                sel.dismiss(flash: url != nil) { self?.overlay = nil }
                if let url { self?.openEditor(url: url, deleteAfter: true, from: r) } else { sel.restorePreviousApp() }
            }
        }
    }

    private func runScreencapture(_ args: [String], done: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapmark-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args + ["-x", url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.capturing = false
                done(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            }
        }
        do { try p.run() } catch { capturing = false; NSSound.beep(); done(nil) }
    }

    /// Confere a permissão de Gravação de Tela; sem ela, mostra a tela explicando como liberar.
    private func ensureScreenCapturePermission() -> Bool {
        if ScreenPermission.granted { return true }
        showPermissionWindow()
        return false
    }

    func showPermissionWindow() {
        if permissionWindow == nil {
            let w = PermissionWindowController()
            w.onClose = { [weak self] in self?.permissionWindow = nil }
            permissionWindow = w
        }
        permissionWindow?.present()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Screenshot annotation for macOS.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/lucas-azambuja/snapmark", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/lucas-azambuja/snapmark")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Snapmark",
            .applicationVersion: AppInfo.version,
            .version: "Build \(AppInfo.build) · \(AppInfo.commit)",
            .credits: credits,
        ])
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

    private func snapshotEditor(input: URL, output: URL) {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              case let ed = EditorWindowController(image: img, pointScale: 2),
              let win = ed.window,
              let view = win.contentView else { return }
        ed.canvas.loadPreviewSample()
        ed.select(tool: .select)
        view.layoutSubtreeIfNeeded()
        view.layout()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
    }

    func openEditor(url: URL, deleteAfter: Bool, from source: NSRect? = nil) {
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
        ed.present(from: source)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
