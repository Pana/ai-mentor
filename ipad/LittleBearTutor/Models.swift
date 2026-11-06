import Foundation

// MARK: - Basic types

enum Subject: String, Codable, CaseIterable, Identifiable, Sendable {
    case math = "数学", chinese = "语文", english = "英语"
    var id: String { rawValue }
    var label: String { rawValue }
    /// Value the gateway expects (`MATH` / `CHINESE` / `ENGLISH`).
    var apiName: String {
        switch self { case .math: "MATH"; case .chinese: "CHINESE"; case .english: "ENGLISH" }
    }
    init?(apiName: String) {
        guard let match = Subject.allCases.first(where: { $0.apiName == apiName }) else { return nil }
        self = match
    }
}

enum WorkStatus: String, Codable, Sendable {
    case ready = "待开始", active = "进行中", review = "待检查", correction = "待订正", done = "已完成"
    var editable: Bool { self != .done && self != .review }
}

struct FamilyError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
    var mode = "help"
    var assessment = "UNKNOWN"
    var time = Date()
}

/// A short-answer exercise. Bank exercises are verified; AI-generated ones are not and never count as mastery.
struct Exercise: Codable, Hashable, Sendable {
    var id: String
    var subject: Subject
    var concept: String
    var prompt: String
    var answer: String
    var hints: [String]
    var explanation: String
    var verified = true

    func accepts(_ input: String) -> Bool {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("。") || value.hasSuffix(".") { value.removeLast() }
        return !value.isEmpty && value == answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct Homework: Codable, Identifiable, Sendable {
    var id = UUID()
    var childID: UUID
    var subject: Subject
    var title: String
    var instructions = ""
    var status: WorkStatus = .ready
    var draft = ""
    /// File name inside the app's photo directory (never an absolute path: the container path changes on update).
    var photoPath: String?
    var conversation: [TutorTurn] = []
    var reviewNote = ""
    var aiAssessment = "UNKNOWN"
    var hints = 0
    var failures = 0
    /// Bumped whenever the task content or answer changes; stale tutor replies are rejected.
    var revision = 0
    var practice = false
    var exercise: Exercise?
    var createdAt = Date()
}

struct Evidence: Codable, Identifiable, Sendable {
    var id = UUID()
    var childID: UUID
    var taskID: UUID
    var subject: Subject
    var exerciseID: String
    var concept: String
    var answer: String
    var correct: Bool
    var hints = 0
    var priorFailures = 0
    var verifiedExercise = true
    var independentConfirmed = true
    var origin = "local"
    var note = ""
    var time = Date()

    /// Counts toward mastery only when verified, correct, confirmed independent, without hints or earlier failures.
    var independent: Bool { verifiedExercise && independentConfirmed && correct && hints == 0 && priorFailures == 0 }
}

struct Knowledge: Identifiable {
    var subject: Subject
    var concept: String
    var state: String
    var evidence: [Evidence]
    var id: String { "\(subject.rawValue)|\(concept)" }
}

struct ReviewDue: Identifiable {
    var subject: Subject
    var concept: String
    var dueAt: Date
    var reason: String
    var id: String { "\(subject.rawValue)|\(concept)" }
}

// MARK: - Family state and rules

struct Family: Codable {
    var schemaVersion = 2
    var demo = false
    var children: [Child] = []
    var tasks: [Homework] = []
    var evidence: [Evidence] = []

    func tasks(for child: UUID) -> [Homework] { tasks.filter { $0.childID == child } }
    func homework(for child: UUID) -> [Homework] { tasks(for: child).filter { !$0.practice } }
    func practiceTasks(for child: UUID) -> [Homework] { tasks(for: child).filter(\.practice) }
    func child(_ id: UUID?) -> Child? { children.first { $0.id == id } }
    func task(_ id: UUID?) -> Homework? { tasks.first { $0.id == id } }

    private func index(of taskID: UUID) throws -> Int {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { throw FamilyError("找不到这项作业") }
        return index
    }

    mutating func addChild(name: String, grade: Int, textbook: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20).contains(name.count) else { throw FamilyError("请填写 1–20 字的昵称") }
        guard [2, 3].contains(grade) else { throw FamilyError("首版支持二、三年级") }
        let book = textbook.trimmingCharacters(in: .whitespacesAndNewlines)
        let child = Child(name: name, grade: grade, textbook: book.isEmpty ? "教材版本待确认" : String(book.prefix(300)))
        children.append(child)
        return child.id
    }

    mutating func addTask(_ task: Homework) throws {
        guard children.contains(where: { $0.id == task.childID }) else { throw FamilyError("孩子档案不存在") }
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FamilyError("请填写作业名称") }
        guard task.title.count <= 100, task.instructions.count <= 2000 else { throw FamilyError("作业名称或要求过长") }
        tasks.append(task)
    }

