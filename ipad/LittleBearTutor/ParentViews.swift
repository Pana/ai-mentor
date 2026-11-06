import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let onLock: () -> Void
    @State private var url = ""
    @State private var token = ""
    @State private var consent = false
    @State private var showingAddChild = false
    @State private var confirmingClear = false
    @State private var deletingChild: Child?
    @State private var editingChild: Child?
    @State private var editingTask: Homework?

    var body: some View {
        Form {
            Section("孩子档案") {
                ForEach(model.family.children) { child in
                    Button { editingChild = child } label: {
                        HStack {
                            Text("\(child.name) · \(child.grade) 年级").foregroundStyle(.primary)
                            Spacer()
                            Text("\(child.textbook) · 每 \(child.studyMinutes) 分钟休息").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { deletingChild = child } }
                }
                Button("添加孩子") { showingAddChild = true }
            }
            Section("待检查作业") {
                let review = model.family.tasks.filter { $0.status == .review }
                if review.isEmpty { Text("没有待检查作业").foregroundStyle(.secondary) }
                ForEach(review) { task in ReviewRow(task: task, childName: model.family.child(task.childID)?.name ?? "") }
            }
            Section {
                let editable = model.family.tasks.filter { !$0.practice && $0.status != .done }
                if editable.isEmpty { Text("没有可修改的作业").foregroundStyle(.secondary) }
                ForEach(editable) { task in
                    Button { editingTask = task } label: {
                        HStack {
                            Text("\(model.family.child(task.childID)?.name ?? "") · \(task.subject.label) · \(task.title)").foregroundStyle(.primary)
                            Spacer()
                            Text(task.status.rawValue).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("作业管理") } footer: { Text("修改题意后，作业会回到“待开始”，之前的小熊对话和检查意见会清除。") }
            Section {
                TextField(debugBuild ? "服务地址（HTTPS，或调试用 http://192.168.x.x:8787）" : "HTTPS 服务地址", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField(model.serviceConfigured ? "设备访问凭证（已保存，修改时重新填写）" : "设备访问凭证", text: $token)
                Toggle("允许发送当前题目与可选图片", isOn: $consent)
                Button("保存") { model.saveService(url: url, token: token, consent: consent); token = "" }
                    .disabled(consent && token.isEmpty)
                LabeledContent("状态", value: model.serviceConfigured ? "已开启" : "未开启")
            } header: { Text("辅导服务") } footer: {
                Text("模型供应商密钥只保存在服务端。设备凭证保存在本机钥匙串；学习记录不会上传，只有求助时发送当前题目和可选图片。")
            }
            Section("本地数据") {
                Button("清空家庭数据", role: .destructive) { confirmingClear = true }
                Button("退出家长设置") { onLock() }
            }
        }
        .navigationTitle("家长设置")
        .onAppear { url = model.serviceURL; consent = model.serviceConfigured }
        .sheet(isPresented: $showingAddChild) { AddChildView() }
        .sheet(item: $editingChild) { EditChildView(child: $0) }
        .sheet(item: $editingTask) { EditTaskView(task: $0) }
        .confirmationDialog("清空全部家庭数据？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearLocalFamily() }
            Button("取消", role: .cancel) {}
        } message: { Text("会删除孩子、作业、图片、对话、学习证据和辅导服务设置，且不可撤销。") }
        .alert("删除孩子档案？", isPresented: Binding(get: { deletingChild != nil }, set: { if !$0 { deletingChild = nil } })) {
            Button("删除", role: .destructive) { if let child = deletingChild { model.deleteChild(child.id) }; deletingChild = nil }
            Button("取消", role: .cancel) {}
        } message: { Text("会删除该孩子的作业、图片和学习证据，其他孩子不受影响。") }
    }
}

struct ReviewRow: View {
    @EnvironmentObject private var model: AppModel
    let task: Homework
    let childName: String
    @State private var note = ""
    @State private var concept = ""
    @State private var independent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(childName) · \(task.subject.label) · \(task.title)").font(.headline)
            if !task.instructions.isEmpty { Text(task.instructions).font(.subheadline).foregroundStyle(.secondary) }
            if !task.draft.isEmpty { Text("孩子的记录：\(task.draft)").foregroundStyle(.secondary) }
            if task.aiAssessment != "UNKNOWN" {
                Text("AI 检查建议：\(task.aiAssessment == "CORRECT" ? "看起来正确" : "可能有错误")（仅供参考）").font(.footnote).foregroundStyle(.orange)
            }
            if task.hints > 0 { Text("孩子向小熊求助过 \(task.hints) 次").font(.footnote).foregroundStyle(.secondary) }
            TextField("检查依据 / 订正建议", text: $note, axis: .vertical).textFieldStyle(.roundedBorder)
            TextField("知识点（可选，例如：两位数进位加法）", text: $concept).textFieldStyle(.roundedBorder)
            Toggle("独立完成并能解释思路", isOn: $independent)
            HStack {
                Button("确认完成") { review(passed: true) }.buttonStyle(.borderedProminent)
                Button("需要订正") { review(passed: false) }.buttonStyle(.bordered)
            }
            if !concept.trimmingCharacters(in: .whitespaces).isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("记录知识点时，请填写具体检查依据。").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    private func review(passed: Bool) {
        _ = model.parentReview(task.id, passed: passed, note: note, concept: concept, independent: passed && independent)
    }
}

struct EditChildView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let child: Child
    @State private var name = ""
    @State private var grade = 2
    @State private var textbook = ""
    @State private var minutes = 20

    var body: some View {
        NavigationStack {
            Form {
                TextField("昵称", text: $name)
                Picker("年级", selection: $grade) { Text("二年级").tag(2); Text("三年级").tag(3) }
                TextField("教材版本（例如：人教版）", text: $textbook)
                Stepper("每学习 \(minutes) 分钟提醒休息", value: $minutes, in: 5...60, step: 5)
            }
            .navigationTitle("编辑孩子档案")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if model.editChild(child.id, name: name, grade: grade, textbook: textbook, studyMinutes: minutes) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = child.name; grade = child.grade; minutes = child.studyMinutes
                textbook = child.textbook == "教材版本待确认" ? "" : child.textbook
            }
        }
    }
}

struct EditTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let task: Homework
    @State private var subject = Subject.math
    @State private var title = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("学科", selection: $subject) { ForEach(Subject.allCases) { Text($0.label).tag($0) } }
                TextField("作业名称", text: $title)
                TextField("页码、题号与完成要求", text: $instructions, axis: .vertical).lineLimit(2...6)
            }
            .navigationTitle("修改作业")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if model.editTask(task.id, subject: subject, title: title, instructions: instructions) { dismiss() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { subject = task.subject; title = task.title; instructions = task.instructions }
        }
    }
}

#if DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif
