// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import AVFoundation
import ScreenCaptureKit

// MARK: - Countdown before a delayed capture or a recording

final class CountdownPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var remaining = 0
    private var timer: Timer?

    /// Shows a countdown centered on `frame`, then hides itself and calls `done`.
    static func run(seconds: Int, centeredOn frame: NSRect, done: @escaping () -> Void) {
        let size = NSSize(width: 120, height: 120)
        let p = CountdownPanel(contentRect: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                                   width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 28
        bg.layer?.masksToBounds = true
        p.contentView = bg
        p.label.font = NSFont.monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        p.label.textColor = .white
        p.label.alignment = .center
        p.label.wantsLayer = true
        p.label.frame = NSRect(x: 0, y: 24, width: size.width, height: 70)
        bg.addSubview(p.label)
        p.remaining = seconds
        p.label.stringValue = "\(seconds)"
        p.orderFrontRegardless()
        p.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak p] t in
            guard let p else { t.invalidate(); return }
            p.remaining -= 1
            if p.remaining <= 0 {
                t.invalidate()
                p.orderOut(nil)
                // Give the window server a moment so the panel isn't in the capture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done() }
            } else {
                p.label.stringValue = "\(p.remaining)"
                p.label.layer?.add(Self.pop(), forKey: "pop")
            }
        }
    }

    private static func pop() -> CAAnimation {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.25
        a.toValue = 1
        a.duration = 0.25
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return a
    }
}

