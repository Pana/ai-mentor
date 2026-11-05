import Foundation
import SwiftUI

enum Subject: String, Codable, CaseIterable, Identifiable, Sendable {
    case math = "数学", chinese = "语文", english = "英语"
    var id: String { rawValue }
}

enum WorkStatus: String, Codable, Sendable {
    case ready = "待开始", active = "进行中", review = "待检查", correction = "待订正", done = "已完成"
}

struct Child: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var grade: Int = 2
    var textbook: String = "教材版本待确认"
}

struct TutorTurn: Codable, Identifiable, Sendable {
    var id = UUID()
    var question: String
    var reply: String
    var assessment: String = "UNKNOWN"
}

struct Homework: Codable, Identifiable, Sendable {
    var id = UUID()
    var childID: UUID
    var subject: Subject
    var title: String
    var instructions: String = ""
    var status: WorkStatus = .ready
    var draft: String = ""
    var photoPath: String?
    var conversation: [TutorTurn] = []
    var reviewNote: String = ""
    var aiAssessment: String = "UNKNOWN"
}

struct Evidence: Codable, Identifiable, Sendable {
    var id = UUID()
    var childID: UUID
    var taskID: UUID
    var subject: Subject
    var concept: String
    var answer: String
    var correct: Bool
    var independent: Bool
    var note: String = ""
    var time = Date()
}

struct Family: Codable {
    var schemaVersion = 1
    var demo = false
    var children: [Child] = []
    var tasks: [Homework] = []
    var evidence: [Evidence] = []

    func tasks(for child: UUID) -> [Homework] { tasks.filter { $0.childID == child } }
    func child(_ id: UUID?) -> Child? { children.first { $0.id == id } }
    func task(_ id: UUID?) -> Homework? { tasks.first { $0.id == id } }