    mutating func open(_ taskID: UUID) throws {
        let i = try index(of: taskID)
        if tasks[i].status == .ready { tasks[i].status = .active }
    }

    mutating func saveDraft(_ taskID: UUID, _ text: String) throws {
        let i = try index(of: taskID)
        guard tasks[i].status.editable else { return }
        let text = String(text.prefix(2000))
        guard tasks[i].draft != text else { return }
        tasks[i].draft = text
        tasks[i].revision += 1
        tasks[i].aiAssessment = "UNKNOWN"
        if tasks[i].status == .ready { tasks[i].status = .active }
    }

    mutating func submit(_ taskID: UUID) throws {
        let i = try index(of: taskID)
        guard tasks[i].status.editable else { throw FamilyError("这项作业已经提交或完成") }
        guard tasks[i].exercise == nil else { throw FamilyError("练习题请直接点“检查一下”") }
        tasks[i].status = .review
        tasks[i].revision += 1
    }

    mutating func parentReview(_ taskID: UUID, passed: Bool, note: String, concept: String = "", independent: Bool = false) throws {
        let i = try index(of: taskID)
        let work = tasks[i]
        guard work.status == .review else { throw FamilyError("请先让孩子提交检查") }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let concept = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 1000, concept.count <= 100 else { throw FamilyError("检查依据或知识点过长") }
        guard concept.isEmpty || !note.isEmpty else { throw FamilyError("记录知识点时，请填写具体检查依据。") }
        tasks[i].status = passed ? .done : .correction
        tasks[i].reviewNote = note
        tasks[i].revision += 1
        if !passed { tasks[i].failures += 1 }
        guard !concept.isEmpty else { return }
        evidence.append(Evidence(childID: work.childID, taskID: work.id, subject: work.subject, exerciseID: work.id.uuidString,
                                 concept: concept, answer: work.draft.isEmpty ? "纸面作业，由家长检查" : work.draft,
                                 correct: passed, hints: work.hints, priorFailures: work.failures,
                                 independentConfirmed: independent, origin: "parent", note: note))
    }

    /// Model feedback is provisional: it never creates mastery evidence or completes homework.
    mutating func applyTutor(_ taskID: UUID, revision: Int, turn: TutorTurn) throws {
        let i = try index(of: taskID)
        guard tasks[i].revision == revision else { throw FamilyError("作业已改变，保留当前内容，请重新求助。") }
        guard tasks[i].status != .done else { throw FamilyError("这项作业已经完成") }
        guard ["UNKNOWN", "CORRECT", "INCORRECT"].contains(turn.assessment) else { throw FamilyError("辅导回复格式无法识别") }
        tasks[i].conversation = Array((tasks[i].conversation + [turn]).suffix(60))
        if turn.mode == "check" { tasks[i].aiAssessment = turn.assessment }
        if turn.mode == "help" { tasks[i].hints += 1 }
    }

    mutating func hint(_ taskID: UUID) throws {
        let i = try index(of: taskID)
        guard tasks[i].status != .done else { return }
        tasks[i].hints = min(tasks[i].hints + 1, 3)
        tasks[i].status = .active
    }

