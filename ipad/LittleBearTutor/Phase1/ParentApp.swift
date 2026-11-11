import PhotosUI
import SwiftUI
import UIKit

/// Parent app (iPhone): 作业 · 录入 · 每天坚持 · 奖励.
struct ParentApp: View {
    enum Tab: Hashable { case homework, entry, routines, rewards }
    @State private var tab = Tab.homework
    @AppStorage("parent.childId") private var childIdText = ""

    var body: some View {
        TabView(selection: $tab) {
            ParentOverview(childIdText: $childIdText)
                .tabItem { Label("作业", systemImage: "list.bullet") }.tag(Tab.homework)
            ParentEntry(onSaved: { tab = .homework })
                .tabItem { Label("录入", systemImage: "plus.circle") }.tag(Tab.entry)
            ParentRoutines(childIdText: $childIdText)
                .tabItem { Label("每天坚持", systemImage: "arrow.clockwise") }.tag(Tab.routines)
            ParentRewards(childIdText: $childIdText)
                .tabItem { Label("奖励", systemImage: "play.rectangle") }.tag(Tab.rewards)
        }
    }
}

/// Child switcher for parent pages; falls back to the first child.
struct ChildSwitcher: View {
    @EnvironmentObject private var store: HomeworkStore
    @Binding var childIdText: String
    var body: some View {
        if store.children.count > 1 {
            Picker("孩子", selection: Binding(get: { selected(store, childIdText)?.id ?? UUID() }, set: { childIdText = $0.uuidString })) {
                ForEach(store.children) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 200)
        }
    }
}

@MainActor func selected(_ store: HomeworkStore, _ text: String) -> RemoteChild? {
    store.child(UUID(uuidString: text)) ?? store.children.first
}

// MARK: - 作业: completion by date

struct ParentOverview: View {
    @EnvironmentObject private var store: HomeworkStore
    @Binding var childIdText: String
    @State private var showingSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            let child = selected(store, childIdText)
            List {
                if store.children.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("先添加孩子").font(.headline)
                            Text("在设置里添加孩子，再用配对码连接孩子的 iPad。").foregroundStyle(Color.ink2)
                            Button("打开设置") { showingSettings = true }.buttonStyle(.borderedProminent)
                        }.padding(.vertical, 6)
                    }
                }
                if let child {
                    let waiting = store.items(child: child.id).filter(\.awaitingReview)
                    if let first = waiting.last {
                        Section {
                            Button { path.append(first.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(waiting.count) 项作业等你批改").font(.headline)
                                        Text("\(SubjectStyle.label(first.subject)) · \(first.content)").font(.subheadline).lineLimit(1).opacity(0.85)
                                    }
                                    Spacer()
                                    Text("去批改").bold()
                                    Image(systemName: "chevron.right")
                                }.foregroundStyle(.white)
                            }
                            .listRowBackground(Color.pine)
                        }
                    }
                    let groups = store.grouped(child: child.id) { $0.date >= Day.add(store.today, -30) }
                    if groups.isEmpty { Section { Text("还没有作业。到“录入”里粘贴老师发的作业。").foregroundStyle(Color.ink2) } }
                    ForEach(groups, id: \.day) { group in
                        Section {
                            ForEach(group.items) { item in
                                NavigationLink(value: item.id) { ParentRow(item: item) }
                            }
                        } header: {
                            HStack {
                                Text(Day.label(group.day, today: store.today))
                                Spacer()
                                let regular = group.items.filter { !$0.isRoutine }
                                if !regular.isEmpty { Text("交了 \(regular.filter { !$0.needsWork }.count) / \(regular.count)") }
                            }
                        }
                    }
                }
                Section { SyncFootnote() }.listRowBackground(Color.clear)
            }
            .refreshable { await store.sync() }
            .navigationTitle("作业")
            .navigationDestination(for: UUID.self) { ParentHomeworkDetail(id: $0) }
            .toolbar {
                ToolbarItem(placement: .principal) { ChildSwitcher(childIdText: $childIdText) }
                ToolbarItem(placement: .topBarTrailing) { Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
            }
            .sheet(isPresented: $showingSettings) { ParentSettings() }
        }
    }
}