    static func demoFamily() -> Family {
        let lin = Child(name: "林林", grade: 2)
        let qi = Child(name: "琪琪", grade: 3)
        let names: [(Subject, String, String)] = [
            (.math, "小熊的橡果问题", "小熊有 24 颗橡果，又找到 18 颗。现在一共有多少颗？"),
            (.chinese, "读一读，找一找", "读一读：春天来了，小草绿了，燕子飞回来了。短文描写的是哪个季节？"),
            (.english, "水果单词小练习", "苹果的英文怎么写？填写一个单词。")
        ]
        var family = Family(demo: true, children: [lin, qi])
        family.tasks = [lin, qi].flatMap { child in names.map { subject, title, instructions in
            Homework(childID: child.id, subject: subject, title: title, instructions: instructions)
        } }
        return family
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var family = Family()
    @Published var selectedChildID: UUID?
    @Published var selectedTaskID: UUID?
    @Published var errorMessage: String?
    @Published var tutorBusy = false
    @Published var serviceURL = ""
    @Published private(set) var serviceConfigured = false

    private let store = LocalStore()
    private let credentials = CredentialStore()
    private let tutor = TutorClient()

    init() {
        family = store.load() ?? Family()
        selectedChildID = family.children.first?.id
        let config = credentials.load()
        serviceURL = config.url
        serviceConfigured = config.consent && !config.url.isEmpty && !config.token.isEmpty
    }

    var selectedChild: Child? { family.child(selectedChildID) }
    var selectedTask: Homework? { family.task(selectedTaskID) }

    func useDemo() { family = .demoFamily(); selectedChildID = family.children.first?.id; persist() }
    func persist() { do { try store.save(family) } catch { errorMessage = "本地记录保存失败，请检查设备存储空间。" } }
    func addChild(name: String, grade: Int, textbook: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        family.children.append(Child(name: name.trimmingCharacters(in: .whitespacesAndNewlines), grade: grade, textbook: textbook))
        selectedChildID = family.children.last?.id; persist()
    }
    func addTask(subject: Subject, title: String, instructions: String, photoPath: String? = nil) {
        guard let child = selectedChild, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        family.tasks.append(Homework(childID: child.id, subject: subject, title: title, instructions: instructions, photoPath: photoPath))
        persist()
    }
    func updateDraft(_ text: String) {
        guard let id = selectedTaskID, let index = family.tasks.firstIndex(where: { $0.id == id }) else { return }
        family.tasks[index].draft = String(text.prefix(2000)); family.tasks[index].status = .active; persist()
    }
    func submitTask() {
        guard let id = selectedTaskID, let index = family.tasks.firstIndex(where: { $0.id == id }) else { return }
        family.tasks[index].status = .review; persist()
    }
    func attachPhoto(_ data: Data) {
        guard let id = selectedTaskID, let index = family.tasks.firstIndex(where: { $0.id == id }) else { return }
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let path = base.appendingPathComponent("photo-\(id.uuidString).jpg")
            try data.write(to: path, options: .atomic)
            family.tasks[index].photoPath = path.path
            persist()
        } catch { errorMessage = "题目图片保存失败，请重试。" }
    }
    func saveService(url: String, token: String, consent: Bool) {
        do {
            if !consent && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                credentials.clear(); serviceURL = ""; serviceConfigured = false; errorMessage = nil; return
            }
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { throw LocalError.invalidService }
            guard token.count >= 24 && !token.contains(where: { $0.isWhitespace }) else { throw LocalError.invalidService }
            try credentials.save(url: url, token: token, consent: consent)
            serviceURL = url; serviceConfigured = consent && !token.isEmpty; errorMessage = nil
        } catch { errorMessage = "服务地址必须是 HTTPS，并填写设备访问凭证。" }
    }
    func askTutor(message: String, includePhoto: Bool) {
        guard let child = selectedChild, let task = selectedTask else { return }
        guard serviceConfigured else { errorMessage = "请家长先配置辅导服务。"; return }
        tutorBusy = true
        let config = credentials.load()
        Task { @MainActor in
            defer { tutorBusy = false }
            do {
                let reply = try await tutor.ask(config: config, child: child, task: task, message: message, includePhoto: includePhoto ? task.photoPath : nil)
                guard let index = family.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                family.tasks[index].conversation.append(TutorTurn(question: message, reply: reply.message, assessment: reply.assessment))
                family.tasks[index].aiAssessment = reply.assessment
                persist()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func markTask(_ taskID: UUID, passed: Bool, note: String, concept: String = "", independent: Bool = false) {
        guard let index = family.tasks.firstIndex(where: { $0.id == taskID }), family.tasks[index].status == .review else { return }
        let task = family.tasks[index]
        family.tasks[index].status = passed ? .done : .correction
        family.tasks[index].reviewNote = String(note.prefix(1000))
        if !concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            family.evidence.append(Evidence(childID: task.childID, taskID: task.id, subject: task.subject,
                concept: String(concept.prefix(100)), answer: task.draft.isEmpty ? "纸面作业" : task.draft,
                correct: passed, independent: passed && independent, note: String(note.prefix(1000))))
        }
        persist()
    }
    func deleteTask(_ taskID: UUID) {
        guard let task = family.tasks.first(where: { $0.id == taskID }) else { return }
        family.tasks.removeAll { $0.id == taskID }
        family.evidence.removeAll { $0.taskID == taskID }
        if let path = task.photoPath { try? FileManager.default.removeItem(atPath: path) }
        if selectedTaskID == taskID { selectedTaskID = nil }
        persist()
    }
    func deleteChild(_ childID: UUID) {
        let taskIDs = family.tasks.filter { $0.childID == childID }.map(\.id)
        for task in family.tasks where task.childID == childID { if let path = task.photoPath { try? FileManager.default.removeItem(atPath: path) } }
        family.children.removeAll { $0.id == childID }
        family.tasks.removeAll { $0.childID == childID }
        family.evidence.removeAll { $0.childID == childID || taskIDs.contains($0.taskID) }
        if selectedChildID == childID { selectedChildID = family.children.first?.id; selectedTaskID = nil }
        persist()
    }
    func clearLocalFamily() {
        for task in family.tasks { if let path = task.photoPath { try? FileManager.default.removeItem(atPath: path) } }
        family = Family(); selectedChildID = nil; selectedTaskID = nil; credentials.clear(); serviceURL = ""; serviceConfigured = false; persist()
    }
}

enum LocalError: Error { case invalidService }

struct LocalStore {
    private var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("family-v1.json")
    }
    func load() -> Family? { guard let data = try? Data(contentsOf: file) else { return nil }; return try? JSONDecoder().decode(Family.self, from: data) }
    func save(_ family: Family) throws { let data = try JSONEncoder().encode(family); try data.write(to: file, options: .atomic) }
}
