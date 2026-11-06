import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if model.family.children.isEmpty { WelcomeView() } else { MainSplitView() }
        }
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") {}
        } message: { Text(model.errorMessage ?? "") }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        .sheet(isPresented: $showingAddChild) { AddChildView() }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, tasks, practice, progress, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "学习首页"; case .tasks: "我的作业"; case .practice: "练一练"; case .progress: "我的进步"; case .settings: "家长设置"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"; case .tasks: "checklist"; case .practice: "pencil.and.list.clipboard"; case .progress: "chart.bar"; case .settings: "lock"
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .home
    /// One path for the detail column; cleared on every page or child change so a study page never lingers.
    @State private var path: [UUID] = []
    var body: some View {
        NavigationSplitView {
            // Plain buttons instead of List(selection:): mixing selectable rows with buttons left the pages unreachable.
            List {
                Section("孩子") {
                    ForEach(model.family.children) { child in
                        sidebarRow("\(child.name) · \(child.grade) 年级",
                                   icon: child.id == model.selectedChildID ? "person.fill" : "person",
                                   selected: child.id == model.selectedChildID) {
                            model.selectChild(child.id); selection = .home
                        }
                    }
                }
                Section("学习") {
                    ForEach(SidebarItem.allCases) { item in
                        sidebarRow(item.title, icon: item.icon, selected: selection == item) { selection = item }
                    }
                }
            }
            .navigationTitle(model.selectedChild?.name ?? "小熊伴学")
        } detail: {
            // A fresh stack per page and per child so navigation never shows another child's task.
            NavigationStack(path: $path) {
                Group {
                    switch selection ?? .home {
                    case .home: HomeView(selection: $selection)
                    case .tasks: TasksView()
                    case .practice: PracticeView { path.append($0) }
                    case .progress: ProgressPage { path.append($0) }
                    case .settings: ParentSettingsGate()
                    }
                }
                .navigationDestination(for: UUID.self) { StudyView(taskID: $0) }
            }
            .id("\(selection?.rawValue ?? "home")-\(model.selectedChildID?.uuidString ?? "")")
            .onChange(of: selection) { path = [] }
            .onChange(of: model.selectedChildID) { path = [] }
        }
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).foregroundStyle(selected ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarItem?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.family.demo { Text("示例家庭 · 可体验本地练习与学习流程 · 仅在本机保存").font(.footnote).foregroundStyle(.orange) }
                Text("\(model.selectedChild?.name ?? "同学")，准备好一起探索了吗？").font(.largeTitle.bold())
                Text("今天也按自己的节奏，一件一件来。").foregroundStyle(.secondary)
                if let child = model.selectedChild {
                    let open = model.family.homework(for: child.id).filter { $0.status != .done }
                    if open.isEmpty { Text("作业都完成啦！").font(.title3) }
                    ForEach(open.prefix(3)) { task in
                        NavigationLink(value: task.id) { TaskRow(task: task) }.buttonStyle(.plain)
                    }
                    let due = model.family.reviews(for: child.id).filter { $0.dueAt <= Date() }
                    if !due.isEmpty {
                        Label("有 \(due.count) 个知识点可以复习了", systemImage: "arrow.clockwise").foregroundStyle(.orange)
                    }
                }
                Button("还有精力？来做一个小练习") { selection = .practice }.buttonStyle(.bordered)
            }
            .padding(32)
        }
        .navigationTitle("学习首页")
    }
}

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false
    var body: some View {
        List {
            if let child = model.selectedChild {
                let tasks = model.family.homework(for: child.id)
                if tasks.isEmpty { Text("还没有作业，点击“添加作业”补充。").foregroundStyle(.secondary) }
                ForEach(tasks) { task in
                    NavigationLink(value: task.id) { TaskRow(task: task) }
                        .swipeActions { Button("删除", role: .destructive) { model.deleteTask(task.id) } }
                }
            }
            Button("添加作业") { showingAdd = true }
        }
        .navigationTitle("我的作业")
        .sheet(isPresented: $showingAdd) { AddTaskView() }
    }
}