// MARK: - Screen recording (ScreenCaptureKit + AVAssetWriter)

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static private(set) var current: ScreenRecorder?
    static var isRecording: Bool { current != nil }

    let target: CaptureTarget
    let url: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    /// The stream runs during the countdown so capture and audio are warmed up; nothing is written until armed.
    private var armed = false
    private var lastFrame: CMSampleBuffer?
    private var sessionStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private let queue = DispatchQueue(label: "snapmark.recorder")
    private(set) var startDate = Date()
    /// Live levels (0…1) for the meters in the recording controls.
    private(set) var soundLevel: Float = 0
    private(set) var micLevel: Float = 0
    /// Names of the audio tracks, in the order they appear in the file.
    private(set) var audioTrackNames: [String] = []

    private init(target: CaptureTarget, url: URL) {
        self.target = target
        self.url = url
    }

    /// Starts recording. Calls `completion` on the main queue with an error, or nil once frames are flowing.
    static func start(target: CaptureTarget, sound: Bool, mic: Bool, completion: @escaping (Error?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapmark-\(UUID().uuidString).mp4")
        let r = ScreenRecorder(target: target, url: url)
        r.setUp(sound: sound, mic: mic) { err in
            DispatchQueue.main.async {
                if err == nil { current = r }
                completion(err)
            }
        }
    }

    private func setUp(sound: Bool, mic: Bool, completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content else { completion(error ?? Self.error("Couldn't list the screens.")); return }
            let me = content.applications.filter { $0.processID == getpid() }
            let primaryHeight = DispatchQueue.main.sync { NSScreen.screens.first?.frame.height ?? 0 }
            let cfg = SCStreamConfiguration()
            let filter: SCContentFilter
            var size = self.target.frame.size
            var scale: CGFloat = 2

            switch self.target {
            case .window(let id, let frame):
                guard let w = content.windows.first(where: { $0.windowID == id }) else {
                    completion(Self.error("That window is no longer available.")); return
                }
                filter = SCContentFilter(desktopIndependentWindow: w)
                scale = Self.scale(at: frame)
                size = frame.size
            case .area(let rect), .screen(let rect):
                // ScreenCaptureKit uses top-left global coordinates.
                let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
                guard let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: cgRect.midX, y: cgRect.midY)) })
                        ?? content.displays.first else {
                    completion(Self.error("Couldn't find the screen to record.")); return
                }
                filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                scale = Self.scale(at: rect)
                if case .area = self.target {
                    cfg.sourceRect = CGRect(x: cgRect.minX - d.frame.minX, y: cgRect.minY - d.frame.minY,
                                            width: cgRect.width, height: cgRect.height)
                }
            }
            // H.264 wants even dimensions.
            let w = Int(size.width * scale) / 2 * 2, h = Int(size.height * scale) / 2 * 2
            cfg.width = w
            cfg.height = h
            let fps = Preferences.recordFPS
            cfg.showsCursor = Preferences.recordCursor
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.queueDepth = 6
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.capturesAudio = sound
            cfg.excludesCurrentProcessAudio = true
            if #available(macOS 15.0, *) {
                cfg.captureMicrophone = mic
                if mic, let id = CaptureOptions.micDeviceID { cfg.microphoneCaptureDeviceID = id }
            }

            do {
                let writer = try AVAssetWriter(outputURL: self.url, fileType: .mp4)
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: w,
                    AVVideoHeightKey: h,
                    // Constant quality instead of a target bitrate: a bitrate-driven encoder starts cautious
                    // (blurry) and only sharpens after a second or two, which is very visible on screen content.
                    AVVideoCompressionPropertiesKey: [
                        AVVideoQualityKey: 0.8,
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoMaxKeyFrameIntervalKey: fps,
                        AVVideoMaxKeyFrameIntervalDurationKey: 1,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoAllowFrameReorderingKey: false,
                    ],
                ])
                video.expectsMediaDataInRealTime = true
                writer.add(video)
                self.videoInput = video
                func audio(channels: Int) -> AVAssetWriterInput {
                    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
                    ])
                    a.expectsMediaDataInRealTime = true
                    writer.add(a)
                    return a
                }
                if sound { self.audioInput = audio(channels: 2); self.audioTrackNames.append("Desktop audio") }
                if mic, CaptureOptions.micAvailable {
                    self.micInput = audio(channels: 1)
                    self.audioTrackNames.append(CaptureOptions.selectedMicrophone?.localizedName ?? "Microphone")
                }
                self.writer = writer

                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                if sound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue) }
                if mic, #available(macOS 15.0, *) {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.queue)
                }
                self.stream = stream
                stream.startCapture { err in completion(err) }
            } catch {
                completion(error)
            }
        }
    }

    private static func scale(at rect: NSRect) -> CGFloat {
        DispatchQueue.main.sync {
            let c = NSPoint(x: rect.midX, y: rect.midY)
            return (NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        }
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Snapmark", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sb), let writer else { return }
        switch type {
        case .screen:
            // Only complete frames carry new pixels.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            guard armed else { lastFrame = sb; return }
            guard sessionStarted else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard !lastVideoPTS.isValid || pts > lastVideoPTS else { return }
            if videoInput?.isReadyForMoreMediaData == true, videoInput?.append(sb) == true { lastVideoPTS = pts }
        case .audio:
            let l = audioLevel(of: sb)
            DispatchQueue.main.async { self.soundLevel = max(l, self.soundLevel * 0.8) }
            if sessionStarted, CMSampleBufferGetPresentationTimeStamp(sb) >= sessionStart,
               audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sb) }
        default:
            let l = audioLevel(of: sb)
            DispatchQueue.main.async { self.micLevel = max(l, self.micLevel * 0.8) }
            if sessionStarted, CMSampleBufferGetPresentationTimeStamp(sb) >= sessionStart,
               micInput?.isReadyForMoreMediaData == true { micInput?.append(sb) }
        }
    }

    /// Starts writing now. The latest frame seen during the countdown opens the movie, so it never starts
    /// black or frozen even if the screen doesn't change right away.
    func arm() {
        startDate = Date()
        queue.async {
            guard !self.armed, let writer = self.writer else { return }
            self.armed = true
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            writer.startWriting()
            writer.startSession(atSourceTime: now)
            self.sessionStart = now
            self.sessionStarted = true
            if let f = self.lastFrame {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: f, sampleTimingEntryCount: 1,
                                                      sampleTimingArray: &timing, sampleBufferOut: &copy)
                if let copy, self.videoInput?.append(copy) == true { self.lastVideoPTS = now }
            }
            self.lastFrame = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { AppDelegate.shared?.stopRecording() }
    }

    /// Stops and finishes the file. `completion` gets the movie URL, or nil if nothing was recorded.
    func stop(completion: @escaping (URL?) -> Void) {
        ScreenRecorder.current = nil
        let finish = {
            self.queue.async {
                guard let writer = self.writer, self.sessionStarted else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.finishWriting {
                    DispatchQueue.main.async { completion(writer.status == .completed ? self.url : nil) }
                }
            }
        }
        if let stream { stream.stopCapture { _ in finish() } } else { finish() }
    }
}

