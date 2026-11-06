import XCTest
@testable import LittleBearTutor

final class FamilyRulesTests: XCTestCase {
    private var family = Family()
    private var lin = UUID()
    private var qi = UUID()

    override func setUpWithError() throws {
        family = Family()
        lin = try family.addChild(name: "林林", grade: 2, textbook: "")
        qi = try family.addChild(name: "琪琪", grade: 3, textbook: "人教版")
    }

    private func homework(_ child: UUID, _ subject: Subject = .math) throws -> UUID {
        let task = Homework(childID: child, subject: subject, title: "口算", instructions: "第 12 页")
        try family.addTask(task)
        return task.id
    }

    func testChildValidation() {
        XCTAssertThrowsError(try family.addChild(name: "  ", grade: 2, textbook: ""))
        XCTAssertThrowsError(try family.addChild(name: "小明", grade: 4, textbook: ""))
        XCTAssertEqual(family.child(lin)?.textbook, "教材版本待确认")
    }

    func testParentReviewRequiresNoteForConceptAndRecordsEvidence() throws {
        let id = try homework(lin)
        try family.saveDraft(id, "42")
        try family.submit(id)
        XCTAssertThrowsError(try family.parentReview(id, passed: true, note: "", concept: "进位加法"))
        try family.parentReview(id, passed: true, note: "竖式正确", concept: "进位加法", independent: true)
        XCTAssertEqual(family.task(id)?.status, .done)
        XCTAssertEqual(family.evidence.count, 1)
        XCTAssertTrue(family.evidence[0].independent)
        XCTAssertEqual(family.evidence[0].origin, "parent")
    }

    func testHelpedHomeworkIsNotIndependent() throws {
        let id = try homework(lin)
        let revision = family.task(id)!.revision
        try family.applyTutor(id, revision: revision, turn: TutorTurn(question: "怎么做", reply: "先想想", mode: "help"))
        try family.submit(id)
        try family.parentReview(id, passed: true, note: "正确", concept: "进位加法", independent: true)
        XCTAssertFalse(family.evidence[0].independent, "a hint was used, so it cannot count as independent")
    }

    func testStaleTutorReplyIsRejectedAndCheckNeverCompletes() throws {
        let id = try homework(lin)
        let revision = family.task(id)!.revision
        try family.saveDraft(id, "41")
        XCTAssertThrowsError(try family.applyTutor(id, revision: revision, turn: TutorTurn(question: "q", reply: "r")))
        let current = family.task(id)!.revision
        try family.applyTutor(id, revision: current, turn: TutorTurn(question: "检查", reply: "对", mode: "check", assessment: "CORRECT"))
        XCTAssertEqual(family.task(id)?.aiAssessment, "CORRECT")
        XCTAssertEqual(family.task(id)?.status, .active)
        XCTAssertTrue(family.evidence.isEmpty)
    }

    func testDraftChangeResetsAIAssessment() throws {
        let id = try homework(lin)
        try family.applyTutor(id, revision: 0, turn: TutorTurn(question: "检查", reply: "错", mode: "check", assessment: "INCORRECT"))
        try family.saveDraft(id, "42")
        XCTAssertEqual(family.task(id)?.aiAssessment, "UNKNOWN")
    }

    func testExerciseCheckRecordsEvidenceAndFailures() throws {
        let id = try family.localPractice(child: lin, subject: .math)
        XCTAssertEqual(family.task(id)?.exercise?.id, "addition-42")
        try family.check(id, answer: "41")
        XCTAssertEqual(family.task(id)?.status, .correction)
        XCTAssertEqual(family.task(id)?.failures, 1)
        try family.check(id, answer: " 42。")
        XCTAssertEqual(family.task(id)?.status, .done)
        XCTAssertEqual(family.evidence.map(\.correct), [false, true])
        XCTAssertFalse(family.evidence[1].independent, "correct after a failure is not independent")
        XCTAssertThrowsError(try family.check(id, answer: "42"))
    }

    func testLocalPracticeReusesUnfinishedThenAdvances() throws {
        let first = try family.localPractice(child: lin, subject: .english)
        XCTAssertEqual(try family.localPractice(child: lin, subject: .english), first)
        try family.check(first, answer: "apple")
        let second = try family.localPractice(child: lin, subject: .english)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(family.task(second)?.exercise?.id, "english-pear")
        XCTAssertTrue(family.homework(for: lin).isEmpty, "practice is kept out of the homework list")
    }

