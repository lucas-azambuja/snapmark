// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - Review a recording: preview, trim, audio tracks, save

/// Peak levels (0…1) of an audio track, in `count` evenly spaced buckets.
func waveformPeaks(of track: AVAssetTrack, in asset: AVAsset, count: Int) -> [Float] {
    guard let reader = try? AVAssetReader(asset: asset) else { return [] }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000,
    ])
    guard reader.canAdd(out) else { return [] }
    reader.add(out)
    reader.startReading()
    let total = max(1, Int(asset.duration.seconds * 48_000))
    let perBucket = max(1, total / count)
    var peaks = [Float](repeating: 0, count: count)
    var index = 0
    while let sb = out.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr, let ptr else { continue }
        let n = length / 4
        ptr.withMemoryRebound(to: Float.self, capacity: n) { f in
            for i in 0..<n {
                let b = min(count - 1, index / perBucket)
                peaks[b] = max(peaks[b], abs(f[i]))
                index += 1
            }
        }
    }
    // Normalize gently so quiet tracks are still visible.
    let top = max(peaks.max() ?? 0, 0.05)
    return peaks.map { min(1, $0 / top) }
}

/// Bars for a track's waveform, scaled by its volume, with the trimmed-out parts and the playhead.
final class WaveformView: NSView {
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var volume: Float = 1 { didSet { needsDisplay = true } }
    var muted = false { didSet { needsDisplay = true } }
    /// Fractions of the duration (0…1).
    var trim: ClosedRange<CGFloat> = 0...1 { didSet { if trim != oldValue { needsDisplay = true } } }
    var playhead: CGFloat = 0 { didSet { if abs(playhead - oldValue) > 0.0005 { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let bg = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.white(0.04).setFill()
        bg.fill()
        guard !peaks.isEmpty else {
            let t = NSAttributedString(string: "Reading audio…", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.white(0.35),
            ])
            t.draw(at: NSPoint(x: r.minX + 10, y: r.midY - t.size().height / 2))
            return
        }
        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        let barW: CGFloat = 2, gap: CGFloat = 1
        let n = Int(r.width / (barW + gap))
        let gain = CGFloat(muted ? 0 : min(volume, 1))
        for i in 0..<n {
            let f = CGFloat(i) / CGFloat(max(n - 1, 1))
            let p = CGFloat(peaks[min(peaks.count - 1, Int(f * CGFloat(peaks.count - 1)))])
            let h = max(1.5, (r.height - 10) * p * max(gain, 0.08))
            let inside = trim.contains(f)
            let color: NSColor = muted ? Theme.white(0.14) : inside ? NSColor.white.withAlphaComponent(0.25 + 0.6 * gain) : Theme.white(0.15)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(i) * (barW + gap), y: r.midY - h / 2, width: barW, height: h),
                         xRadius: 1, yRadius: 1).fill()
        }
        // Dim the parts that will be trimmed away.
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width * trim.lowerBound, height: r.height).fill()
        NSRect(x: r.minX + r.width * trim.upperBound, y: r.minY, width: r.width * (1 - trim.upperBound), height: r.height).fill()
        // Playhead.
        Theme.accent.setFill()
        NSRect(x: r.minX + r.width * playhead - 0.75, y: r.minY, width: 1.5, height: r.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class AudioTrackRow: NSStackView {
    let track: AVAssetTrack
    let waveform = WaveformView()
    private(set) var volume: Float = 1
    private(set) var muted = false
    var onChange: (() -> Void)?
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "100%")
    private var muteButton: IconButton!

    init(track: AVAssetTrack, name: String, symbol: String) {
        self.track = track
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 12
        alignment = .centerY

        let icon = NSImageView(image: Theme.symbol(symbol, size: 14, weight: .semibold, color: Theme.white(0.8)) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = NSTextField(labelWithString: name)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        muteButton = IconButton(symbol: "speaker.wave.2.fill", size: 30, iconSize: 12, tooltip: "Mute this track",
                                target: self, action: #selector(toggleMute))
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.heightAnchor.constraint(equalToConstant: 40).isActive = true
        waveform.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        waveform.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.target = self
        slider.action = #selector(volumeChanged)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        percent.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percent.textColor = Theme.white(0.5)
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        [icon, label, muteButton, waveform, slider, percent].forEach { addArrangedSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var effectiveVolume: Float { muted ? 0 : volume }

    @objc private func toggleMute() {
        muted.toggle()
        muteButton.symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.isSelected = muted
        muteButton.toolTip = muted ? "Unmute this track" : "Mute this track"
        slider.isEnabled = !muted
        percent.textColor = Theme.white(muted ? 0.25 : 0.5)
        waveform.muted = muted
        onChange?()
    }

    @objc private func volumeChanged() {
        volume = Float(slider.doubleValue)
        percent.stringValue = "\(Int((volume * 100).rounded()))%"
        waveform.volume = volume
        onChange?()
    }
}

final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let trimmer = TrimmerView()
    private lazy var seeker = SeekChaser(player: player)
    private var playButton: IconButton!
    private let timeLabel = NSTextField(labelWithString: "")
    private var rows: [AudioTrackRow] = []
    private let tracksStack = NSStackView()
    private let info = NSTextField(labelWithString: "")
    private var saveButton: PillButton!
    private var trimSaveButton: PillButton!
    private var finished = false
    private var saving = false
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var thumbnailWidth: CGFloat = 0
    private lazy var totalSeconds: Double = max(asset.duration.seconds, 0.01)
    var onClose: ((VideoEditorWindowController) -> Void)?

    /// `trackNames` names the audio tracks in file order (e.g. ["Desktop audio", "MacBook Pro Microphone"]).
    init(url: URL, trackNames: [String], from source: NSRect?) {
        self.url = url
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        super.init(window: win)
        win.title = "Recording"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentMinSize = NSSize(width: 720, height: 560)
        win.contentView = buildContent()
        win.center()

        playerView.player = player
        trimmer.duration = totalSeconds
        trimmer.onTrim = { [weak self] lo, hi, edge in self?.trimChanged(lo, hi, edge: edge) }
        trimmer.onScrub = { [weak self] f, done in self?.scrub(to: f, done: done) }
        asset.loadTracks(withMediaType: .audio) { [weak self] tracks, _ in
            DispatchQueue.main.async { self?.setUpTracks(tracks ?? [], names: trackNames) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.syncPlayhead()
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.playButton.symbol = p.timeControlStatus == .paused ? "play.fill" : "pause.fill"
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window, !(e.window?.firstResponder is NSTextView) else { return e }
            if e.keyCode == 49 { self.togglePlay(); return nil }                        // Space
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "s" { self.save(); return nil }
            return e
        }
        updateInfo()
        syncPlayhead()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active

        playerView.controlsStyle = .none
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 12
        playerView.layer?.masksToBounds = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.setContentHuggingPriority(.init(1), for: .vertical)
        playerView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePlay)))

        // Transport: play/pause, the trim bar, and the time.
        playButton = IconButton(symbol: "play.fill", size: 40, iconSize: 15, tooltip: "Play / Pause (Space)",
                                target: self, action: #selector(togglePlay))
        trimmer.translatesAutoresizingMaskIntoConstraints = false
        trimmer.heightAnchor.constraint(equalToConstant: 60).isActive = true
        trimmer.setContentHuggingPriority(.init(1), for: .horizontal)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = Theme.white(0.7)
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let transport = NSStackView(views: [playButton, trimmer, timeLabel])
        transport.orientation = .horizontal
        transport.spacing = 12
        let transportPanel = PanelView()
        transportPanel.embed(transport, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 16))
        transportPanel.translatesAutoresizingMaskIntoConstraints = false

        tracksStack.orientation = .vertical
        tracksStack.alignment = .leading
        tracksStack.spacing = 10
        let tracksPanel = PanelView()
        let header = Theme.sectionLabel("Audio tracks")
        let inner = NSStackView(views: [header, tracksStack])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        tracksPanel.embed(inner, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        tracksStack.translatesAutoresizingMaskIntoConstraints = false
        tracksStack.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        tracksPanel.translatesAutoresizingMaskIntoConstraints = false
        // The panels hug their content; the player takes the rest of the height.
        let hug = inner.bottomAnchor.constraint(equalTo: tracksPanel.bottomAnchor, constant: -14)
        hug.priority = .defaultHigh
        hug.isActive = true

        info.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        info.textColor = Theme.white(0.5)
        let discard = PillButton(title: "Discard", symbol: "trash", hint: "", primary: false, target: self, action: #selector(discard))
        saveButton = PillButton(title: "Save", symbol: "square.and.arrow.down", hint: "⌘S", primary: true,
                                target: self, action: #selector(save))
        trimSaveButton = PillButton(title: "Trim and Save", symbol: "scissors", hint: "⌘S", primary: true,
                                    target: self, action: #selector(save))
        trimSaveButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [info, spacer, discard, saveButton, trimSaveButton])
        bottom.orientation = .horizontal
        bottom.spacing = 12
        let bar = PanelView()
        bar.layer?.cornerRadius = 22
        bar.embed(bottom, insets: NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 10))
        bar.translatesAutoresizingMaskIntoConstraints = false

        [playerView, transportPanel, tracksPanel, bar].forEach { root.addSubview($0) }
        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            transportPanel.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 12),
            transportPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            transportPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            transportPanel.heightAnchor.constraint(equalToConstant: 80),
            tracksPanel.topAnchor.constraint(equalTo: transportPanel.bottomAnchor, constant: 12),
            tracksPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            tracksPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            bar.topAnchor.constraint(equalTo: tracksPanel.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
            bar.heightAnchor.constraint(equalToConstant: 58),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        return root
    }

    private func setUpTracks(_ tracks: [AVAssetTrack], names: [String]) {
        if tracks.isEmpty {
            let none = NSTextField(labelWithString: "This recording has no audio. Turn on system audio or the microphone in the Video controls to record sound.")
            none.font = NSFont.systemFont(ofSize: 12)
            none.textColor = Theme.white(0.5)
            tracksStack.addArrangedSubview(none)
            return
        }
        for (i, t) in tracks.enumerated() {
            let name = i < names.count ? names[i] : "Audio track \(i + 1)"
            let symbol = name == "Desktop audio" ? "speaker.wave.2.fill" : "mic.fill"
            let row = AudioTrackRow(track: t, name: name, symbol: symbol)
            row.onChange = { [weak self] in self?.applyMix() }
            rows.append(row)
            tracksStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tracksStack.widthAnchor).isActive = true
            let asset = self.asset
            DispatchQueue.global(qos: .userInitiated).async {
                let peaks = waveformPeaks(of: t, in: asset, count: 600)
                DispatchQueue.main.async { row.waveform.peaks = peaks }
            }
        }
        syncPlayhead()
    }

    private func audioMix() -> AVAudioMix? {
        guard !rows.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = rows.map { r in
            let p = AVMutableAudioMixInputParameters(track: r.track)
            p.setVolume(r.effectiveVolume, at: .zero)
            return p
        }
        return mix
    }

    private func applyMix() {
        player.currentItem?.audioMix = audioMix()
    }

    // MARK: Filmstrip

    /// (Re)builds the trim bar's thumbnails for its current width.
    private func loadThumbnails() {
        let w = trimmer.bounds.width - TrimmerView.handleWidth * 2
        guard w > 50, abs(w - thumbnailWidth) > 40 else { return }
        thumbnailWidth = w
        let h = trimmer.bounds.height - 8
        let natural = asset.tracks(withMediaType: .video).first?.naturalSize ?? NSSize(width: 16, height: 10)
        let aspect = natural.width / max(natural.height, 1)
        let count = max(3, Int(ceil(w / (h * aspect))))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: h * aspect * 2, height: h * 2)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let times = (0..<count).map { i in
            NSValue(time: CMTime(seconds: totalSeconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600))
        }
        var images = [NSImage?](repeating: nil, count: count)
        var done = 0
        gen.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, cg, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let i = times.firstIndex(where: { $0.timeValue == requested }), let cg {
                    images[i] = NSImage(cgImage: cg, size: .zero)
                }
                done += 1
                if done == count { self.trimmer.thumbnails = images.compactMap { $0 } }
            }
        }
    }

    // MARK: Playback and trim

    private var trimRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: Double(trimmer.lo) * totalSeconds, preferredTimescale: 600),
                    end: CMTime(seconds: Double(trimmer.hi) * totalSeconds, preferredTimescale: 600))
    }

    @objc private func togglePlay() {
        if player.timeControlStatus != .paused { player.pause(); return }
        let r = trimRange
        let now = player.currentTime()
        // Play inside the trimmed range only.
        player.currentItem?.reversePlaybackEndTime = r.start
        player.currentItem?.forwardPlaybackEndTime = r.end
        if now < r.start || now >= r.end - CMTime(value: 1, timescale: 10) {
            player.seek(to: r.start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.player.play() }
        } else {
            player.play()
        }
    }

    private func trimChanged(_ lo: CGFloat, _ hi: CGFloat, edge: TrimmerView.Edge?) {
        // Show the frame under the handle that moves.
        if let edge {
            player.pause()
            let f = edge == .start ? lo : hi
            seeker.seek(to: CMTime(seconds: Double(f) * totalSeconds, preferredTimescale: 600), exact: false)
        } else {
            let r = trimRange
            player.currentItem?.reversePlaybackEndTime = r.start
            player.currentItem?.forwardPlaybackEndTime = r.end
        }
        updateInfo()
        syncPlayhead()
    }

    private func scrub(to f: CGFloat, done: Bool) {
        player.pause()
        seeker.seek(to: CMTime(seconds: Double(f) * totalSeconds, preferredTimescale: 600), exact: done)
    }

    private func syncPlayhead() {
        let head = CGFloat(player.currentTime().seconds / totalSeconds)
        trimmer.playhead = head
        for row in rows {
            row.waveform.trim = trimmer.lo...trimmer.hi
            row.waveform.playhead = head
        }
        timeLabel.stringValue = "\(TrimmerView.clock(player.currentTime().seconds)) / \(TrimmerView.clock(totalSeconds))"
        loadThumbnails()
    }

    private static func clock(_ t: CMTime) -> String {
        let s = max(0, Int(t.seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Duration, or the trimmed range when there is one; the Save button follows.
    private func updateInfo() {
        let r = trimRange
        let trimmed = trimmer.isTrimmed
        if trimmed {
            let text = NSMutableAttributedString(string: "✂︎  Trimmed  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.accent,
            ])
            text.append(NSAttributedString(
                string: "\(Self.clock(r.start)) – \(Self.clock(r.end))  ·  \(Self.clock(r.duration)) of \(Self.clock(asset.duration))",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.white(0.75)]))
            info.attributedStringValue = text
        } else {
            info.attributedStringValue = NSAttributedString(string: "Drag the ends of the timeline to trim", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.white(0.45),
            ])
        }
        if saveButton.isHidden != trimmed {
            saveButton.isHidden = trimmed
            trimSaveButton.isHidden = !trimmed
        }
    }

    // MARK: Save / discard

    @objc func save() {
        guard !saving, let win = window else { return }
        player.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Screen Recording \(AppDelegate.timestamp()).mp4"
        panel.directoryURL = AppDelegate.saveFolder()
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let dest = panel.url else { return }
            UserDefaults.standard.set(dest.deletingLastPathComponent().path, forKey: "lastSaveDir")
            self?.export(to: dest)
        }
    }

    private func export(to dest: URL) {
        saving = true
        player.pause()
        info.stringValue = "Saving…"
        let range = trimRange
        let audible = rows.filter { $0.effectiveVolume > 0 }
        let needsMix = audible.contains { $0.effectiveVolume != 1 }

        asset.loadTracks(withMediaType: .video) { [weak self] videoTracks, _ in
            guard let self, let video = videoTracks?.first else { return }
            let comp = AVMutableComposition()
            var params: [AVMutableAudioMixInputParameters] = []
            if let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? v.insertTimeRange(range, of: video, at: .zero)
                v.preferredTransform = video.preferredTransform
            }
            for row in audible {
                guard let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try? a.insertTimeRange(range, of: row.track, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: a)
                p.setVolume(row.effectiveVolume, at: .zero)
                params.append(p)
            }
            // Passthrough keeps the original quality and is fast; volume changes need re-encoding.
            let preset = needsMix ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
            guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { return }
            if needsMix {
                let mix = AVMutableAudioMix()
                mix.inputParameters = params
                session.audioMix = mix
            }
            try? FileManager.default.removeItem(at: dest)
            session.outputURL = dest
            session.outputFileType = .mp4
            session.exportAsynchronously {
                DispatchQueue.main.async { self.exportFinished(session, dest: dest) }
            }
        }
    }

    private func exportFinished(_ session: AVAssetExportSession, dest: URL) {
        saving = false
        guard session.status == .completed else {
            updateInfo()
            let alert = NSAlert()
            alert.messageText = "Couldn't save the recording"
            alert.informativeText = session.error?.localizedDescription ?? "Unknown error."
            if let win = window { alert.beginSheetModal(for: win) }
            return
        }
        finished = true
        try? FileManager.default.removeItem(at: url)
        window?.close()
        NSSound(named: "Pop")?.play()
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dest))
        gen.appliesPreferredTrackTransform = true
        let thumb = (try? gen.copyCGImage(at: .zero, actualTime: nil)).map { NSImage(cgImage: $0, size: .zero) }
            ?? NSWorkspace.shared.icon(forFile: dest.path)
        QuickAccess.shared.show(image: thumb, fileURL: dest, caption: "Recording saved") { u in
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func discard() {
        guard let win = window else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn't been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.finished = true
            try? FileManager.default.removeItem(at: self.url)
            win.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { return true }
        discard()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObservation = nil
        onClose?(self)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        prepareForDisplay()
    }

    /// Lays the window out and builds the filmstrip for the trim bar's width.
    func prepareForDisplay() {
        window?.contentView?.layoutSubtreeIfNeeded()
        loadThumbnails()
    }

    func windowDidResize(_ notification: Notification) { loadThumbnails() }
}
