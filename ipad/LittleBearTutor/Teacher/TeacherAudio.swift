import AVFoundation
import Foundation

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
    var onSpeechStart: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var vad = VoiceActivityDetector()
    private var preroll: [Data] = []
    private var _muted = false
    private var _strict = false
    private var running = false

    /// Ignore the mic (the child pressed mute).
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue; if newValue { vad.reset() } } }
    }
    /// The teacher is talking: raise the barge-in threshold.
    var strict: Bool {
        get { lock.withLock { _strict } }
        set { lock.withLock { _strict = newValue } }
    }

    /// Starts playback, and the mic too when `capture` is true. `outputRate` is the server's TTS sample rate.
    func start(capture: Bool, outputRate: Double) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if capture { try engine.inputNode.setVoiceProcessingEnabled(true) }
        playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)!
        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        if capture {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            converter = AVAudioConverter(from: format, to: captureFormat)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in self?.capture(buffer) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running || engine.isRunning else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        lock.withLock { vad.reset(); preroll.removeAll() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Queues PCM16LE mono audio; `played` runs on the main queue once it has been heard (or dropped by `stopPlayback`).
    func play(_ pcm: Data, played: @escaping () -> Void) {
        let frames = pcm.count / 2
        guard running, frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { DispatchQueue.main.async(execute: played); return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32_768 }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in DispatchQueue.main.async(execute: played) }
        if !player.isPlaying { player.play() }
    }

    /// Drops everything queued (a barge-in) and stays ready for the next response.
    func stopPlayback() {
        guard running else { return }
        player.stop()
        player.play()
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
