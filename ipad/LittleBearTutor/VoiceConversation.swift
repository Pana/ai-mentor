import AVFoundation
import Foundation
import Speech
import SwiftUI

struct VoiceContext: Encodable, Sendable {
    let revision: Int
    let grade: Int
    let subject: String
    let title: String
    let instructions: String
    let answer: String
    let history: [TutorHistoryItem]

    init(child: Child, task: Homework) {
        revision = task.revision
        grade = [2, 3].contains(child.grade) ? child.grade : 2
        subject = task.subject.apiName
        title = String(task.title.prefix(100))
        instructions = String(task.instructions.prefix(2_000))
        answer = String(task.draft.prefix(2_000))
        history = task.conversation.suffix(8).map {
            TutorHistoryItem(question: String($0.question.prefix(2_000)), reply: String($0.reply.prefix(2_000)))
        }
    }
}

/// A continuously restarting Chinese recognizer. It is used for wake-word
/// detection and short turns; no microphone bytes are sent to the gateway.
/// A dedicated wake-word SDK can replace this class later without changing
/// VoiceConversation's WebSocket protocol.
@MainActor final class ContinuousSpeechInput: NSObject, ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var partial = ""
    @Published var errorMessage: String?
    var onFinalText: ((String) -> Void)?
    var onPartialText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restarting = false

    func start() {
        guard !listening else { return }
        guard recognizer != nil else { reportError("此设备没有可用的中文语音识别服务。"); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else { self.reportError("语音识别未授权。保留文字输入即可继续学习。"); return }
                do { try self.begin() } catch { self.reportError("无法启动连续语音，请检查麦克风权限。") }
            }
        }
    }

    func stop() {
        restarting = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        partial = ""
    }

    private func begin() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in request?.append(buffer) }
        audioEngine.prepare()
        try audioEngine.start()
        listening = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = String(result.bestTranscription.formattedString.prefix(2_000))
                    self.partial = text
                    self.onPartialText?(text)
                    if result.isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onFinalText?(text) }
                }
                if error != nil || result?.isFinal == true { self.restartRecognition() }
            }
        }
    }

    private func restartRecognition() {
        guard listening, !restarting else { return }
        restarting = true
        task?.cancel()
        request?.endAudio()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard self.listening else { return }
            do { try self.begin() } catch { self.restarting = false; self.reportError("语音识别暂时中断，请重试。") }
            self.restarting = false
        }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        onError?(message)
    }
}

@MainActor final class VoiceConversation: ObservableObject {
    enum State: Equatable {
        case idle, connecting, sleeping, listening, thinking, speaking
        case failed(String)
        var label: String {
            switch self {
            case .idle: "未开启"
            case .connecting: "正在连接"
            case .sleeping: "等待唤醒词"
            case .listening: "正在听"
            case .thinking: "小熊正在思考"
            case .speaking: "小熊正在回答"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastTranscript = ""
    let wakeWord = "小熊"

    private let speech = ContinuousSpeechInput()
    private let speaker = SpeechOutput()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var awake = false
    private var responseText = ""
    private var pendingQuestion = ""
    private var sessionRevision = 0
    var onTurn: ((String, String, Int) -> Void)?

    var isActive: Bool { state != .idle && !isFailed }
    private var isFailed: Bool { if case .failed = state { return true }; return false }

    init() {
        speech.onFinalText = { [weak self] text in self?.handleFinalText(text) }
        speech.onPartialText = { [weak self] text in self?.handlePartialText(text) }
        speech.onError = { [weak self] message in self?.state = .failed(message) }
    }

    func start(config: ServiceConfig, context: VoiceContext) {
        stop()
        sessionRevision = context.revision
        do {
            let base = try TutorClient.validate(url: config.url, token: config.token)
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw TutorError.invalidConfiguration }
            components.scheme = base.scheme == "https" ? "wss" : "ws"
            components.path = base.path.hasSuffix("/") ? base.path + "v1/voice" : base.path + "/v1/voice"
            guard let url = components.url else { throw TutorError.invalidConfiguration }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            state = .connecting
            task.resume()
            receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
            send(["type": "session.start", "wake_word": wakeWord, "context": context.dictionary])
            speech.start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        sleepTask?.cancel(); sleepTask = nil
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        speech.stop(); speaker.stop()
        awake = false; responseText = ""; pendingQuestion = ""; lastTranscript = ""
        state = .idle
    }

    private func handlePartialText(_ text: String) {
        guard awake, state == .speaking, !text.isEmpty else { return }
        speaker.stop()
        send(["type": "response.cancel"])
        state = .listening
    }

    private func handleFinalText(_ text: String) {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        lastTranscript = text
        if !awake {
            guard let range = normalized.range(of: wakeWord) else { return }
            awake = true
            state = .listening
            let rest = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { sendText(rest) }
        } else {
            sendText(text)
        }
        scheduleSleep()
    }

    private func sendText(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        state = .thinking
        pendingQuestion = value
        send(["type": "input.text", "text": String(value.prefix(2_000))])
    }

    private func scheduleSleep() {
        sleepTask?.cancel()
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            self.awake = false
            self.state = .sleeping
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                await MainActor.run { [weak self] in self?.handle(message) }
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let self, self.state != .idle else { return }
                self.state = .failed("语音服务连接中断")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let raw) = message, let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return }
        switch type {
        case "hello": break
        case "session.ready": state = awake ? .listening : .sleeping
        case "assistant.response.start": responseText = ""; state = .speaking
        case "assistant.text.delta": responseText += value["text"] as? String ?? ""
        case "assistant.text.done":
            let text = value["text"] as? String ?? responseText
            if !text.isEmpty { speaker.speak(text) }
            if !text.isEmpty, !pendingQuestion.isEmpty {
                onTurn?(pendingQuestion, text, sessionRevision)
                pendingQuestion = ""
            }
            state = .speaking
        case "assistant.response.done": scheduleSleep()
        case "response.cancelled": speaker.stop(); state = .listening
        case "error": state = .failed(voiceError(value["code"] as? String))
        default: break
        }
    }

    private func voiceError(_ code: String?) -> String {
        switch code {
        case "voice_provider_not_configured": "语音服务尚未配置实时模型"
        case "voice_provider_unavailable": "语音服务暂时不可用"
        default: "语音对话发生错误"
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket, JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }
}

private extension VoiceContext {
    var dictionary: [String: Any] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

struct VoiceConversationBar: View {
    @ObservedObject var conversation: VoiceConversation
    let enabled: Bool
    let start: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(conversation.state.label, systemImage: conversation.isActive ? "waveform" : "waveform.slash")
                Spacer()
                Button(conversation.isActive ? "停止语音对话" : "开启语音对话") {
                    if conversation.isActive { conversation.stop() } else { start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
            }
            if conversation.isActive {
                Text("说“\(conversation.wakeWord)”唤醒；唤醒后直接说话，不需要按住按钮。语音不会发送到小熊服务，设备支持时优先本机识别。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !enabled {
                Text("请家长先在家长设置中开启辅导服务。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !conversation.lastTranscript.isEmpty { Text("听到：\(conversation.lastTranscript)").font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
