import Foundation
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var family = Family()
    @Published var selectedChildID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var tutorBusy = false
    @Published private(set) var serviceURL = ""
    @Published private(set) var serviceConfigured = false

    private let store: LocalStore
    private let credentials = CredentialStore()
    private let tutor = TutorClient()
    let photos = PhotoStore()
    private var tutorJob: Task<Void, Never>?
    /// Incremented on every cancel/new request so a late reply from an abandoned request is dropped.
    private var tutorEpoch = 0

    init(store: LocalStore = LocalStore()) {
        self.store = store
        switch store.load() {
        case .empty: family = Family()
        case .loaded(let saved): family = saved
        case .unreadable(let backup):
            family = Family()
            errorMessage = "本地记录无法读取，已另存为 \(backup) 以便恢复，当前从空白家庭开始。"
        }
        selectedChildID = family.children.first?.id
        let config = credentials.load()
        serviceURL = config.url
        serviceConfigured = config.consent && !config.url.isEmpty && !config.token.isEmpty
    }

    var selectedChild: Child? { family.child(selectedChildID) }

    // MARK: Persistence

    private func persist() {
        do { try store.save(family) } catch { errorMessage = "本地记录保存失败，请检查设备存储空间。" }
    }

    /// Applies a rule from `Family`; on failure nothing changes and the message is shown.
    @discardableResult
    private func mutate<T>(_ change: (inout Family) throws -> T) -> T? {
        var next = family
        do {
            let result = try change(&next)
            family = next
            persist()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Family and children

    func useDemo() {
        family = .demoFamily()
        selectedChildID = family.children.first?.id
        persist()
    }

    func selectChild(_ id: UUID) {
        guard id != selectedChildID else { return }
        cancelTutor()
        selectedChildID = id
    }

    func editChild(_ id: UUID, name: String, grade: Int, textbook: String, studyMinutes: Int) -> Bool {
        mutate { try $0.editChild(id, name: name, grade: grade, textbook: textbook, studyMinutes: studyMinutes) } != nil
    }

    func addChild(name: String, grade: Int, textbook: String) {
        if let id = mutate({ try $0.addChild(name: name, grade: grade, textbook: textbook) }) { selectedChildID = id }
    }

    func deleteChild(_ childID: UUID) {
        cancelTutor()
        let removed = mutate { $0.deleteChild(childID) } ?? []
        removed.forEach { photos.delete($0) }
        if selectedChildID == childID { selectedChildID = family.children.first?.id }
    }

    func clearLocalFamily() {
        cancelTutor()
        family = Family()
        selectedChildID = nil
        photos.deleteAll()
        credentials.clear()
        serviceURL = ""
        serviceConfigured = false
        persist()
    }

    // MARK: Homework

    func addTask(subject: Subject, title: String, instructions: String, photoPath: String? = nil) {
        guard let child = selectedChild else { return }
        mutate {
            try $0.addTask(Homework(childID: child.id, subject: subject, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines), photoPath: photoPath))
        }
    }

    func openTask(_ id: UUID) { mutate { try $0.open(id) } }
    func editTask(_ id: UUID, subject: Subject, title: String, instructions: String) -> Bool {
        cancelTutor()
        return mutate { try $0.editTask(id, subject: subject, title: title, instructions: instructions) } != nil
    }

    /// Saves elapsed study time. Silently skipped if the task was deleted meanwhile.
    func recordStudy(_ session: StudySession) {
        guard session.seconds > 0, family.task(session.taskID) != nil else { return }
        mutate { try $0.recordStudy(session) }
    }
    func saveDraft(_ id: UUID, _ text: String) { mutate { try $0.saveDraft(id, text) } }
    func submitTask(_ id: UUID) { mutate { try $0.submit(id) } }
    func hint(_ id: UUID) { mutate { try $0.hint(id) } }
    func checkExercise(_ id: UUID, answer: String) { mutate { try $0.check(id, answer: answer) } }

    func parentReview(_ id: UUID, passed: Bool, note: String, concept: String, independent: Bool) -> Bool {
        mutate { try $0.parentReview(id, passed: passed, note: note, concept: concept, independent: independent) } != nil
    }

    func deleteTask(_ id: UUID) {
        cancelTutor()
        photos.delete(mutate { $0.deleteTask(id) } ?? nil)
    }

    // MARK: Photos

    func photoURL(_ name: String?) -> URL? { photos.url(for: name) }

    /// Saves picked image data as a gateway-ready JPEG and returns its file name.
    func storePhoto(_ data: Data) -> String? {
        do { return try photos.save(data) } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Deletes a photo that no task references (e.g. an add-task sheet that was cancelled).
    func discardPhoto(_ name: String?) {
        guard let name, !family.tasks.contains(where: { $0.photoPath == name }) else { return }
        photos.delete(name)
    }

    func attachPhoto(_ data: Data, to taskID: UUID) {
        guard let name = storePhoto(data) else { return }
        let old = family.task(taskID)?.photoPath
        let saved: Void? = mutate { family -> Void in
            guard let i = family.tasks.firstIndex(where: { $0.id == taskID }) else { throw FamilyError("找不到这项作业") }
            family.tasks[i].photoPath = name
            family.tasks[i].revision += 1
        }
        if saved == nil { photos.delete(name) } else if old != name { discardPhoto(old) }
    }

    // MARK: Service settings

    func saveService(url: String, token: String, consent: Bool) {
        cancelTutor()
        // Turning consent off removes the stored token; nothing is sent until a parent configures it again.
        if !consent {
            credentials.clear(); serviceURL = ""; serviceConfigured = false; return
        }
        do {
            let parsed = try TutorClient.validate(url: url, token: token)
            try credentials.save(url: parsed.absoluteString, token: token, consent: consent)
            serviceURL = parsed.absoluteString
            serviceConfigured = consent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Tutor requests

    func cancelTutor() {
        tutorEpoch += 1
        tutorJob?.cancel()
        tutorJob = nil
        tutorBusy = false
    }

    /// Asks for a hint (`help`) or a provisional check (`check`) on a homework task.
    func askTutor(taskID: UUID, mode: String, message: String, includePhoto: Bool, onSuccess: @escaping () -> Void = {}) {
        guard let task = family.task(taskID), let child = family.child(task.childID) else { return }
        let question = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = question.isEmpty ? (mode == "check" ? "帮我检查这份作业" : "给我一点提示") : question
        request(mode: mode, child: child, subject: task.subject, task: task, message: shown,
                photo: includePhoto ? task.photoPath : nil) { [weak self] reply in
            guard let self else { return }
            let turn = TutorTurn(question: shown, reply: reply.message, mode: mode, assessment: reply.assessment ?? "UNKNOWN")
            if self.mutate({ try $0.applyTutor(task.id, revision: task.revision, turn: turn) }) != nil { onSuccess() }
        }
    }

    /// Reads homework requirements from a photo. The result is a draft the parent must confirm.
    func recognize(photo: String, subject: Subject, onResult: @escaping (TutorResponse) -> Void) {
        guard let child = selectedChild else { return }
        request(mode: "recognize", child: child, subject: subject, task: nil,
                message: "请识别照片中的作业要求", photo: photo, onResult: onResult)
    }

    /// Opens a similar AI-generated exercise, or falls back to the local bank when the service is off.
    func generatePractice(subject: Subject, concept: String, onCreated: @escaping (UUID) -> Void) {
        guard let child = selectedChild else { return }
        guard serviceConfigured else {
            if let id = startLocalPractice(subject) { onCreated(id) }
            return
        }
        let topic = concept.isEmpty ? "\(subject.label)基础知识" : concept
        request(mode: "practice", child: child, subject: subject, task: nil,
                message: "请围绕\(topic)生成一道适合\(child.grade)年级的练习", photo: nil) { [weak self] reply in
            guard let self else { return }
            guard let exercise = reply.exercise?.unverified(expected: subject) else {
                self.errorMessage = "这次练习生成不完整，请重试。"; return
            }
            let task = Homework(childID: child.id, subject: subject, title: String(exercise.concept.prefix(100)),
                                instructions: "AI 生成练习，答案供参考；疑问请向家长核对", practice: true, exercise: exercise)
            if self.mutate({ try $0.addTask(task) }) != nil { onCreated(task.id) }
        }
    }

    func startLocalPractice(_ subject: Subject) -> UUID? {
        guard let child = selectedChild else { return nil }
        return mutate { try $0.localPractice(child: child.id, subject: subject) }
    }

    private func request(mode: String, child: Child, subject: Subject, task: Homework?, message: String, photo: String?,
                         onResult: @escaping (TutorResponse) -> Void) {
        guard !tutorBusy else { return }
        guard serviceConfigured else { errorMessage = TutorError.notEnabled.errorDescription; return }
        let config = credentials.load()
        tutorEpoch += 1
        let epoch = tutorEpoch
        tutorBusy = true
        tutorJob = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try photo.map { try self.photos.base64($0) }
                let body = TutorRequest(mode: mode, child: child, subject: subject, task: task, message: message, image: image)
                let reply = try await self.tutor.send(config: config, body: body)
                guard epoch == self.tutorEpoch, !Task.isCancelled else { return }
                self.finish(epoch)
                guard self.family.child(child.id) != nil else { return }
                onResult(reply)
            } catch is CancellationError {
                // Cancelled by the user, page change or child switch: keep local data untouched.
            } catch {
                guard epoch == self.tutorEpoch else { return }
                self.errorMessage = error.localizedDescription
            }
            self.finish(epoch)
        }
    }

    private func finish(_ epoch: Int) {
        guard epoch == tutorEpoch else { return }
        tutorBusy = false
        tutorJob = nil
    }
}

// MARK: - Local JSON store

struct LocalStore {
    enum LoadResult { case empty, loaded(Family), unreadable(backup: String) }

    var fileName = "family-v1.json"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var file: URL { directory.appendingPathComponent(fileName) }

    /// A file that exists but cannot be decoded is moved aside instead of being overwritten by an empty family.
    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: file) else { return .empty }
        if let family = try? JSONDecoder().decode(Family.self, from: data) { return .loaded(family) }
        let backup = "\(fileName).unreadable-\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(backup))
        return .unreadable(backup: backup)
    }

    func save(_ family: Family) throws {
        let data = try JSONEncoder().encode(family)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}
