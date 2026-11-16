// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa
import AVFoundation
import ScreenCaptureKit

// MARK: - Live audio levels for the recording controls

/// Level (0…1) of an audio sample buffer, from its RMS in dB (-50 dB … 0 dB).
func audioLevel(of sb: CMSampleBuffer) -> Float {
    guard let fmt = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }
    var size = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
                                                            bufferListSize: 0, blockBufferAllocator: nil,
                                                            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    guard size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl,
                                                                  bufferListSize: size, blockBufferAllocator: nil,
                                                                  blockBufferMemoryAllocator: nil, flags: 0,
                                                                  blockBufferOut: &block) == noErr else { return 0 }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    var sum: Double = 0
    var count = 0
    for buf in UnsafeMutableAudioBufferListPointer(abl) {
        guard let data = buf.mData else { continue }
        if isFloat && asbd.mBitsPerChannel == 32 {
            let n = Int(buf.mDataByteSize) / 4
            let p = data.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { sum += Double(p[i] * p[i]) }
            count += n
        } else if asbd.mBitsPerChannel == 16 {
            let n = Int(buf.mDataByteSize) / 2
            let p = data.bindMemory(to: Int16.self, capacity: n)
            for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
            count += n
        }
    }
    guard count > 0 else { return 0 }
    let rms = sqrt(sum / Double(count))
    let db = 20 * log10(max(rms, 1e-7))
    return Float(min(1, max(0, (db + 50) / 50)))
}

/// Listens to the microphone and to the system audio while the action bar is up, to drive the meters.
final class AudioLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput {
    private(set) var micLevel: Float = 0
    private(set) var soundLevel: Float = 0
    private var session: AVCaptureSession?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "snapmark.levels")

    /// Turns each source on or off. Safe to call repeatedly.
    func update(mic: Bool, sound: Bool) {
        if mic { startMic() } else { stopMic() }
        if sound { startSound() } else { stopSound() }
    }

    func stop() {
        stopMic()
        stopSound()
    }

    // Microphone

    private func startMic() {
        guard session == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                if ok { DispatchQueue.main.async { self.startMic() } }
            }
            return
        default: return
        }
        guard let device = CaptureOptions.selectedMicrophone,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return }
        s.addInput(input)
        s.addOutput(out)
        session = s
        queue.async { s.startRunning() }
    }

    private func stopMic() {
        guard let s = session else { return }
        session = nil
        micLevel = 0
        queue.async { s.stopRunning() }
    }

    /// Restarts the microphone with the newly chosen device.
    func restartMic() {
        guard session != nil else { return }
        stopMic()
        startMic()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let l = audioLevel(of: sb)
        DispatchQueue.main.async { self.micLevel = max(l, self.micLevel * 0.8) }
    }

    // System audio (a tiny ScreenCaptureKit stream that only listens)

    private func startSound() {
        guard stream == nil else { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content, let display = content.displays.first else { return }
            let me = content.applications.filter { $0.processID == getpid() }
            let cfg = SCStreamConfiguration()
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                             configuration: cfg, delegate: nil)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch { return }
            DispatchQueue.main.async {
                self.stream = s
                s.startCapture { _ in }
            }
        }
    }

    private func stopSound() {
        guard let s = stream else { return }
        stream = nil
        soundLevel = 0
        s.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let l = audioLevel(of: sb)
        DispatchQueue.main.async { self.soundLevel = max(l, self.soundLevel * 0.8) }
    }

    /// Lets the meters fall back when the sources go quiet.
    func decay() {
        micLevel *= 0.85
        soundLevel *= 0.85
    }
}
