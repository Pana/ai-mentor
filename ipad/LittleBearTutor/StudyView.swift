import PencilKit
import SwiftUI
import UIKit

struct StudyView: View {
    @EnvironmentObject private var model: AppModel
    let taskID: UUID
    @State private var answer = ""
    @StateObject private var speaker = SpeechOutput()
    @StateObject private var voice = VoiceConversation()

    var body: some View {
        Group {
            if let task = model.family.task(taskID) { content(task) }
            else { ContentUnavailableView("这项作业已删除", systemImage: "trash", description: Text("请返回作业列表。")) }
        }
        .navigationTitle("学习空间")
        // On iPhone the keyboard covers the tab bar; give children an obvious way to put it away.
        .keyboardDoneButton()
        .onAppear {
            model.openTask(taskID)
            answer = model.family.task(taskID)?.draft ?? ""
        }
        .onDisappear { model.cancelTutor(); speaker.stop(); voice.stop() }
    }

    @ViewBuilder private func content(_ task: Homework) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(task.title).font(.largeTitle.bold())
                    Spacer()
                    Text(tag(task)).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.green.opacity(0.15), in: Capsule())
                    Text(task.status.rawValue).font(.caption).foregroundStyle(task.status == .correction ? .orange : .green)
                }
                StudyTimerView(task: task).id(task.id)
                VoiceConversationBar(conversation: voice, enabled: model.serviceConfigured) {
                    guard let child = model.selectedChild else { return }
                    voice.onTurn = { question, reply, revision in
                        model.applyVoiceTurn(taskID: task.id, revision: revision, question: question, reply: reply)
                    }
                    voice.start(config: CredentialStore().load(), context: VoiceContext(child: child, task: task))
                }
                if let exercise = task.exercise {
                    ExercisePanel(task: task, exercise: exercise, answer: $answer, speaker: speaker)
                } else {
                    homeworkPanel(task)
                    TutorPanel(task: task, speaker: speaker)
                }
                Whiteboard(enabled: task.status != .done).id(task.id)
                Text("相机仅在拍照时使用 · 语音对话可随时停止 · 离开页面会暂停学习计时").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }

    private func tag(_ task: Homework) -> String {
        guard let exercise = task.exercise else { return "我的作业" }
        return exercise.verified ? "基础练习" : "AI 生成练习"
    }

    @ViewBuilder private func homeworkPanel(_ task: Homework) -> some View {
        Text(task.instructions.isEmpty ? "按照作业要求在纸上完成，也可以在下方记录你的想法。" : task.instructions).font(.title3)
        if let url = model.photoURL(task.photoPath), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        TextField("记录你的答案或想法（可选）", text: $answer, axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(2...8)
            .disabled(!task.status.editable)
            .onChange(of: answer) { _, value in if task.status.editable { model.saveDraft(task.id, value) } }
        HStack {
            Button("我写好了，请家长检查") { speaker.stop(); model.submitTask(task.id) }
                .buttonStyle(.borderedProminent).disabled(!task.status.editable)
            if task.status != .done {
                PhotoSourceButtons(replacing: task.photoPath != nil) { data in model.attachPhoto(data, to: task.id) }
            }
        }
        if task.status == .review { Text("已经记下啦，等待家长检查。").foregroundStyle(.secondary) }
        if !task.reviewNote.isEmpty { Text("家长的建议：\(task.reviewNote)").foregroundStyle(.green) }
    }
}

/// Short-answer exercise: progressive hints and a local answer check that records evidence.
struct ExercisePanel: View {
    @EnvironmentObject private var model: AppModel
    let task: Homework
    let exercise: Exercise
    @Binding var answer: String
    @ObservedObject var speaker: SpeechOutput