    /// Checks a short-answer exercise locally and records the attempt as evidence.
    mutating func check(_ taskID: UUID, answer: String) throws {
        let i = try index(of: taskID)
        let work = tasks[i]
        guard work.status != .done else { throw FamilyError("这项任务已经完成") }
        guard let exercise = work.exercise else { throw FamilyError("这项作业需要家长检查") }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw FamilyError("先写下你的答案吧") }
        let correct = exercise.accepts(answer)
        evidence.append(Evidence(childID: work.childID, taskID: work.id, subject: work.subject, exerciseID: exercise.id,
                                 concept: exercise.concept, answer: String(answer.prefix(2000)), correct: correct,
                                 hints: work.hints, priorFailures: work.failures, verifiedExercise: exercise.verified,
                                 origin: exercise.verified ? "local" : "ai"))
        tasks[i].draft = String(answer.prefix(2000))
        tasks[i].status = correct ? .done : .correction
        if !correct { tasks[i].failures += 1 }
    }

    /// Returns an unfinished verified practice task for the subject, or creates one from the local bank.
    mutating func localPractice(child childID: UUID, subject: Subject) throws -> UUID {
        if let existing = practiceTasks(for: childID).first(where: {
            $0.subject == subject && $0.status != .done && $0.exercise?.verified == true
        }) { return existing.id }
        let completed = Set(tasks(for: childID).filter { $0.status == .done }.compactMap { $0.exercise?.id })
        let exercise = Exercises.practice(subject, completed: completed)
        let task = Homework(childID: childID, subject: subject, title: "\(subject.label) · 小练习",
                            instructions: "本地基础练习，未对应学校教材", practice: true, exercise: exercise)
        try addTask(task)
        return task.id
    }

    /// Removes the task and its evidence. Returns the photo file to delete, if any.
    mutating func deleteTask(_ taskID: UUID) -> String? {
        let photo = task(taskID)?.photoPath
        tasks.removeAll { $0.id == taskID }
        evidence.removeAll { $0.taskID == taskID }
        return photo
    }

    /// Removes the child with all of their data. Returns photo files to delete.
    mutating func deleteChild(_ childID: UUID) -> [String] {
        let photos = tasks(for: childID).compactMap(\.photoPath)
        children.removeAll { $0.id == childID }
        tasks.removeAll { $0.childID == childID }
        evidence.removeAll { $0.childID == childID }
        return photos
    }

    func knowledge(for childID: UUID) -> [Knowledge] {
        let records = evidence.filter { $0.childID == childID }.sorted { $0.time < $1.time }
        let groups = Dictionary(grouping: records) { "\($0.subject.rawValue)|\($0.concept)" }
        return groups.values.compactMap { items -> Knowledge? in
            guard let first = items.first else { return nil }
            let verified = items.filter(\.verifiedExercise)
            let independentCount = Set(verified.filter(\.independent).map(\.exerciseID)).count
            let state: String
            if let last = verified.last {
                state = !last.correct ? "需要再练练" : (independentCount >= 2 ? "初步掌握" : "学习中")
            } else {
                state = "待核验"
            }
            return Knowledge(subject: first.subject, concept: first.concept, state: state, evidence: items)
        }.sorted { $0.id < $1.id }
    }

    func reviews(for childID: UUID) -> [ReviewDue] {
        knowledge(for: childID).compactMap { item -> ReviewDue? in
            guard let last = item.evidence.filter(\.verifiedExercise).max(by: { $0.time < $1.time }) else { return nil }
            let days = !last.correct ? 0 : (item.state == "初步掌握" ? 3 : 1)
            let reason = !last.correct ? "上次需要订正" : (last.independent ? "隔一段时间再独立试试" : "上次获得过帮助，再试一道不同的题")
            return ReviewDue(subject: item.subject, concept: item.concept,
                             dueAt: last.time.addingTimeInterval(Double(days) * 86_400), reason: reason)
        }.sorted { $0.dueAt < $1.dueAt }
    }

    static func demoFamily() -> Family {
        let lin = Child(name: "林林", grade: 2)
        let qi = Child(name: "琪琪", grade: 3)
        let samples: [(Subject, String, String)] = [
            (.math, "小熊的橡果问题", "小熊有 24 颗橡果，又找到 18 颗。现在一共有多少颗？"),
            (.chinese, "读一读，找一找", "读一读：春天来了，小草绿了，燕子飞回来了。短文描写的是哪个季节？"),
            (.english, "水果单词小练习", "苹果的英文怎么写？填写一个单词。")
        ]
        var family = Family(demo: true, children: [lin, qi])
        family.tasks = [lin, qi].flatMap { child in
            samples.map { Homework(childID: child.id, subject: $0.0, title: $0.1, instructions: $0.2) }
        }
        return family
    }
}

