import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if model.family.children.isEmpty { WelcomeView() }
            else { MainSplitView() }
        }
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("知道了") {} } message: { Text(model.errorMessage ?? "") }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddChild = false
    var body: some View {
        VStack(spacing: 24) {
            Text("小 熊 伴 学").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(.green)
            Text("每一步，都有小熊陪你。\n写作业 · 学会思考 · 看见进步").multilineTextAlignment(.center).font(.title2)
            Button("先体验示例家庭") { model.useDemo() }.buttonStyle(.borderedProminent)
            Button("建立家庭档案") { showingAddChild = true }.buttonStyle(.bordered)
            Text("iPad 首版候选 · 学习记录只在本机保存").foregroundStyle(.secondary).font(.footnote)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            .sheet(isPresented: $showingAddChild) { AddChildView() }
    }
}

struct MainSplitView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .home
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("孩子") {
                    ForEach(model.family.children) { child in
                        Button { model.selectedChildID = child.id; selection = .home } label: {
                            Label("\(child.name) · \(child.grade) 年级", systemImage: child.id == model.selectedChildID ? "person.fill" : "person")
                        }
                    }
                }
                Section("学习") {
                    ForEach(SidebarItem.allCases) { item in Label(item.title, systemImage: item.icon).tag(item as SidebarItem?) }
                }
            }
                .navigationTitle(model.selectedChild?.name ?? "小熊伴学")
        } detail: {
            switch selection ?? .home {
            case .home: HomeView()
            case .tasks: TasksView()
            case .progress: ProgressViewPage()
            case .settings: ParentSettingsGate()
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable { case home, tasks, progress, settings; var id: String { rawValue }; var title: String { switch self { case .home: "学习首页"; case .tasks: "我的作业"; case .progress: "我的进步"; case .settings: "家长设置" } }; var icon: String { switch self { case .home: "house"; case .tasks: "checklist"; case .progress: "chart.bar"; case .settings: "lock" } } }

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("\(model.selectedChild?.name ?? "同学")，准备好一起探索了吗？").font(.largeTitle.bold())
            Text("今天也按自己的节奏，一件一件来。").foregroundStyle(.secondary)
            if let child = model.selectedChild { ForEach(model.family.tasks(for: child.id).prefix(3)) { task in TaskRow(task: task) } }
        }.padding(32) }.navigationTitle("学习首页")
    }
}

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false
    var body: some View {
        List {
            if let child = model.selectedChild { ForEach(model.family.tasks(for: child.id)) { task in NavigationLink { StudyView(task: task) } label: { TaskRow(task: task) }.swipeActions { Button("删除", role: .destructive) { model.deleteTask(task.id) } } } }
            Button("添加作业") { showingAdd = true }
        }.navigationTitle("我的作业").sheet(isPresented: $showingAdd) { AddTaskView() }
    }
}

struct TaskRow: View {
    let task: Homework
    var body: some View { HStack { Text(task.subject.rawValue).font(.headline).frame(width: 54); VStack(alignment: .leading) { Text(task.title).font(.headline); Text(task.instructions).lineLimit(2).foregroundStyle(.secondary) }; Spacer(); Text(task.status.rawValue).font(.caption).foregroundStyle(task.status == .correction ? .orange : .green) } }
}

struct StudyView: View {
    @EnvironmentObject private var model: AppModel
    let task: Homework
    @State private var answer = ""
    @State private var question = ""
    @State private var includePhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @StateObject private var speech = SpeechInput()
    @StateObject private var speaker = SpeechOutput()
    var current: Homework { model.family.task(task.id) ?? task }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text(current.title).font(.largeTitle.bold())
            StudyTimerView()
            Text(current.instructions).font(.title3)
            if let path = current.photoPath, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            TextField("记录你的答案或想法", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder).onChange(of: answer) { _, value in model.updateDraft(value) }
            HStack { Button("我写好了") { model.submitTask() }.buttonStyle(.borderedProminent); PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("选择题目图片", systemImage: "photo") }; if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { showingCamera = true } label: { Label("拍摄题目", systemImage: "camera") } } }
            Divider()
            Text("问问小熊").font(.title2.bold())
            ForEach(current.conversation) { turn in VStack(alignment: .leading, spacing: 6) { Text("我：\(turn.question)").foregroundStyle(.secondary); Text("小熊：\(turn.reply)"); Button(speaker.speaking ? "停止朗读" : "朗读这条提示") { if speaker.speaking { speaker.stop() } else { speaker.speak(turn.reply) } }.buttonStyle(.borderless) } }
            TextField("说说你卡在哪里", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
            HStack { Button(speech.listening ? "停止听取" : "说出问题") { if speech.listening { speech.stop() } else { speech.start() } }.buttonStyle(.bordered); if speech.listening { ProgressView() }; if !speech.transcript.isEmpty { Text("已识别：\(speech.transcript)").foregroundStyle(.secondary) } }
                .onChange(of: speech.transcript) { _, value in if !value.isEmpty { question = value } }
            Toggle("发送当前作业图片", isOn: $includePhoto)
            Button(model.tutorBusy ? "正在思考…" : "发送问题") { model.askTutor(message: question, includePhoto: includePhoto) }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.tutorBusy).buttonStyle(.borderedProminent)
            Text("AI 建议仅供参考；作业完成和知识掌握由家长核对。").font(.footnote).foregroundStyle(.secondary)
        }.padding(32) }
        .navigationTitle("学习空间")
        .onAppear { model.selectedTaskID = task.id; answer = current.draft }
        .onDisappear { speech.stop(); speaker.stop() }
        .task(id: selectedPhoto?.itemIdentifier) {
            guard let selectedPhoto, let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
            model.attachPhoto(data)
        }
        .sheet(isPresented: $showingCamera) { CameraPicker { data in model.attachPhoto(data); showingCamera = false } }
    }
}

struct ProgressViewPage: View { @EnvironmentObject private var model: AppModel; var body: some View { List { if let child = model.selectedChild { Section("学习证据") { let records = model.family.evidence.filter { $0.childID == child.id }.sorted { $0.time > $1.time }; if records.isEmpty { Text("完成作业并由家长记录知识点后，这里会显示具体依据。") } else { ForEach(records) { record in VStack(alignment: .leading) { Text("\(record.subject.rawValue) · \(record.concept)").font(.headline); Text("\(record.correct ? "通过" : "需要订正") · \(record.independent ? "独立完成" : "获得帮助或待核验")").foregroundStyle(.secondary); if !record.note.isEmpty { Text(record.note) }; Text(record.time, style: .date).font(.caption).foregroundStyle(.secondary) } } } } } }.navigationTitle("我的进步") } }
struct SettingsView: View { @EnvironmentObject private var model: AppModel; let onLock: () -> Void; @State private var url = ""; @State private var token = ""; @State private var consent = false; @State private var showingAddChild = false; @State private var confirmingClear = false; @State private var deletingChild: Child?; var body: some View { Form { Section("孩子档案") { ForEach(model.family.children) { child in HStack { Text("\(child.name) · \(child.grade) 年级"); Spacer(); Text(child.textbook).foregroundStyle(.secondary).lineLimit(1) }.swipeActions { Button("删除", role: .destructive) { deletingChild = child } } }; Button("添加孩子") { showingAddChild = true } }; Section("待检查作业") { let review = model.family.tasks.filter { $0.status == .review }; if review.isEmpty { Text("没有待检查作业") } else { ForEach(review) { task in ReviewRow(task: task) } } }; Section("辅导服务") { TextField("HTTPS 服务地址", text: $url); SecureField("设备访问凭证", text: $token); Toggle("允许发送当前题目与可选图片", isOn: $consent); Button("保存") { model.saveService(url: url, token: token, consent: consent) }; Text("模型供应商密钥只保存在服务端。学习记录与设备凭证不会上传到模型供应商之外的地方。").font(.footnote).foregroundStyle(.secondary) }; Section("本地数据") { Button("清空家庭数据", role: .destructive) { confirmingClear = true }; Button("退出家长设置", role: .cancel) { onLock() } } }.navigationTitle("家长设置").onAppear { url = model.serviceURL; consent = model.serviceConfigured }.sheet(isPresented: $showingAddChild) { AddChildView() }.confirmationDialog("清空全部家庭数据？", isPresented: $confirmingClear, titleVisibility: .visible) { Button("清空", role: .destructive) { model.clearLocalFamily() }; Button("取消", role: .cancel) {} } message: { Text("会删除孩子、作业、图片、对话和学习证据，且不可撤销。") }.alert("删除孩子档案？", isPresented: Binding(get: { deletingChild != nil }, set: { if !$0 { deletingChild = nil } })) { Button("删除", role: .destructive) { if let deletingChild { model.deleteChild(deletingChild); self.deletingChild = nil } }; Button("取消", role: .cancel) {} } message: { Text("会删除该孩子的作业、图片和学习证据，其他孩子不受影响。") } } }

struct ReviewRow: View { @EnvironmentObject private var model: AppModel; let task: Homework; @State private var note = ""; @State private var concept = ""; @State private var independent = false; var body: some View { VStack(alignment: .leading, spacing: 8) { Text(task.title).font(.headline); if !task.draft.isEmpty { Text("孩子的记录：\(task.draft)").foregroundStyle(.secondary) }; TextField("检查依据 / 订正建议", text: $note, axis: .vertical).textFieldStyle(.roundedBorder); TextField("知识点（可选）", text: $concept).textFieldStyle(.roundedBorder); Toggle("独立完成并能解释思路", isOn: $independent); HStack { Button("确认完成") { model.markTask(task.id, passed: true, note: note, concept: concept, independent: independent) }.buttonStyle(.borderedProminent); Button("需要订正") { model.markTask(task.id, passed: false, note: note, concept: concept, independent: false) }.buttonStyle(.bordered) } }.padding(.vertical, 6) } }
struct AddChildView: View { @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var model: AppModel; @State private var name = ""; @State private var grade = 2; @State private var textbook = ""; var body: some View { NavigationStack { Form { TextField("昵称", text: $name); Picker("年级", selection: $grade) { Text("二年级").tag(2); Text("三年级").tag(3) }; TextField("教材版本（可留空）", text: $textbook) }.navigationTitle("添加孩子").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { model.addChild(name: name, grade: grade, textbook: textbook); dismiss() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } } } }

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; picker.allowsEditing = false; return picker }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (Data) -> Void
        init(onImage: @escaping (Data) -> Void) { self.onImage = onImage }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.88) { onImage(data) }; picker.dismiss(animated: true) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
struct AddTaskView: View { @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var model: AppModel; @State private var title = ""; @State private var instructions = ""; @State private var subject = Subject.math; var body: some View { NavigationStack { Form { Picker("学科", selection: $subject) { ForEach(Subject.allCases) { Text($0.rawValue).tag($0) } }; TextField("作业名称", text: $title); TextField("题目与完成要求", text: $instructions, axis: .vertical) }.navigationTitle("添加作业").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { model.addTask(subject: subject, title: title, instructions: instructions); dismiss() }.disabled(title.isEmpty) } } } } }
