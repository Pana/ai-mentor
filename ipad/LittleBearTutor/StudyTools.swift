import AVFoundation
import Speech
import SwiftUI

@MainActor final class SpeechInput: NSObject, ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !listening else { stop(); return }
        guard recognizer != nil else { errorMessage = "此设备没有可用的中文语音识别服务，请使用键盘输入。"; return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else { self.errorMessage = "语音识别未授权，可以继续使用键盘输入。"; return }
                do { try self.beginAudio() } catch { self.errorMessage = "无法启动语音输入，请检查麦克风权限。" }
            }
        }
    }
    func stop() {
        audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0); request?.endAudio(); task?.cancel(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        listening = false
    }
    private func beginAudio() throws {
        stop(); transcript = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest(); self.request = request
        request.shouldReportPartialResults = true
        // Keep the child's voice on the iPad whenever the device supports offline Chinese recognition.
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in request?.append(buffer) }
        audioEngine.prepare(); try audioEngine.start(); listening = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = String(result.bestTranscription.formattedString.prefix(2000)) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }
}

@MainActor final class SpeechOutput: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var speaking = false
    func speak(_ text: String, language: String = "zh-CN") {
        stop(); let utterance = AVSpeechUtterance(string: text); utterance.voice = AVSpeechSynthesisVoice(language: language); utterance.rate = 0.48
        synthesizer.speak(utterance); speaking = true
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate); speaking = false }
}

/// Counts focused time on one study page, saves it every 30 s and on leave, and suggests a break
/// after the child's configured minutes. Backgrounding the app pauses it.
struct StudyTimerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let task: Homework
    @State private var sessionID = UUID()
    @State private var startedAt = Date()
    @State private var seconds = 0
    @State private var paused = false
    @State private var breakAt = 0
    @State private var showingBreak = false

    private var finished: Bool { task.status == .done }
    private var running: Bool { !paused && !finished && scenePhase == .active }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: running ? "timer" : "pause.circle")
            Text("本次学习 \(seconds / 60) 分 \(seconds % 60) 秒")
            if !finished {
                Button(paused ? "继续学习" : "休息一下") { paused.toggle(); save() }.buttonStyle(.borderless)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .task(id: running) {
            guard running else { return }
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                let now = Date()
                seconds += max(0, Int(now.timeIntervalSince(last).rounded()))
                last = now
                if seconds % 30 == 0 { save() }
                if seconds >= breakAt { paused = true; showingBreak = true; save() }
            }
        }
        .onAppear {
            if breakAt == 0 { breakAt = (model.family.child(task.childID)?.studyMinutes ?? 20) * 60 }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
        .onDisappear { save() }
        .alert("伸个懒腰，休息一下吧", isPresented: $showingBreak) {
            Button("好，休息一下") { breakAt = seconds + (model.family.child(task.childID)?.studyMinutes ?? 20) * 60 }
        } message: {
            Text("已经专心学习了一会儿，可以看看远处、喝口水。回来后点击“继续学习”。")
        }
    }

    private func save() {
        model.recordStudy(StudySession(id: sessionID, childID: task.childID, taskID: task.id, seconds: seconds, startedAt: startedAt))
    }
}
