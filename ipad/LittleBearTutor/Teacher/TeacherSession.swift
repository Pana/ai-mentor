import AVFoundation
import Foundation
import SwiftUI

/// The mic level for the bear's ring. Kept apart from `TeacherSession` so 20 updates a second redraw only the ring.
@MainActor final class VoiceLevel: ObservableObject {
    @Published var value: Float = 0
}

/// One voice-teacher conversation over `/v1/teacher` (protocol `littlebear.teacher.v1`, see `server/src/teacher.mjs`).
///
/// The server streams a reply as segments: words to say plus whiteboard ops. A segment's ops are applied when
/// that segment starts playing, and the next segment starts when the last of its audio has been heard, so the
/// drawing follows the voice. Without server TTS a segment stays on screen for a time based on its length.
///
/// Every sentence the child sends carries a `turn` number that the server echoes. A reply is shown only if it
/// answers the latest turn and the child has not interrupted since; anything else is cancelled by its id.
@MainActor final class TeacherSession: ObservableObject {
    enum Phase: Equatable {
        case connecting, listening, hearing, thinking, speaking, ended
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var elements: [BoardElement] = []
    @Published private(set) var focus: BoardFocus?
    /// What the teacher is saying now.
    @Published private(set) var caption = ""
    /// What the child said (interim while speaking).
    @Published private(set) var heard = ""
    /// The teacher asked a question and is waiting for the answer.
    @Published private(set) var awaitingAnswer = false
    /// The server recognizes speech; otherwise only typed input works.
    @Published private(set) var voiceInput = false
    @Published private(set) var notice: String?
    @Published var muted = false {
        didSet {
            audio.muted = muted
            if muted, phase == .hearing { cancelHearing() }
        }
    }
    let voiceLevel = VoiceLevel()

    private struct Segment {
        var speech: String
        var ops: [[String: Any]]
        var awaits: Bool
        var chunks: [Data] = []
        var audioDone = false
        var hasAudio = false
        /// Some of its audio was actually queued on the speaker.
        var played = false
        var waiting = false
        var waited = false
    }

    private let audio = TeacherAudio()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    /// The last sentence sent, and the first one whose reply is still wanted.
    private var turn = 0
    private var minTurn = 0
    private var response = -1
    private var segments: [Int: Segment] = [:]
    private var presenting: Int?
    private var nextIndex = 0
    private var outstanding = 0
    private var responseDone = false
    /// Segments of this reply that began playing: what the child heard and saw.
    private var started = 0
    private var playbackToken = 0

    init() {
        audio.onSpeechStart = { [weak self] in self?.speechStarted() }
        audio.onAudio = { [weak self] data in self?.sendAudio(data) }
        audio.onSpeechEnd = { [weak self] in self?.speechEnded() }
        audio.onLevel = { [weak self] level in
            guard let meter = self?.voiceLevel, abs(meter.value - level) > 0.03 else { return }
            meter.value = level
        }
        audio.onCaptureLost = { [weak self] in self?.captureLost() }
    }

    /// The conversation is connected and can take a sentence.
    var canTalk: Bool {
        switch phase {
        case .connecting, .ended, .failed: return false
        default: return socket != nil
        }
    }

    // MARK: Lifecycle

    func start(session: DeviceSession, child: RemoteChild) {
        stop()
        elements = []; focus = nil; caption = ""; heard = ""; notice = nil
        phase = .connecting
        guard let base = try? APIClient.validate(session.server),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { phase = .failed("服务器地址不对，请让家长检查设置。"); return }
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        components.path = (base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path) + "/v1/teacher"
        guard let url = components.url else { phase = .failed("服务器地址不对，请让家长检查设置。"); return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 4_000_000
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        send(["type": "session.start", "childId": child.id.uuidString.lowercased()])
    }

    func stop() {
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        resetPresentation()
        audio.stop()
        phase = .ended
    }

    /// Typed input, or a suggestion the child tapped.
    func say(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, canTalk else { return }
        // The server drops a sentence it was still hearing when typed text arrives.
        if phase == .hearing { audio.resetDetection() }
        interruptIfNeeded()
        turn += 1
        heard = value
        notice = nil
        phase = .thinking
        send(["type": "input.text", "text": String(value.prefix(1_000)), "turn": turn])
    }

    /// The child tapped the bear while it was talking or thinking: stop and listen.
    func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        interruptIfNeeded()
        minTurn = turn + 1 // also drops the reply to a sentence that is still being recognized
        phase = .listening
    }

