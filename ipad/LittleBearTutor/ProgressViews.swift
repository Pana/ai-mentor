import SwiftUI

struct PracticeView: View {
    @EnvironmentObject private var model: AppModel
    let open: (UUID) -> Void

    var body: some View {
        List {
            if let child = model.selectedChild {
                ReviewSection(childID: child.id) { subject, concept in
                    model.generatePractice(subject: subject, concept: concept, onCreated: open)
                }
                if model.tutorBusy {
                    HStack {
                        ProgressView()
                        Text("小熊正在出一道新题…")
                        Spacer()
                        Button("停止生成") { model.cancelTutor() }.buttonStyle(.bordered)
                    }
                }
                Section {
                    ForEach(Subject.allCases) { subject in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(subject.label).font(.caption.bold()).foregroundStyle(.green)
                            Text(slogan(subject)).font(.title3.bold())
                            HStack {
                                Button("本地基础练习") { if let id = model.startLocalPractice(subject) { open(id) } }.buttonStyle(.borderedProminent)
                                Button("生成新题") { model.generatePractice(subject: subject, concept: "", onCreated: open) }
                                    .buttonStyle(.bordered).disabled(!model.serviceConfigured || model.tutorBusy)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: { Text("三科小练习") } footer: {
                    Text(model.serviceConfigured ? "生成的新题由 AI 出题，答案供参考，不计入独立掌握。" : "本地基础练习随时可用；家长开启辅导服务后可以生成新题。")
                }
                let done = model.family.practiceTasks(for: child.id).sorted { $0.createdAt > $1.createdAt }
                if !done.isEmpty {
                    Section("做过的练习") {
                        ForEach(done) { task in
                            NavigationLink(value: task.id) { TaskRow(task: task) }
                                .swipeActions { Button("删除", role: .destructive) { model.deleteTask(task.id) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("练一练")
    }

    private func slogan(_ subject: Subject) -> String {
        switch subject {
        case .math: "换个问题，试试自己的方法"
        case .chinese: "读一小段，找到关键信息"
        case .english: "想一想，拼出水果单词"
        }
    }
}

struct ProgressPage: View {
    @EnvironmentObject private var model: AppModel
    let open: (UUID) -> Void

    var body: some View {
        List {
            if let child = model.selectedChild {
                let today = Calendar.current.startOfDay(for: Date())
                let todays = model.family.evidence.filter { $0.childID == child.id && $0.time >= today }
                Section("今天的学习回顾") {
                    Text("\(todays.count) 次作答 · \(todays.filter(\.independent).count) 次独立答对")
                    Text("需要帮助和订正也是学习的一部分。完成作业后，可以向家长说说今天学到了什么。").foregroundStyle(.secondary)
                }
                let knowledge = model.family.knowledge(for: child.id)
                Section {
                    if knowledge.isEmpty { Text("完成练习，或由家长检查作业并记录知识点后，这里会显示具体依据。").foregroundStyle(.secondary) }
                    ForEach(knowledge) { item in
                        DisclosureGroup {
                            ForEach(item.evidence.reversed()) { record in EvidenceRow(record: record) }
                        } label: {
                            HStack {
                                Text("\(item.subject.label) · \(item.concept)").font(.headline)
                                Spacer()
                                Text(item.state).foregroundStyle(color(item.state))
                            }
                        }
                    }
                } header: { Text("知识点") } footer: {
                    Text("做完作业不等于已经掌握：至少两道不同的题都独立答对，且没有使用提示，才记为“初步掌握”。AI 检查建议和 AI 生成题不计入。")
                }
                ReviewSection(childID: child.id) { subject, concept in
                    model.generatePractice(subject: subject, concept: concept, onCreated: open)
                }
            }
        }
        .navigationTitle("我的进步")
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "初步掌握": .green
        case "需要再练练": .orange
        default: .secondary
        }
    }
}

struct EvidenceRow: View {
    let record: Evidence
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(record.correct ? "答对" : "需要订正") · \(record.independent ? "独立完成" : detail)").font(.subheadline)
            if !record.note.isEmpty { Text("依据：\(record.note)").font(.footnote) }
            Text("回答：\(record.answer)").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Text(record.time, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var detail: String {
        if !record.verifiedExercise { return "AI 生成题，待核验" }
        if record.hints > 0 { return "用了 \(record.hints) 次提示" }
        if record.priorFailures > 0 { return "订正后完成" }
        return record.origin == "parent" ? "获得帮助或待核验" : "待核验"
    }
}

/// Spaced review: incorrect → now, learning → next day, initially mastered → three days.
struct ReviewSection: View {
    @EnvironmentObject private var model: AppModel
    let childID: UUID
    let onPractice: (Subject, String) -> Void

    var body: some View {
        let reviews = model.family.reviews(for: childID)
        if !reviews.isEmpty {
            Section("复习安排") {
                ForEach(reviews) { review in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(review.subject.label) · \(review.concept)").font(.headline)
                            Text(review.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if review.dueAt <= Date() {
                            Text("可以复习了").foregroundStyle(.orange)
                        } else {
                            Text(review.dueAt, format: .dateTime.month().day()).foregroundStyle(.secondary)
                        }
                        Button(model.serviceConfigured ? "试一道相似题" : "做一道基础练习") { onPractice(review.subject, review.concept) }
                            .buttonStyle(.bordered).disabled(model.tutorBusy)
                    }
                }
            }
        }
    }
}