struct TaskRow: View {
    let task: Homework
    var body: some View {
        HStack {
            Text(task.subject.label).font(.headline).frame(width: 54)
            VStack(alignment: .leading) {
                Text(task.title).font(.headline)
                Text(task.exercise?.prompt ?? task.instructions).lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(task.status.rawValue).font(.caption).foregroundStyle(task.status == .correction ? .orange : .green)
        }
        .contentShape(Rectangle())
    }
}

struct AddChildView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var grade = 2
    @State private var textbook = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("昵称", text: $name)
                Picker("年级", selection: $grade) { Text("二年级").tag(2); Text("三年级").tag(3) }
                TextField("教材版本（可留空）", text: $textbook)
            }
            .navigationTitle("添加孩子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { model.addChild(name: name, grade: grade, textbook: textbook); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Manual entry plus optional photo recognition. Recognized text is a draft until the parent confirms it.
struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var instructions = ""
    @State private var subject = Subject.math
    @State private var photo: String?
    @State private var recognitionNote = ""
    @State private var recognized = false
    @State private var confirmed = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("作业内容") {
                    Picker("学科", selection: $subject) { ForEach(Subject.allCases) { Text($0.label).tag($0) } }
                    TextField("作业名称", text: $title)
                    TextField("页码、题号与完成要求", text: $instructions, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    PhotoSourceButtons(replacing: photo != nil) { data in replacePhoto(with: model.storePhoto(data)) }
                    if let photo {
                        if model.serviceConfigured {
                            HStack {
                                Button(model.tutorBusy ? "正在识别…" : "识别作业要求（发送这张图片）") { recognize(photo) }
                                    .buttonStyle(.borderedProminent).disabled(model.tutorBusy)
                                if model.tutorBusy { ProgressView(); Button("停止") { model.cancelTutor() }.buttonStyle(.borderless) }
                            }
                        } else {
                            Text("家长开启辅导服务后，可以自动识别图片中的作业要求。").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !recognitionNote.isEmpty { Text(recognitionNote).foregroundStyle(.green) }
                        if let url = model.photoURL(photo), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                            Text("核对原图与作业要求，再确认加入作业。").font(.footnote).foregroundStyle(.orange)
                        }
                        if recognized { Toggle("我已核对图片，并修正了不清楚的内容", isOn: $confirmed) }
                        Button("移除图片", role: .destructive) { replacePhoto(with: nil) }.buttonStyle(.borderless)
                    }
                } header: { Text("作业图片（可选）") } footer: {
                    Text("确认后才加入作业列表。识别需要发送本次图片，学习记录仍只保存在本机。")
                }
            }
            .navigationTitle("为\(model.selectedChild?.name ?? "孩子")添加作业")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认添加") {
                        model.addTask(subject: subject, title: title, instructions: instructions, photoPath: photo)
                        saved = true
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.tutorBusy || (recognized && !confirmed))
                }
            }
            .onDisappear {
                guard !saved else { return }
                model.cancelTutor()
                model.discardPhoto(photo)
            }
        }
    }

    private func replacePhoto(with name: String?) {
        model.cancelTutor()
        model.discardPhoto(photo)
        photo = name
        recognized = false
        confirmed = false
        recognitionNote = ""
    }

    private func recognize(_ photo: String) {
        model.recognize(photo: photo, subject: subject) { reply in
            guard self.photo == photo else { return }
            if let value = reply.title, !value.isEmpty { title = String(value.prefix(100)) }
            if let value = reply.instructions, !value.isEmpty { instructions = String(value.prefix(2000)) }
            if let value = reply.subject.flatMap(Subject.init(apiName:)) { subject = value }
            recognitionNote = reply.message
            recognized = true
            confirmed = false
        }
    }
}
