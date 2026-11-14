import AVFoundation
import Foundation
import UIKit

/// Decides when the child starts and stops talking from the level of each mic chunk.
/// The noise floor adapts to the room; while the teacher is speaking the start threshold is raised,
/// so echo the voice processor did not remove does not count as the child barging in.
struct VoiceActivityDetector: Equatable {
    enum Event: Equatable { case start, end }

    var noiseFloor: Float = -60
    private(set) var speaking = false
    private var aboveMs = 0, belowMs = 0, speechMs = 0

    var startMargin: Float = 14
    var strictExtra: Float = 8
    var endMargin: Float = 8
    var startAfterMs = 180
    var endAfterMs = 800
    var maxSpeechMs = 30_000

    /// `level` in dBFS for a chunk lasting `ms`; `strict` while the teacher is talking.
    mutating func process(level: Float, ms: Int, strict: Bool) -> Event? {
        if speaking {
            speechMs += ms
            belowMs = level < noiseFloor + endMargin ? belowMs + ms : 0
            if belowMs >= endAfterMs || speechMs >= maxSpeechMs { reset(); return .end }
            return nil
        }
        // Track the room: fall quickly to quieter levels, rise slowly so speech does not become the floor.
        noiseFloor = level < noiseFloor ? noiseFloor * 0.7 + level * 0.3 : noiseFloor + (level - noiseFloor) * 0.01
        noiseFloor = min(-30, max(-80, noiseFloor))
        let threshold = max(noiseFloor + startMargin, -48) + (strict ? strictExtra : 0)
        aboveMs = level > threshold ? aboveMs + ms : 0
        if aboveMs >= startAfterMs { speaking = true; aboveMs = 0; belowMs = 0; speechMs = 0; return .start }
        return nil
    }

    mutating func reset() { speaking = false; aboveMs = 0; belowMs = 0; speechMs = 0 }

    /// dBFS of 16-bit samples.
    static func level(_ samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for sample in samples { let value = Float(sample) / 32_768; sum += value * value }
        return 10 * log10(max(sum / Float(samples.count), 1e-10))
    }
}

/// Mic capture at 16 kHz PCM16 with the system voice processor (echo cancellation), voice activity detection,
/// and playback of the teacher's PCM16 audio on the same engine so the echo canceller hears what is played.
/// Callbacks arrive on the main queue.
final class TeacherAudio: @unchecked Sendable {
    enum AudioError: Error { case noInput }

    var onSpeechStart: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    /// The engine could not be brought back with the mic after the system stopped it; playback may still work.
    var onCaptureLost: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var converter: AVAudioConverter?
    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var vad = VoiceActivityDetector()
    private var preroll: [Data] = []
    private var _muted = false
    private var _strict = false
    // Main queue only.
    private var running = false
    private var captureEnabled = false
    private var outputRate: Double = 24_000
    private var tapInstalled = false
    private var voiceProcessing = false
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    /// Ignore the mic (the child pressed mute).
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue; if newValue { vad.reset(); preroll.removeAll() } } }
    }
    /// The teacher is talking: raise the barge-in threshold.
    var strict: Bool {
        get { lock.withLock { _strict } }
        set { lock.withLock { _strict = newValue } }
    }

    /// Forget a sentence in progress (it was cancelled); the next sound starts a new one.
    func resetDetection() { lock.withLock { vad.reset(); preroll.removeAll() } }

    /// Starts playback, and the mic too when `capture` is true. `outputRate` is the server's TTS sample rate.
    /// On failure everything is torn down again, so a retry without the mic starts clean.
    func start(capture: Bool, outputRate: Double) throws {
        stop()
        captureEnabled = capture
        self.outputRate = outputRate
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
            if capture {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessing = true
            }
            playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            if capture {
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                // No usable microphone (some simulators): installing a tap with this format would raise.
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
                converter = AVAudioConverter(from: format, to: captureFormat)
                input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in self?.capture(buffer) }
                tapInstalled = true
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
        player.play()
        running = true
        observe()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        running = false
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        let attached = engine.attachedNodes.contains(player)
        if attached { player.stop() }
        engine.stop()
        if attached { engine.detach(player) }
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false); voiceProcessing = false }
        lock.withLock { vad.reset(); preroll.removeAll() }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    /// Queues PCM16LE mono audio; `played` runs on the main queue once it has been heard (or dropped by `stopPlayback`).
    /// Returns false, and still calls `played`, when nothing can be played right now.
    @discardableResult
    func play(_ pcm: Data, played: @escaping () -> Void) -> Bool {
        let frames = pcm.count / 2
        guard running, engine.isRunning, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { DispatchQueue.main.async(execute: played); return false }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32_768 }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in DispatchQueue.main.async(execute: played) }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Drops everything queued (a barge-in) and stays ready for the next response.
    func stopPlayback() {
        guard running, engine.isRunning else { return } // starting a player on a stopped engine raises
        player.stop()
        player.play()
    }

    // MARK: Recovery

    /// iOS stops the engine on a route change (headphones), a call or Siri, and when the app leaves the foreground.
    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.recover() },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.recover() },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.recover()
            }
        ]
    }

    private func recover() {
        guard running, !engine.isRunning else { return }
        let capture = captureEnabled, rate = outputRate
        do { try start(capture: capture, outputRate: rate) } catch {
            try? start(capture: false, outputRate: rate)
            onCaptureLost?()
        }
    }

    // MARK: Capture (audio thread)

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * captureFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        let pointer = UnsafeBufferPointer(start: samples, count: count)
        let level = VoiceActivityDetector.level(pointer)
        let data = Data(buffer: pointer)
        let ms = count * 1_000 / 16_000

        var event: VoiceActivityDetector.Event?
        var send: [Data] = []
        lock.lock()
        if _muted {
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
            return
        }
        let wasSpeaking = vad.speaking
        event = vad.process(level: level, ms: ms, strict: _strict)
        if event == .start {
            send = preroll + [data] // the first syllable started before the detector was sure
            preroll.removeAll()
        } else if wasSpeaking, event != .end {
            send = [data]
        } else if event == nil {
            preroll.append(data)
            if preroll.count > 12 { preroll.removeFirst(preroll.count - 12) } // ~300–700 ms
        }
        lock.unlock()

        let normalized = max(0, min(1, (level + 60) / 45))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevel?(normalized)
            if event == .start { self.onSpeechStart?() }
            for chunk in send { self.onAudio?(chunk) }
            if event == .end { self.onSpeechEnd?() }
        }
    }
}