    func testKnowledgeStatesAndUnverifiedExercises() throws {
        let a = try family.localPractice(child: lin, subject: .math)
        try family.check(a, answer: "42")
        XCTAssertEqual(family.knowledge(for: lin).first?.state, "学习中")
        let b = try family.localPractice(child: lin, subject: .math)
        try family.check(b, answer: "53")
        XCTAssertEqual(family.knowledge(for: lin).first?.state, "初步掌握")

        let generated = Exercise(id: "ai-1", subject: .chinese, concept: "近义词", prompt: "“高兴”的近义词？", answer: "快乐",
                                 hints: ["1", "2", "3"], explanation: "e", verified: false)
        let task = Homework(childID: lin, subject: .chinese, title: "近义词", practice: true, exercise: generated)
        try family.addTask(task)
        try family.check(task.id, answer: "快乐")
        let item = family.knowledge(for: lin).first { $0.concept == "近义词" }
        XCTAssertEqual(item?.state, "待核验")
        XCTAssertFalse(item!.evidence[0].independent)
        XCTAssertNil(family.reviews(for: lin).first { $0.concept == "近义词" }, "unverified work does not schedule review")
    }

    func testReviewSchedule() throws {
        let id = try family.localPractice(child: lin, subject: .math)
        try family.check(id, answer: "1")
        let due = try XCTUnwrap(family.reviews(for: lin).first)
        XCTAssertLessThanOrEqual(due.dueAt, Date())
        XCTAssertEqual(due.reason, "上次需要订正")

        let other = try family.localPractice(child: qi, subject: .english)
        try family.check(other, answer: "apple")
        let next = try XCTUnwrap(family.reviews(for: qi).first)
        XCTAssertEqual(next.dueAt.timeIntervalSince(family.evidence.last!.time), 86_400, accuracy: 1)
    }

    func testChildIsolationOnDelete() throws {
        let a = try homework(lin)
        let b = try homework(qi)
        family.tasks[family.tasks.firstIndex { $0.id == a }!].photoPath = "photo-a.jpg"
        try family.submit(a); try family.parentReview(a, passed: true, note: "ok", concept: "c")
        try family.submit(b); try family.parentReview(b, passed: true, note: "ok", concept: "c")
        let photos = family.deleteChild(lin)
        XCTAssertEqual(photos, ["photo-a.jpg"])
        XCTAssertNil(family.task(a))
        XCTAssertNotNil(family.task(b))
        XCTAssertEqual(family.evidence.map(\.childID), [qi])
    }

    func testSchemaOneJSONStillLoads() throws {
        let child = UUID(), task = UUID()
        let json = """
        {"schemaVersion":1,"demo":true,
         "children":[{"id":"\(child)","name":"林林","grade":2,"textbook":"教材版本待确认"}],
         "tasks":[{"id":"\(task)","childID":"\(child)","subject":"数学","title":"口算","instructions":"","status":"待检查",
                   "draft":"42","photoPath":"/old/container/Library/Application Support/photo-x.jpg",
                   "conversation":[{"id":"\(UUID())","question":"q","reply":"r","assessment":"UNKNOWN"}],
                   "reviewNote":"","aiAssessment":"UNKNOWN"}],
         "evidence":[{"id":"\(UUID())","childID":"\(child)","taskID":"\(task)","subject":"数学","concept":"加法",
                      "answer":"42","correct":true,"independent":true,"note":"ok","time":0}]}
        """
        let loaded = try JSONDecoder().decode(Family.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.tasks.first?.status, .review)
        XCTAssertEqual(loaded.tasks.first?.hints, 0)
        XCTAssertEqual(loaded.tasks.first?.conversation.first?.mode, "help")
        XCTAssertTrue(loaded.evidence.first!.independentConfirmed)
        XCTAssertEqual(loaded.evidence.first?.exerciseID, task.uuidString)
        XCTAssertEqual(PhotoStore().url(for: loaded.tasks.first?.photoPath)?.lastPathComponent, "photo-x.jpg")
    }
}
