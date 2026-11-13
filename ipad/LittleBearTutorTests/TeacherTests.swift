import XCTest
@testable import LittleBearTutor

final class TeacherTests: XCTestCase {
    func testAdditionCarries() {
        let calc = ColumnCalc(a: 38, b: 27, op: "+")
        XCTAssertEqual(calc.result, 65)
        XCTAssertEqual(calc.carries, [1: 1])
        XCTAssertEqual(calc.width, 2)
        XCTAssertEqual(ColumnCalc(a: 999, b: 1, op: "+").carries, [1: 1, 2: 1, 3: 1])
        XCTAssertEqual(ColumnCalc(a: 999, b: 1, op: "+").width, 4)
    }

    func testSubtractionBorrows() {
        let calc = ColumnCalc(a: 52, b: 17, op: "-")
        XCTAssertEqual(calc.result, 35)
        XCTAssertEqual(calc.borrows, [1])
        XCTAssertEqual(ColumnCalc(a: 100, b: 1, op: "-").borrows, [1, 2], "borrowing across a zero")
        XCTAssertEqual(ColumnCalc(a: 100, b: 1, op: "-").width, 3)
    }

    func testMultiplicationCarries() {
        let calc = ColumnCalc(a: 47, b: 6, op: "×")
        XCTAssertEqual(calc.result, 282)
        XCTAssertEqual(calc.carries, [1: 4, 2: 2])
    }

    func testDigits() {
        XCTAssertEqual(ColumnCalc.shown(65, 0), 5)
        XCTAssertEqual(ColumnCalc.shown(65, 1), 6)
        XCTAssertNil(ColumnCalc.shown(65, 2))
        XCTAssertEqual(ColumnCalc.shown(0, 0), 0)
    }

    func testBoardOpsUpsertRemoveAndClear() {
        var elements: [BoardElement] = []
        let add: [String: Any] = ["op": "add", "el": ["id": "v1", "type": "vertical", "a": 38, "b": 27, "operator": "+", "reveal": 0, "focus": -1] as [String: Any]]
        XCTAssertEqual(BoardOps.apply(add, to: &elements), "v1")
        let update: [String: Any] = ["op": "update", "el": ["id": "v1", "type": "vertical", "a": 38, "b": 27, "operator": "+", "reveal": 1, "focus": 0] as [String: Any]]
        BoardOps.apply(update, to: &elements)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].kind, .vertical(a: 38, b: 27, op: "+", reveal: 1, focus: 0))
        BoardOps.apply(["op": "add", "el": ["id": "t1", "type": "text", "text": "38 + 27 = ?", "style": "title"]], to: &elements)
        BoardOps.apply(["op": "add", "el": ["id": "x", "type": "hologram"]], to: &elements)
        XCTAssertEqual(elements.map(\.id), ["v1", "t1"], "unknown types are skipped")
        BoardOps.apply(["op": "remove", "id": "v1"], to: &elements)
        XCTAssertEqual(elements.map(\.id), ["t1"])
        BoardOps.apply(["op": "clear"], to: &elements)
        XCTAssertTrue(elements.isEmpty)
    }

    func testBoardElementsParseFromJSON() throws {
        let json = """
        {"id":"b1","type":"bar","rows":[{"label":"小红","parts":[{"value":12,"label":"12本"},{"value":null,"label":"?"}]}],"total":"一共"}
        """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let element = try XCTUnwrap(BoardElement(json: object))
        XCTAssertEqual(element.kind, .bar(rows: [.init(label: "小红", parts: [.init(value: 12, label: "12本"), .init(value: nil, label: "?")])], total: "一共"))
        let jump: [String: Any] = ["from": 8, "to": 13, "label": "+5"]
        let line = try XCTUnwrap(BoardElement(json: ["id": "n1", "type": "number_line", "from": 0, "to": 20, "marks": [8], "jumps": [jump]]))
        XCTAssertEqual(line.kind, .numberLine(from: 0, to: 20, step: 1, marks: [8], jumps: [.init(from: 8, to: 13, label: "+5")]))
    }

    func testVoiceActivityDetector() {
        var vad = VoiceActivityDetector()
        for _ in 0..<50 { XCTAssertNil(vad.process(level: -62, ms: 20, strict: false)) }
        // A short click is not speech.
        XCTAssertNil(vad.process(level: -20, ms: 20, strict: false))
        XCTAssertNil(vad.process(level: -62, ms: 20, strict: false))
        // Sustained speech starts after ~180 ms.
        var events: [VoiceActivityDetector.Event] = []
        for _ in 0..<10 { if let event = vad.process(level: -25, ms: 20, strict: false) { events.append(event) } }
        XCTAssertEqual(events, [.start])
        // Short pauses inside a sentence do not end it; 800 ms of quiet does.
        for _ in 0..<20 { XCTAssertNil(vad.process(level: -62, ms: 20, strict: false)) }
        XCTAssertNil(vad.process(level: -25, ms: 20, strict: false))
        events = []
        for _ in 0..<45 { if let event = vad.process(level: -62, ms: 20, strict: false) { events.append(event) } }
        XCTAssertEqual(events, [.end])
    }

    func testVoiceActivityDetectorIsStricterWhileTeacherTalks() {
        var vad = VoiceActivityDetector()
        for _ in 0..<50 { _ = vad.process(level: -62, ms: 20, strict: true) }
        // Residual echo a little above the room level does not barge in…
        for _ in 0..<20 { XCTAssertNil(vad.process(level: -42, ms: 20, strict: true)) }
        // …but the same level would count when the teacher is quiet.
        var started = false
        for _ in 0..<20 where !started { started = vad.process(level: -42, ms: 20, strict: false) == .start }
        XCTAssertTrue(started)
    }
}