    // MARK: Mic events

    private func speechStarted() {
        guard voiceInput, canTalk else { return }
        interruptIfNeeded()
        heard = ""
        notice = nil
        phase = .hearing
    }

    private func sendAudio(_ data: Data) {
        guard voiceInput, phase == .hearing else { return }
        // The completion-handler send queues in call order, so audio and `input.audio.end` stay in sequence.
        socket?.send(.data(data)) { _ in }
    }

    private func speechEnded() {
        guard voiceInput, phase == .hearing else { return }
        turn += 1
        phase = .thinking
        send(["type": "input.audio.end", "turn": turn])
    }

    /// Drops the sentence being heard (muted mid-sentence, or the mic went away).
    private func cancelHearing() {
        send(["type": "input.audio.cancel"])
        audio.resetDetection()
        heard = ""
        phase = .listening
    }

    private func captureLost() {
        if phase == .hearing { cancelHearing() }
        voiceInput = false
        notice = "麦克风断开了，可以先打字，或者退出再进来。"
    }

    private func interruptIfNeeded() {
        // The server has usually generated the whole reply already; tell it how far the child actually got.
        if response >= 0 { send(["type": "response.cancel", "response": response, "played": started]) }
        resetPresentation()
        caption = ""
    }

    // MARK: Server events

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(text)
                case .data(let data): handleAudio(data)
                @unknown default: break
                }
            }
        } catch {
            guard !Task.isCancelled, socket === task else { return }
            socket = nil
            resetPresentation()
            audio.stop()
            phase = .failed("和小熊老师的连接断开了。")
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let responseId = (event["response"] as? NSNumber)?.intValue
        let eventTurn = (event["turn"] as? NSNumber)?.intValue
        /// This event is about the latest sentence, and the child has not interrupted or started talking since.
        let wanted = eventTurn == turn && turn >= minTurn && phase != .hearing
        switch type {
        case "session.ready":
            let audioInfo = event["audio"] as? [String: Any]
            let output = audioInfo?["output"] as? [String: Any]
            voiceInput = audioInfo?["input"] is [String: Any]
            Task { await startAudio(outputRate: (output?["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000) }
        case "input.transcript.partial":
            if phase == .hearing { heard = event["text"] as? String ?? heard }
        case "input.transcript.final":
            guard wanted else { return }
            heard = event["text"] as? String ?? heard
            phase = .thinking
        case "input.transcript.empty":
            if eventTurn == turn, phase == .thinking { phase = .listening }
        case "response.start":
            guard let responseId else { return }
            guard wanted else { send(["type": "response.cancel", "response": responseId, "played": 0]); return }
            resetPresentation()
            response = responseId
            phase = .thinking
        case "segment":
            guard let responseId, responseId == response, let index = (event["index"] as? NSNumber)?.intValue else { return }
            segments[index] = Segment(speech: event["speech"] as? String ?? "", ops: event["board"] as? [[String: Any]] ?? [], awaits: event["await"] as? Bool ?? false)
            presentNextIfReady()
        case "segment.audio.done":
            guard let responseId, responseId == response, let index = (event["index"] as? NSNumber)?.intValue, segments[index] != nil else { return }
            segments[index]?.audioDone = true
            segments[index]?.hasAudio = event["audio"] as? Bool ?? false
            if presenting == index { finishIfPlayed() }
        case "response.done":
            guard let responseId, responseId == response else { return }
            responseDone = true
            if presenting == nil { presentNextIfReady() }
        case "error":
            if let eventTurn, eventTurn != turn { return } // about a sentence the child has moved on from
            handleError(event["code"] as? String ?? "")
        default:
            break
        }
    }

    private func handleAudio(_ data: Data) {
        guard data.count > 4 else { return }
        let responseId = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let index = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        guard response >= 0, responseId == response & 0xffff, segments[index] != nil else { return }
        let pcm = data.subdata(in: (data.startIndex + 4)..<data.endIndex)
        if presenting == index { schedule(pcm, segment: index) } else { segments[index]?.chunks.append(pcm) }
    }

    private func handleError(_ code: String) {
        switch code {
        case "child_not_found", "session_not_started":
            fail("找不到这个孩子的资料，请让家长检查设置。")
        case "teacher_model_not_configured":
            fail("服务器还没有配置小熊老师的 AI 模型。")
        case "asr_not_configured":
            voiceInput = false
            audio.resetDetection()
            notice = "服务器还没有配置语音识别，可以先打字和小熊说话。"
            phase = .listening
        case "rate_limited":
            recoverable("说得太快啦，休息一下再问。")
        case "asr_unavailable":
            recoverable("刚才没听清，再说一遍好吗？")
        default:
            recoverable("小熊刚才走神了，再说一遍吧。")
        }
    }

    private func fail(_ message: String) {
        resetPresentation()
        audio.stop()
        phase = .failed(message)
    }

    /// Shows a hint and goes back to listening, unless the child is already saying the next sentence.
    private func recoverable(_ message: String) {
        notice = message
        guard phase != .hearing else { return }
        resetPresentation()
        phase = .listening
    }

    private func startAudio(outputRate: Double) async {
        if voiceInput, !(await AVAudioApplication.requestRecordPermission()) {
            voiceInput = false
            notice = "没有麦克风权限，可以先打字。家长可以在系统设置里打开。"
        }
        guard socket != nil else { return } // the page was closed while the permission prompt was up
        do {
            try audio.start(capture: voiceInput, outputRate: outputRate)
        } catch {
            if voiceInput {
                voiceInput = false
                notice = "麦克风启动失败，可以先打字和小熊说话。"
            }
            try? audio.start(capture: false, outputRate: outputRate)
        }
        audio.muted = muted
        if phase == .connecting { phase = .listening }
    }

    // MARK: Presentation

    private func presentNextIfReady() {
        guard presenting == nil else { return }
        guard let segment = segments[nextIndex] else {
            if responseDone {
                response = -1
                audio.strict = false
                if phase == .speaking || phase == .thinking { phase = .listening }
            }
            return
        }
        let index = nextIndex
        presenting = index
        started = index + 1
        phase = .speaking
        audio.strict = true
        caption = segment.speech
        awaitingAnswer = segment.awaits
        if !segment.ops.isEmpty {
            withAnimation(.spring(duration: 0.45)) {
                for op in segment.ops {
                    if let id = BoardOps.apply(op, to: &elements) { focus = BoardFocus(id: id, tick: (focus?.tick ?? 0) + 1) }
                }
            }
        }
        segments[index]?.chunks.removeAll()
        for chunk in segment.chunks { schedule(chunk, segment: index) }
        finishIfPlayed()
    }

    private func schedule(_ pcm: Data, segment index: Int) {
        outstanding += 1
        let token = playbackToken
        let queued = audio.play(pcm) { [weak self] in
            guard let self, token == self.playbackToken else { return }
            self.outstanding -= 1
            self.finishIfPlayed()
        }
        if queued { segments[index]?.played = true }
    }

    private func finishIfPlayed() {
        guard let index = presenting, let segment = segments[index], segment.audioDone, outstanding == 0 else { return }
        if !(segment.hasAudio && segment.played), !segment.waited {
            // Nothing was heard for this segment (no TTS, or the speaker is unavailable): leave it up long enough to read.
            guard !segment.waiting else { return }
            segments[index]?.waiting = true
            let seconds = max(1.5, Double(segment.speech.count) * 0.22)
            let token = playbackToken
            waitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !Task.isCancelled, token == self.playbackToken else { return }
                self.segments[index]?.waited = true
                self.finishIfPlayed()
            }
            return
        }
        segments[index] = nil
        presenting = nil
        nextIndex = index + 1
        presentNextIfReady()
    }

    private func resetPresentation() {
        playbackToken += 1
        waitTask?.cancel(); waitTask = nil
        audio.stopPlayback()
        audio.strict = false
        response = -1
        segments.removeAll()
        presenting = nil
        nextIndex = 0
        outstanding = 0
        responseDone = false
        started = 0
        awaitingAnswer = false
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