struct ParentRow: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    var body: some View {
        HStack(spacing: 10) {
            SubjectTag(subject: item.subject, size: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.content).font(.body).lineLimit(2)
                if item.isRoutine { Text("每天坚持").font(.caption).foregroundStyle(Color.honeyInk) }
                else if let due = item.dueDate, due != item.date { Text("\(Day.short(due)) 交").font(.caption).foregroundStyle(Color.ink3) }
            }
            Spacer()
            switch item.status {
            case "SUBMITTED": Chip(text: "待批改", fg: Color(hex: 0x34557A), bg: Color(hex: 0xE8EEF6), size: 13)
            case "NEEDS_CORRECTION": Chip(text: "订正中", fg: Color(hex: 0xA04A06), bg: Color(hex: 0xFDEBDC), size: 13)
            case "REVIEWED":
                if let grade = item.latestReview?.grade { GradeBadge(grade: grade, size: 28) } else { Chip(text: "已打卡", fg: .pine, bg: .pineSoft, size: 13) }
            default: Text("未开始").font(.footnote).foregroundStyle(Color.ink3)
            }
        }
    }
}

// MARK: - Homework detail (parent)

struct ParentHomeworkDetail: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var reviewing: Submission?
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        if let item = store.homework[id] {
            List {
                Section {
                    HStack { SubjectTag(subject: item.subject, size: 13); Chip(text: modeLabel(item), size: 13); Spacer() }
                    Text(item.content).font(.title3)
                    LabeledContent("布置日期", value: Day.label(item.date, today: store.today))
                    if let due = item.dueDate { LabeledContent("老师要求", value: "\(Day.label(due, today: store.today)) 交") }
                    if !item.parentTodo.isEmpty { Label(item.parentTodo, systemImage: "person.fill.checkmark").foregroundStyle(Color.honeyInk) }
                    if !item.rawText.isEmpty {
                        DisclosureGroup("老师原话") { Text(item.rawText).font(.footnote).foregroundStyle(Color.ink2).textSelection(.enabled) }
                    }
                }
                if !item.attachmentIds.isEmpty {
                    Section("附带图片") {
                        ScrollView(.horizontal) {
                            HStack { ForEach(item.attachmentIds, id: \.self) { RemoteImage(fileId: $0, contentMode: .fill).frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 10)) } }
                        }
                    }
                }
                ForEach(item.submissions.reversed()) { submission in
                    Section(submission.attempt == 1 ? "提交" : "第 \(submission.attempt) 次提交（订正）") {
                        SubmissionSummary(item: item, submission: submission)
                        if submission.id == item.latest?.id, item.awaitingReview {
                            Button("开始批改") { reviewing = submission }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        }
                    }
                }
                if item.submissions.isEmpty { Section { Text("孩子还没有提交。").foregroundStyle(Color.ink2) } }
                Section {
                    Button("修改作业") { editing = true }
                    Button("删除作业", role: .destructive) { confirmingDelete = true }
                }
            }
            .navigationTitle(SubjectStyle.label(item.subject))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $reviewing) { submission in ReviewFlow(item: item, submission: submission) }
            .sheet(isPresented: $editing) { EditHomeworkView(item: item) }
            .confirmationDialog("删除这项作业？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await perform(store) { try await store.delete(id); dismiss() } } }
            } message: { Text("会同时删除孩子提交的照片、录音和批改，奖励记录保留。") }
        } else {
            ContentUnavailableView("作业已删除", systemImage: "trash")
        }
    }
}

struct SubmissionSummary: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    let submission: Submission
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(submitTime(submission)).font(.subheadline)
                if !item.isRoutine { Chip(text: submission.onTime ? "按时" : "晚交", fg: submission.onTime ? .pine : Color(hex: 0xA04A06), bg: submission.onTime ? .pineSoft : Color(hex: 0xFDEBDC), size: 12) }
            }
            if let seconds = submission.durationSeconds { Text("计时 \(seconds / 60) 分 \(seconds % 60) 秒").foregroundStyle(Color.ink2) }
            if item.isRecording, let audio = submission.fileIds.first { AudioPlayerButton(fileId: audio) }
            if item.isOffline {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(submission.fileIds.enumerated()), id: \.offset) { index, file in
                            AnnotatedPage(photo: file, overlay: overlayFile(submission, index)).frame(width: 120, height: 160)
                                .background(Color.chip).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if let review = submission.review {
                HStack(alignment: .top, spacing: 10) {
                    GradeBadge(grade: review.grade, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        if !review.comment.isEmpty { Text(review.comment) }
                        if review.requireCorrection { Text("要求订正后再交").font(.footnote).foregroundStyle(Color(hex: 0xA04A06)) }
                    }
                }
            }
        }
    }
}

func overlayFile(_ submission: Submission, _ index: Int) -> UUID? {
    guard let ids = submission.review?.annotationFileIds, ids.count == submission.fileIds.count else { return nil }
    return ids[index]
}

func submitTime(_ submission: Submission) -> String {
    guard let date = ISO8601DateFormatter.fractional.date(from: submission.submittedAt) ?? ISO8601DateFormatter().date(from: submission.submittedAt) else { return "已提交" }
    return "\(date.formatted(.dateTime.month().day().hour().minute())) 交"
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}

struct EditHomeworkView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    let item: RemoteHomework
    @State private var draft = DraftItem()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form { DraftFields(draft: $draft, images: []) }
                .navigationTitle("修改作业")
                .keyboardDoneButton()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saving = true
                            Task {
                                await perform(store) {
                                    try await store.update(item.id, content: draft.content, subject: draft.subject, date: draft.date, dueDate: draft.hasDue ? draft.dueDate : nil,
                                                           mode: draft.kind.mode, onlineKind: draft.kind.onlineKind, durationMinutes: draft.kind.usesDuration ? draft.minutes : nil, parentTodo: draft.parentTodo)
                                    dismiss()
                                }
                                saving = false
                            }
                        }.disabled(saving || draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { draft = DraftItem(item) }
        }
    }
}

// MARK: - 录入: paste the teacher's message → AI clean-up → check → save

/// How a homework item gets done.
enum DoneBy: String, CaseIterable, Identifiable {
    case photo, timer, recording
    var id: String { rawValue }
    var label: String { switch self { case .photo: "本子上写，拍照交"; case .timer: "在 iPad 上计时"; case .recording: "在 iPad 上录音" } }
    var mode: String { self == .photo ? "OFFLINE" : "ONLINE" }
    var onlineKind: String? { switch self { case .photo: nil; case .timer: "TIMER"; case .recording: "RECORDING" } }
    var usesDuration: Bool { self == .timer }
    init(mode: String, onlineKind: String?) {
        self = mode == "OFFLINE" ? .photo : (onlineKind == "TIMER" ? .timer : .recording)
    }
}

struct DraftItem: Identifiable {
    var id = UUID()
    var subject = "MATH"
    var content = ""
    var date = ""
    var hasDue = false
    var dueDate = ""
    var kind = DoneBy.photo
    var minutes = 10
    var parentTodo = ""
    var attachImages = false

    init() {}
    init(_ parsed: ParsedItem, date: String, attachImages: Bool) {
        subject = parsed.subject; content = parsed.content; self.date = date
        hasDue = parsed.dueDate != nil; dueDate = parsed.dueDate ?? Day.add(date, 1)
        kind = parsed.mode == "OFFLINE" ? .photo : .recording
        parentTodo = parsed.parentTodo; self.attachImages = attachImages
    }
    init(_ item: RemoteHomework) {
        subject = item.subject; content = item.content; date = item.date
        hasDue = item.dueDate != nil; dueDate = item.dueDate ?? Day.add(item.date, 1)
        kind = DoneBy(mode: item.mode, onlineKind: item.onlineKind); minutes = item.durationMinutes ?? 10; parentTodo = item.parentTodo
    }
}

/// Day strings ↔ DatePicker.
func dayBinding(_ text: Binding<String>) -> Binding<Date> {
    Binding(get: { Day.date(text.wrappedValue) ?? Date() },
            set: { text.wrappedValue = Day.string($0, TimeZone(identifier: "UTC")!) })
}

struct DraftFields: View {
    @Binding var draft: DraftItem
    let images: [Data]
    var body: some View {
        Picker("科目", selection: $draft.subject) { ForEach(SubjectStyle.all, id: \.self) { Text(SubjectStyle.label($0)).tag($0) } }
        TextField("作业内容", text: $draft.content, axis: .vertical).lineLimit(2...8)
        Picker("怎么完成", selection: $draft.kind) { ForEach(DoneBy.allCases) { Text($0.label).tag($0) } }
        if draft.kind.usesDuration { Stepper("时长 \(draft.minutes) 分钟", value: $draft.minutes, in: 1...120) }
        DatePicker("布置日期", selection: dayBinding($draft.date), displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: "UTC")!)
        Toggle("老师要求的交作业日期", isOn: $draft.hasDue)
        if draft.hasDue { DatePicker("交作业日期", selection: dayBinding($draft.dueDate), in: (Day.date(draft.date) ?? Date())..., displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: "UTC")!) }
        TextField("家长要做的事（例如签字）", text: $draft.parentTodo)
        if !images.isEmpty { Toggle("附上 \(images.count) 张图片", isOn: $draft.attachImages) }
    }
}

struct ParentEntry: View {
    @EnvironmentObject private var store: HomeworkStore
    let onSaved: () -> Void
    @State private var text = ""
    @State private var images: [Data] = []
    @State private var childIds: Set<UUID> = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var drafts: [DraftItem] = []
    @State private var showingResult = false
    @State private var aiMessage = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.children.isEmpty { Text("先在“作业 → 设置”里添加孩子。").foregroundStyle(Color.ink2) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Text("给").foregroundStyle(Color.ink2)
                            ForEach(store.children) { child in
                                let on = childIds.contains(child.id)
                                Button(child.name) { if on { childIds.remove(child.id) } else { childIds.insert(child.id) } }
                                    .buttonStyle(.bordered).tint(on ? .pine : .gray).fontWeight(on ? .bold : .regular)
                                    .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 180).font(.body)
                    Button { if let s = UIPasteboard.general.string { text = s } } label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
                } header: { Text("老师发的作业") } footer: { Text("直接从班级群复制过来就行，口语和表情 AI 会整理掉。") }
                Section {
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                                    ZStack(alignment: .topTrailing) {
                                        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 10)) }
                                        Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }.accessibilityLabel("删除图片")
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) { Label("从相册选图片", systemImage: "photo.on.rectangle") }
                    if CameraController.hasCamera { PhotoSourceButtons(cameraTitle: "拍作业单", showsLibrary: false) { append($0) } }
                } header: { Text("图片（选填）") } footer: { Text("作业单、课本页。最多 6 张。") }
                Section {
                    Button { parse() } label: { HStack { Text(busy ? "AI 正在整理…" : "让 AI 整理").bold(); if busy { ProgressView() } } }
                        .disabled(busy || childIds.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("不用 AI，手动填写") { manual() }.disabled(busy || childIds.isEmpty)
                }
            }
            .navigationTitle("录入作业")
            .keyboardDoneButton()
            .navigationDestination(isPresented: $showingResult) {
                // The form keeps its rows until the next entry replaces them, so nothing it binds to disappears mid-dismissal.
                EntryResult(drafts: $drafts, images: images, message: aiMessage, childIds: childIds, rawText: text) {
                    showingResult = false; text = ""; images = []; onSaved()
                }
            }
            .task(id: pickerItems) {
                for item in pickerItems { if let data = try? await item.loadTransferable(type: Data.self) { append(data) } }
                pickerItems = []
            }
            .onAppear { if childIds.isEmpty, let first = store.children.first { childIds = [first.id] } }
        }
    }

    private func append(_ data: Data) {
        guard images.count < 6, let image = UIImage(data: data), let jpeg = PhotoStore.gatewayJPEG(image) else { return }
        images.append(jpeg)
    }

    private func parse() {
        busy = true
        Task {
            await perform(store) {
                let result = try await store.parse(text: text)
                aiMessage = result.message
                let parsed = result.items.enumerated().map { DraftItem($1, date: store.today, attachImages: $0 == 0 && !images.isEmpty) }
                drafts = parsed.isEmpty ? [blank()] : parsed
                showingResult = true
            }
            busy = false
        }
    }

    private func manual() { aiMessage = ""; drafts = [blank()]; showingResult = true }
    private func blank() -> DraftItem { var d = DraftItem(); d.date = store.today; d.dueDate = Day.add(store.today, 1); d.attachImages = !images.isEmpty; return d }
}

struct EntryResult: View {
    @EnvironmentObject private var store: HomeworkStore
    @Binding var drafts: [DraftItem]
    let images: [Data]
    let message: String
    let childIds: Set<UUID>
    let rawText: String
    let onSaved: () -> Void
    @State private var saving = false

    var body: some View {
        Form {
            if !message.isEmpty { Section { Label(message, systemImage: "sparkles").foregroundStyle(Color.ink2) } }
            ForEach($drafts) { $draft in
                Section {
                    DraftFields(draft: $draft, images: images)
                    if drafts.count > 1 { Button("删除这一项", role: .destructive) { drafts.removeAll { $0.id == draft.id } } }
                } header: { Text(SubjectStyle.label(draft.subject)) }
            }
            Section { Button { var d = DraftItem(); d.date = store.today; d.dueDate = Day.add(store.today, 1); drafts.append(d) } label: { Label("再加一项", systemImage: "plus") } }
            Section {
                Button { save() } label: { HStack { Text(saving ? "正在保存…" : "加入\(names)的作业（\(drafts.count) 项）").bold(); if saving { ProgressView() } } }
                    .disabled(saving || drafts.contains { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } footer: { Text("加入后，孩子的 iPad 下次同步就能看到。") }
        }
        .navigationTitle("核对作业")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(saving || drafts.contains { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
    }

    private var names: String { store.children.filter { childIds.contains($0.id) }.map(\.name).joined(separator: "、") }

    private func save() {
        saving = true
        Task {
            await perform(store) {
                let attachments = drafts.contains(where: \.attachImages) ? try await store.uploadImages(images) : []
                var items: [NewHomework] = []
                for child in store.children where childIds.contains(child.id) {
                    for d in drafts {
                        items.append(NewHomework(childId: child.id, subject: d.subject, date: d.date, dueDate: d.hasDue ? max(d.dueDate, d.date) : nil,
                                                 content: d.content.trimmingCharacters(in: .whitespacesAndNewlines), rawText: String(rawText.prefix(5000)),
                                                 mode: d.kind.mode, onlineKind: d.kind.onlineKind, durationMinutes: d.kind.usesDuration ? d.minutes : nil,
                                                 parentTodo: d.parentTodo, attachmentIds: d.attachImages ? attachments : []))
                    }
                }
                try await store.create(items)
                onSaved()
            }
            saving = false
        }
    }
}

// MARK: - 每天坚持

struct ParentRoutines: View {
    @EnvironmentObject private var store: HomeworkStore
    @Binding var childIdText: String
    @State private var editing: RoutineDraft?
    @State private var warnFourth = false

    var body: some View {
        NavigationStack {
            let child = selected(store, childIdText)
            let mine = store.routines.filter { $0.childId == child?.id }
            let active = mine.filter(\.active).count
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("启用 \(active) 项").font(.headline); Spacer(); Text("建议 3 项，最多 5 项").font(.footnote).foregroundStyle(Color.ink3) }
                        HStack(spacing: 4) { ForEach(0..<5) { i in Capsule().fill(i < active ? Color.pine : Color(hex: 0xF0E2C4)).frame(height: 8) } }
                    }.padding(.vertical, 4)
                }
                Section {
                    ForEach(mine) { routine in
                        Button { editing = RoutineDraft(routine) } label: {
                            HStack {
                                SubjectTag(subject: routine.subject, size: 13)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.title).font(.headline).foregroundStyle(routine.active ? Color.ink : Color.ink3)
                                    Text(RoutineDraft(routine).summary).font(.footnote).foregroundStyle(Color.ink2)
                                }
                                Spacer()
                                if !routine.active { Text("已暂停").font(.footnote).foregroundStyle(Color.ink3) }
                            }
                        }
                    }
                    if let child {
                        Button {
                            var draft = RoutineDraft(); draft.childId = child.id
                            if active >= 3 { warnFourth = true; pendingDraft = draft } else { editing = draft }
                        } label: { Label("添加一项", systemImage: "plus") }
                        .disabled(active >= 5)
                    }
                } footer: { Text(active >= 5 ? "已满 5 项。先暂停或删除一项再加。" : "每天坚持会按设定的日子自动出现在孩子的“今天”里。") }
            }
            .navigationTitle("每天坚持")
            .toolbar { ToolbarItem(placement: .principal) { ChildSwitcher(childIdText: $childIdText) } }
            .sheet(item: $editing) { RoutineEditor(draft: $0) }
            .alert("项目有点多了", isPresented: $warnFourth) {
                Button("仍然添加") { editing = pendingDraft }
                Button("取消", role: .cancel) {}
            } message: { Text("每天坚持太多，孩子容易坚持不下来。建议保持 3 项以内。") }
        }
    }
    @State private var pendingDraft: RoutineDraft?
}

struct RoutineDraft: Identifiable {
    var id = UUID()
    var isNew = true
    var childId = UUID()
    var title = ""
    var subject = "ENGLISH"
    var kind = DoneBy.timer
    var minutes = 5
    var weekdays: Set<Int> = Set(0...6)
    var active = true
    var sortOrder = 0

    init() {}
    init(_ r: Routine) {
        id = r.id; isNew = false; childId = r.childId; title = r.title; subject = r.subject
        kind = DoneBy(mode: r.mode, onlineKind: r.onlineKind); minutes = r.durationMinutes ?? 5
        weekdays = Set(r.weekdays); active = r.active; sortOrder = r.sortOrder
    }
    var summary: String {
        let days = weekdays == Set(0...6) ? "每天" : weekdays == Set(1...5) ? "周一到周五" : "每周" + weekdays.sorted().map { Day.weekdayNames[$0] }.joined(separator: "、")
        return "\(days) · \(kind == .timer ? "iPad 计时 \(minutes) 分钟" : kind.label)"
    }
    var input: RoutineInput {
        RoutineInput(childId: childId, title: title.trimmingCharacters(in: .whitespacesAndNewlines), subject: subject, mode: kind.mode, onlineKind: kind.onlineKind,
                     durationMinutes: kind.usesDuration ? minutes : nil, quantity: nil, weekdays: weekdays.sorted(), active: active, sortOrder: sortOrder)
    }
}

struct RoutineEditor: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: RoutineDraft
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如：英语朗读 5 分钟", text: $draft.title)
                    Picker("科目", selection: $draft.subject) { ForEach(SubjectStyle.all, id: \.self) { Text(SubjectStyle.label($0)).tag($0) } }
                    Picker("怎么完成", selection: $draft.kind) { ForEach(DoneBy.allCases) { Text($0.label).tag($0) } }
                    if draft.kind.usesDuration { Stepper("时长 \(draft.minutes) 分钟", value: $draft.minutes, in: 1...120) }
                }
                Section("哪些天") {
                    HStack {
                        Button("每天") { draft.weekdays = Set(0...6) }.buttonStyle(.bordered)
                        Button("周一到周五") { draft.weekdays = Set(1...5) }.buttonStyle(.bordered)
                    }
                    HStack {
                        ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                            let on = draft.weekdays.contains(day)
                            Button(Day.weekdayNames[day]) { if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) } }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(on ? Color.pine : Color.chip, in: Circle()).foregroundStyle(on ? .white : Color.ink)
                                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                Section { Toggle("启用", isOn: $draft.active) }
                if !draft.isNew {
                    Section { Button("删除", role: .destructive) { Task { await perform(store) { try await store.deleteRoutine(draft.id); dismiss() } } } }
                }
            }
            .navigationTitle(draft.isNew ? "添加每天坚持" : "修改每天坚持")
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task { await perform(store) { try await store.saveRoutine(id: draft.id, draft.input); dismiss() }; saving = false }
                    }.disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.weekdays.isEmpty)
                }
            }
        }
    }
}

// MARK: - 奖励

struct ParentRewards: View {
    @EnvironmentObject private var store: HomeworkStore
    @Binding var childIdText: String
    @State private var rules = RewardRules()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            let child = selected(store, childIdText)
            Form {
                if let child, let summary = store.rewards[child.id] {
                    Section {
                        HStack {
                            stat("今天攒了", "\(summary.earnedToday) 分钟", .honey)
                            stat("今天用了", "\(summary.usedToday) 分钟", .white)
                            stat("余额", "\(summary.balance) 分钟", .white)
                        }
                        .listRowBackground(Color.ink)
                    }
                }
                Section("怎么攒") {
                    Stepper("按时交（\(rules.finishTime) 前）+\(rules.onTime)", value: $rules.onTime, in: 0...60)
                    DatePicker("每天完成时间", selection: clockBinding($rules.finishTime), displayedComponents: .hourAndMinute)
                    Stepper("评分 优 +\(rules.gradeExcellent)", value: $rules.gradeExcellent, in: 0...60)
                    Stepper("评分 良 +\(rules.gradeGood)", value: $rules.gradeGood, in: 0...60)
                    Stepper("评分 中 +\(rules.gradeFair)", value: $rules.gradeFair, in: 0...60)
                    Stepper("每天坚持打卡一项 +\(rules.checkin)", value: $rules.checkin, in: 0...60)
                    Stepper("连续打卡 7 天 +\(rules.streak7)", value: $rules.streak7, in: 0...120)
                    Text("订正后评分提高，会补上差额。").font(.footnote).foregroundStyle(Color.ink3)
                }
                Section("怎么用") {
                    Toggle("当天作业全交了才能用", isOn: $rules.requireAllSubmitted)
                    Stepper("每天最多用 \(rules.dailyCap) 分钟", value: $rules.dailyCap, in: 0...240, step: 5)
                    DatePicker("可以用的开始时间", selection: clockBinding($rules.windowStart), displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: clockBinding($rules.windowEnd), displayedComponents: .hourAndMinute)
                }
                Section {
                    Button { save() } label: { HStack { Text(saving ? "正在保存…" : "保存规则").bold(); if saving { ProgressView() } } }
                        .disabled(saving || rules == store.rules)
                } footer: {
                    Text("锁定和解锁动画、游戏 App 需要在孩子的 iPad 上授权“屏幕使用时间”，要等加入付费的 Apple 开发者计划后才能开启。现在奖励时间会照常记账和计时。")
                }
                if let child, let summary = store.rewards[child.id], !summary.entries.isEmpty {
                    Section("最近明细") {
                        ForEach(summary.entries.prefix(20)) { entry in
                            HStack { Text(rewardReason(entry, store: store)); Spacer(); Text(entry.minutes > 0 ? "+\(entry.minutes)" : "\(entry.minutes)").bold().foregroundStyle(entry.minutes > 0 ? Color.honeyInk : Color.ink2) }
                        }
                    }
                }
            }
            .navigationTitle("奖励")
            .toolbar { ToolbarItem(placement: .principal) { ChildSwitcher(childIdText: $childIdText) } }
            .onAppear { rules = store.rules }
            .onChange(of: store.rules) { _, new in if !saving { rules = new } }
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(Color(hex: 0xD9D2C5)); Text(value).font(.headline).foregroundStyle(color) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        saving = true
        Task { await perform(store) { try await store.saveRules(rules) }; saving = false }
    }
}

/// "HH:mm" strings ↔ DatePicker.
func clockBinding(_ text: Binding<String>) -> Binding<Date> {
    Binding(get: {
        let parts = text.wrappedValue.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 19, minute: parts.last ?? 0, second: 0, of: Date()) ?? Date()
    }, set: {
        let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
        text.wrappedValue = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    })
}