    private var message: String {
        switch task.status {
        case .done: exercise.explanation
        case .correction: "这次还需要再检查一下。可以看看提示，再试一次。"
        default: task.hints > 0 ? exercise.hints[min(task.hints, 3) - 1] : "先试着自己想一想。需要帮助时，我可以给你一点提示。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exercise.prompt).font(.title2)
            TextField("写下你的答案", text: $answer).textFieldStyle(.roundedBorder).font(.title3)
                .disabled(task.status == .done).onSubmit(check)
            HStack {
                Button("我写好了，检查一下", action: check).buttonStyle(.borderedProminent)
                    .disabled(task.status == .done || answer.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("给我一点提示") { speaker.stop(); model.hint(task.id) }.buttonStyle(.bordered)
                    .disabled(task.status == .done || task.hints >= 3)
            }
            if !exercise.verified { Text("这是 AI 生成题，参考答案可能有误；结果不计入独立掌握证据。").foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 10) {
                Text("小熊陪你想一想").font(.headline).foregroundStyle(.green)
                Text(message).font(.title3)
                HStack {
                    Button(speaker.speaking ? "停止朗读" : "朗读提示") { speaker.speaking ? speaker.stop() : speaker.speak(message) }
                    if task.hints > 0 { Text("已用提示 \(task.hints)/3").foregroundStyle(.secondary) }
                }.buttonStyle(.borderless)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func check() {
        speaker.stop()
        model.checkExercise(task.id, answer: answer)
    }
}

/// Asks the gateway for hints or a provisional check. Replies never complete homework or create mastery evidence.
struct TutorPanel: View {
    @EnvironmentObject private var model: AppModel
    let task: Homework
    @ObservedObject var speaker: SpeechOutput
    @State private var question = ""
    @State private var includePhoto = false
    @StateObject private var speech = SpeechInput()

    private var enabled: Bool { model.serviceConfigured && !model.tutorBusy && task.status != .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("问问小熊").font(.title2.bold())
            if !model.serviceConfigured {
                Text("请家长先在家长设置中开启辅导服务。你仍然可以记录想法并交给家长检查。").foregroundStyle(.secondary)
            }
            ForEach(task.conversation.suffix(8)) { turn in
                VStack(alignment: .leading, spacing: 6) {
                    Text("我：\(turn.question)").foregroundStyle(.secondary)
                    Text("小熊：\(turn.reply)")
                    Button(speaker.speaking ? "停止朗读" : "朗读这条提示") {
                        if speaker.speaking { speaker.stop() } else { speech.stop(); speaker.speak(turn.reply) }
                    }.buttonStyle(.borderless)
                }
            }
            if task.aiAssessment != "UNKNOWN" {
                Text("AI 检查建议：\(task.aiAssessment == "CORRECT" ? "目前看起来正确" : "需要再检查")。最终完成状态由家长确认。")
                    .foregroundStyle(.orange)
            }
            TextField("说说你卡在哪里，或写下你的思路", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6).disabled(model.tutorBusy)
            HStack {
                Button(speech.listening ? "停止听取" : "说出问题") {
                    if speech.listening { speech.stop() } else { speaker.stop(); speech.start() }
                }.buttonStyle(.bordered).disabled(!enabled)
                if speech.listening { ProgressView() }
                if !speech.transcript.isEmpty { Text("已识别：\(speech.transcript)").foregroundStyle(.secondary).lineLimit(1) }
            }
            .onChange(of: speech.transcript) { _, value in if !value.isEmpty { question = value } }
            if task.photoPath != nil {
                Toggle("这次发送作业图片（请确认图片中包含要问的题目）", isOn: $includePhoto).disabled(!enabled)
            }
            HStack {
                Button("发送问题") { send(mode: "help") }.buttonStyle(.borderedProminent)
                    .disabled(!enabled || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("帮我检查") { send(mode: "check") }.buttonStyle(.bordered)
                    .disabled(!enabled || (task.draft.isEmpty && !includePhoto))
                if model.tutorBusy {
                    ProgressView()
                    Button("停止") { model.cancelTutor() }.buttonStyle(.bordered).tint(.red)
                }
            }
            if model.tutorBusy { Text("小熊正在看这道题，可以点击停止。").foregroundStyle(.secondary) }
            Text("仅发送当前题目和最近对话。AI 回复可能出错，作业完成和知识掌握由家长核对。").font(.footnote).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { speech.stop() }
        .alert("语音输入", isPresented: Binding(get: { speech.errorMessage != nil }, set: { if !$0 { speech.errorMessage = nil } })) {
            Button("知道了") {}
        } message: { Text(speech.errorMessage ?? "") }
    }

    private func send(mode: String) {
        speech.stop(); speaker.stop()
        let text = mode == "check" ? "请检查我的答案和步骤" : question
        model.askTutor(taskID: task.id, mode: mode, message: text, includePhoto: includePhoto) {
            if mode == "help" { question = "" }
        }
    }
}

/// Scratch whiteboard for finger or Apple Pencil. Content stays on this page only.
struct Whiteboard: View {
    let enabled: Bool
    @State private var drawing = PKDrawing()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("草稿白板").font(.headline)
                Spacer()
                Button("清空") { drawing = PKDrawing() }.disabled(drawing.strokes.isEmpty)
            }
            DrawingCanvas(drawing: $drawing, enabled: enabled)
                .frame(height: 280)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("可以用手指或 Apple Pencil 画一画。草稿只在当前页面保留，离开后清空。").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemGreen, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.drawing = $drawing
        if canvas.drawing != drawing { canvas.drawing = drawing }
        canvas.isUserInteractionEnabled = enabled
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }
        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            if drawing.wrappedValue != canvas.drawing { drawing.wrappedValue = canvas.drawing }
        }
    }
}