// MARK: - Local exercise bank (mirrors Android `Exercises`)

enum Exercises {
    static let all: [Exercise] = [
        Exercise(id: "addition-42", subject: .math, concept: "两位数进位加法", prompt: "小熊有 24 颗橡果，又找到 18 颗。现在一共有多少颗？请填写一个整数。", answer: "42",
                 hints: ["先想想：橡果变多了，还是变少了？应该用什么方法？", "把 18 分成 10 和 8。先算 24 + 10，再加 8。", "24 + 10 = 34，34 + 8 = 42。也可以看看个位满十后怎样进位。"],
                 explanation: "24 + 18 = 42。个位 4 + 8 = 12，满十向十位进 1。"),
        Exercise(id: "addition-53", subject: .math, concept: "两位数进位加法", prompt: "图书角原来有 36 本书，又放入 17 本。现在一共有多少本？请填写一个整数。", answer: "53",
                 hints: ["书的总数增加了。你会怎样列式？", "先算 36 + 10，再加 7。", "36 + 10 = 46，46 + 7 = 53。"],
                 explanation: "36 + 17 = 53。个位 6 + 7 = 13，需要向十位进 1。"),
        Exercise(id: "reading-spring", subject: .chinese, concept: "从短文提取信息", prompt: "读一读：春天来了，小草绿了，燕子飞回来了。\n短文描写的是哪个季节？请填写两个字。", answer: "春天",
                 hints: ["先找一找，哪句话告诉了我们时间？", "看看短文的开头两个字。", "短文开头写着“春天来了”，所以答案是“春天”。"],
                 explanation: "可以从短文中找到直接说明季节的词语“春天”。"),
        Exercise(id: "reading-autumn", subject: .chinese, concept: "从短文提取信息", prompt: "读一读：秋天到了，树叶黄了，果园里的苹果成熟了。\n短文描写的是哪个季节？请填写两个字。", answer: "秋天",
                 hints: ["哪句话说明了时间？", "先读第一句，再找季节名称。", "“秋天到了”告诉我们答案是“秋天”。"],
                 explanation: "答案是秋天，依据是短文第一句。"),
        Exercise(id: "english-apple", subject: .english, concept: "常见水果单词", prompt: "苹果的英文怎么写？填写一个单词。", answer: "apple",
                 hints: ["这个单词以字母 a 开头。", "这个单词有五个字母，中间有两个 p。", "苹果是 apple。读一遍，再试着自己拼写。"],
                 explanation: "apple 表示苹果。可以这样使用：This is an apple."),
        Exercise(id: "english-pear", subject: .english, concept: "常见水果单词", prompt: "梨的英文怎么写？填写一个单词。", answer: "pear",
                 hints: ["它以字母 p 开头。", "这个单词有四个字母，结尾是 ar。", "梨是 pear。读一遍，再试着自己拼写。"],
                 explanation: "pear 表示梨。可以这样使用：This is a pear.")
    ]