@MainActor func rewardReason(_ entry: RewardEntry, store: HomeworkStore) -> String {
    let homeworkId = UUID(uuidString: String(entry.refId.prefix(36)))
    let name = homeworkId.flatMap { store.homework[$0] }.map { "\(SubjectStyle.label($0.subject)) · \($0.content.prefix(12))" }
    switch entry.reason {
    case "ON_TIME": return "\(name ?? "作业") · 按时交"
    case "GRADE": return "\(name ?? "作业") · 评分"
    case "CHECKIN": return "\(name ?? "每天坚持") · 打卡"
    case "STREAK7": return "连续打卡 7 天"
    case "SPEND": return "使用奖励时间"
    default: return entry.reason
    }
}

// MARK: - Settings: children, pairing, devices

struct ParentSettings: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingChild: ChildDraft?
    @State private var code: PairingCode?
    @State private var devices: [DeviceRecord] = []
    @State private var confirmingSignOut = false
    @State private var deletingChild: RemoteChild?

    var body: some View {
        NavigationStack {
            Form {
                Section("孩子") {
                    ForEach(store.children) { child in
                        Button { editingChild = ChildDraft(child) } label: {
                            HStack { Avatar(child: child, size: 32); Text(child.name).foregroundStyle(Color.ink); Spacer(); Text("\(child.grade) 年级").foregroundStyle(Color.ink2) }
                        }
                        .swipeActions { Button("删除", role: .destructive) { deletingChild = child } }
                    }
                    Button { editingChild = ChildDraft() } label: { Label("添加孩子", systemImage: "plus") }
                }
                Section {
                    if let code {
                        VStack(spacing: 6) {
                            Text(code.code).font(.system(size: 44, weight: .black, design: .monospaced)).kerning(6)
                            Text("在孩子的 iPad 上输入，10 分钟内有效").font(.footnote).foregroundStyle(Color.ink2)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    Button(code == nil ? "生成配对码" : "重新生成") { Task { await perform(store) { code = try await store.pairingCode() } } }
                } header: { Text("连接孩子的 iPad") }
                Section("已连接的设备") {
                    ForEach(devices) { device in
                        HStack {
                            Image(systemName: device.role == "parent" ? "iphone" : "ipad.landscape")
                            VStack(alignment: .leading) { Text(device.name.isEmpty ? (device.role == "parent" ? "家长手机" : "孩子 iPad") : device.name); if device.self_ { Text("这台设备").font(.caption).foregroundStyle(Color.ink3) } }
                        }
                        .swipeActions { if !device.self_ { Button("断开", role: .destructive) { Task { await perform(store) { try await store.revoke(device.id); devices = try await store.devices() } } } } }
                    }
                }
                Section {
                    LabeledContent("服务器", value: store.session?.server ?? "")
                    Button("退出这台手机", role: .destructive) { confirmingSignOut = true }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { devices = (try? await store.devices()) ?? [] }
            .sheet(item: $editingChild) { ChildEditor(draft: $0) }
            .confirmationDialog("退出后需要用家长密钥重新连接。", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("退出", role: .destructive) { store.signOut() }
            }
            .alert("删除\(deletingChild?.name ?? "")的全部数据？", isPresented: Binding(get: { deletingChild != nil }, set: { if !$0 { deletingChild = nil } })) {
                Button("删除", role: .destructive) { if let child = deletingChild { Task { await perform(store) { try await store.deleteChild(child.id) } } } }
                Button("取消", role: .cancel) {}
            } message: { Text("会删除这个孩子的作业、照片、录音、批改和奖励，不能恢复。") }
        }
    }
}

struct ChildDraft: Identifiable {
    var id = UUID()
    var name = ""
    var grade = 2
    var isNew = true
    init() {}
    init(_ child: RemoteChild) { id = child.id; name = child.name; grade = child.grade; isNew = false }
}

struct ChildEditor: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: ChildDraft
    var body: some View {
        NavigationStack {
            Form {
                TextField("昵称", text: $draft.name)
                Picker("年级", selection: $draft.grade) { ForEach(1...6, id: \.self) { Text("\($0) 年级").tag($0) } }
            }
            .navigationTitle(draft.isNew ? "添加孩子" : "修改孩子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await perform(store) { try await store.saveChild(id: draft.id, name: draft.name, grade: draft.grade); dismiss() } } }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