// MARK: - Recording controls

/// Keeps the capture dimming on screen while recording: everything but the recorded area is darker,
/// with the white corner marks around it. Clicks go through, and Snapmark's windows aren't recorded.
final class RecordingDimWindow: NSWindow {
    init(screen: NSRect, clear: NSRect) {
        super.init(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = DimView(clear: clear.offsetBy(dx: -screen.minX, dy: -screen.minY))
    }

    /// One window per screen.
    static func cover(_ clear: NSRect) -> [RecordingDimWindow] {
        NSScreen.screens.map { RecordingDimWindow(screen: $0.frame, clear: clear) }
    }
}

private final class DimView: NSView {
    let clear: NSRect
    init(clear: NSRect) {
        self.clear = clear
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: clear))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(Motion.dimAlpha).setFill()
        dim.fill()
        guard clear.intersects(bounds) else { return }
        // Corner marks, like the selection's.
        let r = clear.insetBy(dx: -4, dy: -4)
        let len = max(8, min(26, min(r.width, r.height) / 4)), radius = min(7, len / 2)
        let p = NSBezierPath()
        for (c, dx, dy) in [(NSPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (NSPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
                            (NSPoint(x: r.maxX, y: r.minY), -1.0, 1.0), (NSPoint(x: r.minX, y: r.minY), 1.0, 1.0)] {
            p.move(to: NSPoint(x: c.x, y: c.y + dy * len))
            p.line(to: NSPoint(x: c.x, y: c.y + dy * radius))
            p.curve(to: NSPoint(x: c.x + dx * radius, y: c.y), controlPoint1: c, controlPoint2: c)
            p.line(to: NSPoint(x: c.x + dx * len, y: c.y))
        }
        p.lineWidth = 3.5
        p.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        p.stroke()
    }
}

/// Floating pill: blinking dot, elapsed time, live audio meters, Discard and Stop.
final class RecordingControlPanel: NSPanel {
    private let content: RecordingControlView
    private var timer: Timer?
    var onStop: (() -> Void)? { didSet { content.onStop = onStop } }
    var onDiscard: (() -> Void)? { didSet { content.onDiscard = onDiscard } }

    init(near rect: NSRect, sound: Bool, mic: Bool) {
        content = RecordingControlView(sound: sound, mic: mic)
        let size = content.frame.size
        let screen = (NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
            ?? NSScreen.main)?.visibleFrame ?? rect
        var y = rect.minY - size.height - 16
        if y < screen.minY + 8 { y = rect.maxY + 16 }
        if y + size.height > screen.maxY - 8 { y = screen.minY + 24 }
        let x = min(max(rect.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        super.init(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        bg.addSubview(content)
        contentView = bg
    }

    func startClock(from start: Date) {
        content.start = start
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            if let r = ScreenRecorder.current { self?.content.levels = (r.soundLevel, r.micLevel) }
            self?.content.needsDisplay = true
        }
    }

    override func orderOut(_ sender: Any?) {
        timer?.invalidate()
        super.orderOut(sender)
    }
}

private final class RecordingControlView: NSView {
    var start = Date()
    var levels: (sound: Float, mic: Float) = (0, 0)
    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?
    private let sound: Bool, mic: Bool
    private var hovered: Int?   // 0 discard, 1 stop
    private var discardRect = NSRect.zero, stopRect = NSRect.zero
    private var meterRects: [(symbol: String, rect: NSRect, isMic: Bool)] = []
    private let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)

    init(sound: Bool, mic: Bool) {
        self.sound = sound
        self.mic = mic
        let h: CGFloat = 46
        var x: CGFloat = 18 + 10 + 10 + 48 + 8      // dot, gap, time
        var meters: [(String, NSRect, Bool)] = []
        if sound { meters.append(("speaker.wave.2.fill", NSRect(x: x, y: 0, width: 46, height: h), false)); x += 50 }
        if mic { meters.append(("mic.fill", NSRect(x: x, y: 0, width: 46, height: h), true)); x += 50 }
        x += 4
        let discard = NSRect(x: x, y: 7, width: 32, height: 32)
        x += 32 + 6
        let stopTitle = NSAttributedString(string: "Stop", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        let stop = NSRect(x: x, y: 7, width: ceil(12 + 11 + 6 + stopTitle.size().width + 14), height: 32)
        x = stop.maxX + 7
        super.init(frame: NSRect(x: 0, y: 0, width: x, height: h))
        meterRects = meters.map { (symbol: $0.0, rect: $0.1, isMic: $0.2) }
        discardRect = discard
        stopRect = stop
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func hit(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return discardRect.contains(p) ? 0 : stopRect.contains(p) ? 1 : nil
    }
    override func mouseMoved(with event: NSEvent) { hovered = hit(event); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if hit(event) == nil { window?.performDrag(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        switch hit(event) {
        case 0: onDiscard?()
        case 1: onStop?()
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let elapsed = Date().timeIntervalSince(start)
        // Blinking dot.
        let blink = CGFloat(0.55 + 0.45 * cos(elapsed * .pi * 1.25))
        NSColor.systemRed.withAlphaComponent(blink).setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: bounds.midY - 5, width: 10, height: 10)).fill()

        let s = Int(elapsed)
        let t = NSAttributedString(string: String(format: "%d:%02d", s / 60, s % 60),
                                   attributes: [.font: timeFont, .foregroundColor: NSColor.white])
        t.draw(at: NSPoint(x: 38, y: bounds.midY - t.size().height / 2))

        for m in meterRects {
            if let icon = Theme.symbol(m.symbol, size: 11, weight: .semibold, color: Theme.white(0.75)) {
                icon.draw(in: NSRect(x: m.rect.minX, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            }
            CaptureToolbar.drawMeter(level: m.isMic ? levels.mic : levels.sound,
                                     in: NSRect(x: m.rect.minX + 18, y: bounds.midY - 8, width: 24, height: 16))
        }

        let d = NSBezierPath(roundedRect: discardRect, xRadius: 16, yRadius: 16)
        Theme.white(hovered == 0 ? 0.16 : 0.08).setFill()
        d.fill()
        Theme.drawCentered(Theme.symbol("trash", size: 12, weight: .semibold, color: .white), in: discardRect)

        let p = NSBezierPath(roundedRect: stopRect, xRadius: 16, yRadius: 16)
        NSColor.systemRed.setFill()
        p.fill()
        if hovered == 1 { Theme.white(0.14).setFill(); p.fill() }
        if let icon = Theme.symbol("stop.fill", size: 11, weight: .semibold, color: .white) {
            icon.draw(in: NSRect(x: stopRect.minX + 12, y: stopRect.midY - icon.size.height / 2,
                                 width: icon.size.width, height: icon.size.height))
        }
        let title = NSAttributedString(string: "Stop", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        title.draw(at: NSPoint(x: stopRect.minX + 12 + 11 + 6, y: stopRect.midY - title.size().height / 2))
    }
}
