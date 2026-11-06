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

    var body: some View {
        Form {
            Section("孩子档案") {
                ForEach(model.family.children) { child in
                    HStack {
                        Text("\(child.name) · \(child.grade) 年级")
                        Spacer()
                        Text(child.textbook).foregroundStyle(.secondary).lineLimit(1)
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
                TextField("HTTPS 服务地址", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
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
