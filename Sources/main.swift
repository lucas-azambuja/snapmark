// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import UniformTypeIdentifiers
import AVFoundation

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
    private var statusMenu: NSMenu?
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
        UpdateChecker.shared.onChange = { [weak self] in self?.updatesChanged() }
        UpdateChecker.shared.schedule()

        let args = CommandLine.arguments
        // Só para desenvolvimento: --snapshot <imagem> <saida.png> desenha o editor num PNG e sai.
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            snapshotEditor(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]))
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-overlay"), i + 2 < args.count,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let size = NSSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            let mode: CaptureMode = args.contains("--window") ? .window : args.contains("--screen") ? .screen : .area
            let locked = args.contains("--locked")
            SelectionController.renderPreview(snapshot: img, size: size,
                                              cursor: NSPoint(x: size.width * 0.4, y: size.height * 0.6),
                                              output: URL(fileURLWithPath: args[i + 2]), mode: mode,
                                              fakeWindow: NSRect(x: size.width * 0.15, y: size.height * 0.25,
                                                                 width: size.width * 0.55, height: size.height * 0.6),
                                              locked: locked)
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-thumb"), i + 2 < args.count,
           let img = NSImage(contentsOf: URL(fileURLWithPath: args[i + 1])) {
            let v = ThumbnailView(image: img, fileURL: URL(fileURLWithPath: args[i + 1]), caption: "Copied to clipboard",
                                  size: NSSize(width: 252, height: 154))
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
            }
            NSApp.terminate(nil)
            return
        }
        // Development only: checks edge snapping on a synthetic screen (a card at x 100–300, y 80–220 points).
        if args.contains("--version-test") {
            let pairs = [("0.1.0-alpha.3", "0.1.0-alpha.4"), ("0.1.0-alpha.9", "0.1.0-alpha.10"), ("0.1.0-alpha.4", "0.1.0"),
                         ("0.1.0", "0.1.1"), ("v0.1.0", "0.1.0"), ("0.1.0-alpha.2", "0.1.0-beta.1")]
            for (a, b) in pairs {
                let va = Version(a)!, vb = Version(b)!
                print(a, va < vb ? "<" : va == vb ? "=" : ">", b)
            }
            UpdateChecker.shared.check { u, e in
                print("current:", AppInfo.version, "· newest newer release:", u.map { "\($0.version)" } ?? "none", e.map { "error: \($0)" } ?? "")
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--snap-test") {
            let w = 800, h = 600   // 400 × 300 points at 2×
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1)); ctx.fill(CGRect(x: 200, y: 160, width: 400, height: 280))
            let map = EdgeMap(image: ctx.makeImage()!, pointWidth: 400)!
            func show(_ v: CGFloat?) -> String { v.map { String(format: "%.1f", $0) } ?? "none" }
            print("left   near 104 ->", show(map.snapX(104, along: 100...200)), "(expect 100)")
            print("right  near 295 ->", show(map.snapX(295, along: 100...200)), "(expect 300)")
            print("bottom near 84  ->", show(map.snapY(84, along: 120...280)), "(expect 80)")
            print("top    near 214 ->", show(map.snapY(214, along: 120...280)), "(expect 220)")
            print("no edge near 40 ->", show(map.snapX(40, along: 100...200)), "(expect none)")
            print("span misses card ->", show(map.snapX(104, along: 240...290)), "(expect none)")
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--ocr"), i + 1 < args.count,
           let img = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            TextRecognizer.recognize(img) { text in
                print(text)
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-recording"), i + 1 < args.count {
            let c = RecordingControlPanel(near: NSRect(x: 200, y: 400, width: 600, height: 300), sound: true, mic: true)
            c.startClock(from: Date().addingTimeInterval(-83))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let view = c.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-video"), i + 2 < args.count {
            let ed = VideoEditorWindowController(url: URL(fileURLWithPath: args[i + 1]),
                                                 trackNames: ["Desktop audio", "MacBook Pro Microphone"], from: nil)
            ed.prepareForDisplay()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            if let view = ed.window?.contentView {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
                }
            }
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            let w = SettingsWindowController()
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
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
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
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        // Shown only when a newer release exists.
        let upd = NSMenuItem(title: "", action: #selector(openUpdatePage), keyEquivalent: "")
        upd.target = self
        upd.isHidden = true
        menu.addItem(upd)
        updateItem = upd
        let updSeparator = NSMenuItem.separator()
        updSeparator.isHidden = true
        menu.addItem(updSeparator)
        updateSeparator = updSeparator
        let cap = NSMenuItem(title: "Capture Area", action: #selector(capture), keyEquivalent: "")
        captureItem = cap
        updateCaptureItem()
        cap.target = self
        menu.addItem(cap)
        let open = NSMenuItem(title: "Open Image in Editor…", action: #selector(openImage), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About Snapmark", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
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
        statusMenu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateCaptureItem()
    }

    private var captureItem: NSMenuItem?
    private var settingsWindow: SettingsWindowController?

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        applyShortcut(Preferences.shortcut)
    }

    /// (Re)registers the global capture shortcut.
    func applyShortcut(_ s: Shortcut) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let id = EventHotKeyID(signature: OSType(0x534E_4150), id: 1) // 'SNAP'
        hotKeyOK = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
        updateCaptureItem()
    }

    /// While the shortcut recorder listens, the current shortcut must not trigger a capture.
    private func suspendShortcut(_ suspended: Bool) {
        if suspended {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            hotKeyRef = nil
        } else {
            applyShortcut(Preferences.shortcut)
        }
    }

    private func updateCaptureItem() {
        guard let cap = captureItem else { return }
        let s = Preferences.shortcut
        cap.keyEquivalent = s.menuKeyEquivalent
        cap.keyEquivalentModifierMask = s.modifiers
        cap.title = hotKeyOK ? "Capture Area" : "Capture Area (\(s.display) unavailable)"
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = SettingsWindowController()
            w.onShortcutChange = { [weak self] s in self?.applyShortcut(s) }
            w.onShortcutRecording = { [weak self] r in self?.suspendShortcut(r) }
            settingsWindow = w
        }
        settingsWindow?.present()
    }

    @objc func capture() {
        if ScreenRecorder.isRecording { stopRecording(); return }
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
        case .capture(let target, let output, let delay) where delay > 0:
            // Give the screen back so menus and hovers can be set up during the countdown.
            sel.dismissImmediately()
            overlay = nil
            sel.restorePreviousApp()
            CountdownPanel.run(seconds: delay, centeredOn: target.frame) { [weak self] in
                self?.shoot(target, output: output, overlay: nil)
            }
        case .capture(let target, let output, _):
            shoot(target, output: output, overlay: sel)
        case .record(let target, let delay):
            sel.dismissImmediately()
            overlay = nil
            sel.restorePreviousApp()
            // Start capturing right away so the stream and audio are warmed up when the countdown ends.
            recordingReady = false
            countdownDone = false
            startRecording(target)
            CountdownPanel.run(seconds: max(delay, 3), centeredOn: target.frame) { [weak self] in
                self?.countdownDone = true
                self?.armIfReady(target)
            }
        }
    }

    /// Takes the still capture. When the overlay is still up, it only has to go first for full screens.
    private func shoot(_ target: CaptureTarget, output: CaptureOutput, overlay sel: SelectionController?) {
        let frame = target.frame
        let finish: (URL?) -> Void = { [weak self] url in
            self?.capturing = false
            if let sel {
                sel.dismiss(flash: url != nil) { self?.overlay = nil }
                if url == nil { sel.restorePreviousApp() }
            }
            guard let url else { return }
            self?.deliver(url, output: output, from: frame)
        }
        switch target {
        case .window(let id, _):
            // `-l` captures the window itself, so nothing on top matters; `-o` leaves out the shadow.
            runScreencapture(["-l", "\(id)"] + (Preferences.windowShadow ? [] : ["-o"]), done: finish)
        case .area(let r):
            runScreencapture(["-R", Self.region(r)], done: finish)
        case .screen(let r):
            sel?.dismissImmediately()
            if sel != nil { overlay = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.runScreencapture(["-R", Self.region(r)]) { url in
                    self.capturing = false
                    if let url { self.deliver(url, output: output, from: frame) } else { sel?.restorePreviousApp() }
                }
            }
        }
    }

    /// Opens the editor, or copies/saves straight away and shows the floating thumbnail.
    private func deliver(_ url: URL, output: CaptureOutput, from frame: NSRect) {
        switch output {
        case .edit:
            openEditor(url: url, deleteAfter: true, from: frame)
        case .copy:
            guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(data, forType: .png)
            if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            Sounds.pop()
            let file = QuickAccess.temporaryFile(png: data) ?? url
            try? FileManager.default.removeItem(at: url)
            QuickAccess.shared.show(image: img, fileURL: file, caption: "Copied to clipboard") { [weak self] u in
                self?.openEditor(url: u, deleteAfter: false)
            }
        case .text:
            guard let data = try? Data(contentsOf: url), let img = NSImage(data: data),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            try? FileManager.default.removeItem(at: url)
            TextRecognizer.recognize(cg) { text in
                guard !text.isEmpty else {
                    NSSound.beep()
                    QuickAccess.shared.show(image: img, fileURL: QuickAccess.temporaryFile(png: data) ?? url,
                                            caption: "No text found") { [weak self] u in
                        self?.openEditor(url: u, deleteAfter: false)
                    }
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Sounds.pop()
                let words = text.split { $0.isWhitespace || $0.isNewline }.count
                QuickAccess.shared.show(image: img, fileURL: QuickAccess.temporaryFile(png: data) ?? url,
                                        caption: "Text copied · \(words) word\(words == 1 ? "" : "s")") { [weak self] u in
                    self?.openEditor(url: u, deleteAfter: false)
                }
            }
        case .save:
            let format = Preferences.imageFormat
            let dest = Self.saveFolder().appendingPathComponent("Screenshot \(Self.timestamp()).\(format.fileExtension)")
            do {
                if format == .jpeg, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                    try jpg.write(to: dest)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.moveItem(at: url, to: dest)
                }
                Sounds.pop()
                guard let img = NSImage(contentsOf: dest) else { return }
                QuickAccess.shared.show(image: img, fileURL: dest, caption: "Saved") { [weak self] u in
                    self?.openEditor(url: u, deleteAfter: false)
                }
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    static func saveFolder() -> URL { Preferences.saveFolder }

    static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return fmt.string(from: Date())
    }

    // MARK: Recording

    private var recordingDim: [RecordingDimWindow] = []
    private var videoEditors: [VideoEditorWindowController] = []
    private var recordingControls: RecordingControlPanel?

    private func startRecording(_ target: CaptureTarget) {
        let begin = { [weak self] in
            ScreenRecorder.start(target: target, sound: CaptureOptions.sound, mic: CaptureOptions.mic) { error in
                guard let self else { return }
                self.capturing = false
                if let error {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert(error: error)
                    alert.messageText = "Couldn't start recording"
                    alert.runModal()
                    return
                }
                self.recordingReady = true
                self.armIfReady(target)
            }
        }
        if CaptureOptions.mic, CaptureOptions.micAvailable {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { begin() } }
        } else {
            begin()
        }
    }

    private var recordingReady = false
    private var countdownDone = false

    /// Begins writing once both the stream is running and the countdown is over.
    private func armIfReady(_ target: CaptureTarget) {
        guard recordingReady, countdownDone, let r = ScreenRecorder.current else { return }
        recordingReady = false
        r.arm()
        showRecordingUI(for: target)
    }

    private func showRecordingUI(for target: CaptureTarget) {
        recordingDim = RecordingDimWindow.cover(target.frame)
        recordingDim.forEach { $0.orderFrontRegardless() }
        let c = RecordingControlPanel(near: target.frame, sound: CaptureOptions.sound,
                                      mic: CaptureOptions.mic && CaptureOptions.micAvailable)
        c.onStop = { [weak self] in self?.stopRecording() }
        c.onDiscard = { [weak self] in self?.stopRecording(discard: true) }
        c.startClock(from: ScreenRecorder.current?.startDate ?? Date())
        c.orderFrontRegardless()
        recordingControls = c
        // While recording, clicking the menu bar icon stops it.
        statusItem.menu = nil
        statusItem.button?.image = Theme.symbol("stop.circle.fill", size: 15, weight: .regular, color: .systemRed)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(stopRecordingFromMenu)
    }

    @objc private func stopRecordingFromMenu() { stopRecording() }

    func stopRecording(discard: Bool = false) {
        guard let r = ScreenRecorder.current else { return }
        recordingDim.forEach { $0.orderOut(nil) }
        recordingControls?.orderOut(nil)
        recordingDim = []
        recordingControls = nil
        let names = r.audioTrackNames
        // `stop` ends the recording state right away, so restore the icon after it
        // (restoring first left the red recording icon in the menu bar).
        r.stop { [weak self] url in
            guard let self, let url else { return }
            if discard { try? FileManager.default.removeItem(at: url); return }
            // Review it before saving: preview, trim and audio tracks.
            let ed = VideoEditorWindowController(url: url, trackNames: names, from: r.target.frame)
            ed.onClose = { [weak self] e in self?.videoEditors.removeAll { $0 === e } }
            self.videoEditors.append(ed)
            ed.present()
        }
        restoreStatusItem()
    }

    private func restoreStatusItem() {
        statusItem.button?.action = nil
        statusItem.menu = statusMenu
        updateStatusIcon()
    }

    // MARK: Updates

    private var updateItem: NSMenuItem?
    private var updateSeparator: NSMenuItem?

    /// The menu bar icon, with a dot when an update is available.
    private func updateStatusIcon() {
        guard !ScreenRecorder.isRecording else { return }
        let base = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapmark")!
        base.isTemplate = true
        let img = UpdateChecker.shared.available == nil ? base : base.withBadge()
        img.accessibilityDescription = UpdateChecker.shared.available == nil ? "Snapmark" : "Snapmark — update available"
        statusItem.button?.image = img
    }

    private func updatesChanged() {
        let u = UpdateChecker.shared.available
        updateItem?.isHidden = u == nil
        updateSeparator?.isHidden = u == nil
        if let u {
            updateItem?.attributedTitle = NSAttributedString(string: "Update Available: \(u.version)…", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: Theme.accent,
            ])
            updateItem?.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        }
        updateStatusIcon()
    }

    @objc private func openUpdatePage() {
        NSWorkspace.shared.open(UpdateChecker.shared.available?.page ?? UpdateChecker.releasesPage)
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.check { update, error in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            if let error {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            } else if let update {
                alert.messageText = "Snapmark \(update.version) is available"
                alert.informativeText = "You have \(AppInfo.version). Download the new version from the releases page and replace the app in Applications."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.page) }
            } else {
                alert.messageText = "You're up to date"
                alert.informativeText = "Snapmark \(AppInfo.version) is the newest version."
                alert.runModal()
            }
        }
    }

    /// `screencapture -R` takes x,y,w,h in points with the origin at the top-left of the main display.
    private static func region(_ r: NSRect) -> String {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return "\(Int(r.minX)),\(Int(primaryHeight - r.maxY)),\(Int(r.width)),\(Int(r.height))"
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