    static func practice(_ subject: Subject, completed: Set<String>) -> Exercise {
        if let next = all.first(where: { $0.subject == subject && !completed.contains($0.id) }) { return next }
        guard subject == .math else { return all.filter { $0.subject == subject }.randomElement()! }
        let a = Int.random(in: 11..<50), b = Int.random(in: 11..<50)
        let tens = b / 10 * 10, ones = b % 10
        return Exercise(id: "addition-\(a)-\(b)", subject: .math, concept: "两位数加法", prompt: "算一算：\(a) + \(b) = ？请填写一个整数。", answer: "\(a + b)",
                        hints: ["先把第二个数分成整十数与个位数。", "先算 \(a) + \(tens)，再加 \(ones)。", "\(a) + \(b) = \(a + b)。检查个位是否需要进位。"],
                        explanation: "把 \(b) 分成 \(tens) 和 \(ones)，分两步加，结果是 \(a + b)。")
    }
}

// MARK: - Tolerant decoding: fields added later get defaults instead of failing the whole file

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension Child {
    enum CodingKeys: String, CodingKey { case id, name, grade, textbook }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        grade = try c.value(.grade, or: 2)
        textbook = try c.value(.textbook, or: "教材版本待确认")
    }
}

extension TutorTurn {
    enum CodingKeys: String, CodingKey { case id, question, reply, mode, assessment, time }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, or: UUID())
        question = try c.decode(String.self, forKey: .question)
        reply = try c.decode(String.self, forKey: .reply)
        mode = try c.value(.mode, or: "help")
        assessment = try c.value(.assessment, or: "UNKNOWN")
        time = try c.value(.time, or: Date())
    }
}

extension Homework {
    enum CodingKeys: String, CodingKey {
        case id, childID, subject, title, instructions, status, draft, photoPath, conversation, reviewNote, aiAssessment
        case hints, failures, revision, practice, exercise, createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        childID = try c.decode(UUID.self, forKey: .childID)
        subject = try c.decode(Subject.self, forKey: .subject)
        title = try c.decode(String.self, forKey: .title)
        instructions = try c.value(.instructions, or: "")
        status = try c.value(.status, or: .ready)
        draft = try c.value(.draft, or: "")
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        conversation = try c.value(.conversation, or: [])
        reviewNote = try c.value(.reviewNote, or: "")
        aiAssessment = try c.value(.aiAssessment, or: "UNKNOWN")
        hints = try c.value(.hints, or: 0)
        failures = try c.value(.failures, or: 0)
        revision = try c.value(.revision, or: 0)
        practice = try c.value(.practice, or: false)
        exercise = try c.decodeIfPresent(Exercise.self, forKey: .exercise)
        createdAt = try c.value(.createdAt, or: Date())
    }
}

extension Evidence {
    enum CodingKeys: String, CodingKey {
        case id, childID, taskID, subject, exerciseID, concept, answer, correct, hints, priorFailures
        case verifiedExercise, independentConfirmed, origin, note, time
    }
    /// Schema 1 stored a single `independent` flag.
    private enum LegacyKeys: String, CodingKey { case independent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.value(.id, or: UUID())
        childID = try c.decode(UUID.self, forKey: .childID)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        subject = try c.decode(Subject.self, forKey: .subject)
        exerciseID = try c.value(.exerciseID, or: taskID.uuidString)
        concept = try c.decode(String.self, forKey: .concept)
        answer = try c.value(.answer, or: "")
        correct = try c.decode(Bool.self, forKey: .correct)
        hints = try c.value(.hints, or: 0)
        priorFailures = try c.value(.priorFailures, or: 0)
        verifiedExercise = try c.value(.verifiedExercise, or: true)
        independentConfirmed = try c.decodeIfPresent(Bool.self, forKey: .independentConfirmed)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .independent) ?? false
        origin = try c.value(.origin, or: "parent")
        note = try c.value(.note, or: "")
        time = try c.value(.time, or: Date())
    }
}

extension Family {
    enum CodingKeys: String, CodingKey { case schemaVersion, demo, children, tasks, evidence }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = 2
        demo = try c.value(.demo, or: false)
        children = try c.value(.children, or: [])
        tasks = try c.value(.tasks, or: [])
        evidence = try c.value(.evidence, or: [])
    }
}
