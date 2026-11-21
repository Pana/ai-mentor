import SwiftUI

// MARK: - Whiteboard model (mirrors `server/src/board.mjs`)
// The server validates every op and always sends whole elements, so `add` and `update` are both upserts here.

struct BoardElement: Identifiable, Equatable, Sendable {
    struct Jump: Equatable, Sendable { var from: Int; var to: Int; var label: String }
    struct BarPart: Equatable, Sendable { var value: Double?; var label: String }
    struct BarRow: Equatable, Sendable { var label: String; var parts: [BarPart] }
    struct PinyinLine: Equatable, Sendable { var text: String; var pinyin: [String] }

    enum Kind: Equatable, Sendable {
        case text(String, style: String)
        case vertical(a: Int, b: Int, op: String, reveal: Int, focus: Int)
        case numberLine(from: Int, to: Int, step: Int, marks: [Int], jumps: [Jump])
        case dots(groups: Int, per: Int, highlight: Int, label: String)
        case bar(rows: [BarRow], total: String)
        case clock(hour: Int, minute: Int, label: String)
        case pinyin(title: String, lines: [PinyinLine])
        case hanzi(char: String, pinyin: String, parts: [String], words: [String], note: String)
        case word(word: String, syllables: String, meaning: String, example: String)
    }

    let id: String
    var kind: Kind

    init(id: String, kind: Kind) { self.id = id; self.kind = kind }

    /// Parses one element from the wire; nil for an unknown type, so a newer server never breaks the board.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let type = json["type"] as? String else { return nil }
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func string(_ key: String) -> String { json[key] as? String ?? "" }
        self.id = id
        switch type {
        case "text":
            guard let text = json["text"] as? String else { return nil }
            kind = .text(text, style: string("style"))
        case "vertical":
            guard let a = int("a"), let b = int("b"), let op = json["operator"] as? String else { return nil }
            kind = .vertical(a: a, b: b, op: op, reveal: int("reveal") ?? 0, focus: int("focus") ?? -1)
        case "number_line":
            guard let from = int("from"), let to = int("to"), to > from else { return nil }
            let marks = (json["marks"] as? [NSNumber])?.map(\.intValue) ?? []
            let jumps = (json["jumps"] as? [[String: Any]] ?? []).compactMap { j -> Jump? in
                guard let f = (j["from"] as? NSNumber)?.intValue, let t = (j["to"] as? NSNumber)?.intValue else { return nil }
                return Jump(from: f, to: t, label: j["label"] as? String ?? "")
            }
            kind = .numberLine(from: from, to: to, step: max(1, int("step") ?? 1), marks: marks, jumps: jumps)
        case "dots":
            guard let groups = int("groups"), let per = int("per") else { return nil }
            kind = .dots(groups: groups, per: per, highlight: int("highlight") ?? 0, label: string("label"))
        case "bar":
            let rows = (json["rows"] as? [[String: Any]] ?? []).map { row in
                BarRow(label: row["label"] as? String ?? "", parts: (row["parts"] as? [[String: Any]] ?? []).map {
                    BarPart(value: ($0["value"] as? NSNumber)?.doubleValue, label: $0["label"] as? String ?? "")
                })
            }
            guard !rows.isEmpty else { return nil }
            kind = .bar(rows: rows, total: string("total"))
        case "clock":
            guard let hour = int("hour") else { return nil }
            kind = .clock(hour: hour, minute: int("minute") ?? 0, label: string("label"))
        case "pinyin":
            let lines = (json["lines"] as? [[String: Any]] ?? []).compactMap { line -> PinyinLine? in
                guard let text = line["text"] as? String, let pinyin = line["pinyin"] as? String else { return nil }
                return PinyinLine(text: text, pinyin: pinyin.split(separator: " ").map(String.init))
            }
            guard !lines.isEmpty else { return nil }
            kind = .pinyin(title: string("title"), lines: lines)
        case "hanzi":
            guard let char = json["char"] as? String, !char.isEmpty else { return nil }
            kind = .hanzi(char: char, pinyin: string("pinyin"), parts: json["parts"] as? [String] ?? [],
                          words: json["words"] as? [String] ?? [], note: string("note"))
        case "word":
            guard let word = json["word"] as? String, !word.isEmpty else { return nil }
            kind = .word(word: word, syllables: string("syllables"), meaning: string("meaning"), example: string("example"))
        default:
            return nil
        }
    }
}

/// The element the board should scroll to. `tick` changes on every op, so updating the same element scrolls again.
struct BoardFocus: Equatable, Sendable {
    var id: String
    var tick: Int
}

enum BoardOps {
    /// Applies one server op to `elements`; returns the id that changed, for scrolling to it.
    @discardableResult
    static func apply(_ op: [String: Any], to elements: inout [BoardElement]) -> String? {
        switch op["op"] as? String {
        case "clear":
            elements.removeAll()
            return nil
        case "remove":
            guard let id = op["id"] as? String else { return nil }
            elements.removeAll { $0.id == id }
            return nil
        case "add", "update":
            guard let json = op["el"] as? [String: Any], let element = BoardElement(json: json) else { return nil }
            if let index = elements.firstIndex(where: { $0.id == element.id }) { elements[index] = element }
            else { elements.append(element) }
            return element.id
        default:
            return nil
        }
    }
}

/// Column arithmetic for the 竖式 view: digits by column (0 = ones), carries and borrows.
struct ColumnCalc: Equatable {
    let a: Int, b: Int, op: String
    let result: Int
    /// Carry written into a column (from the column to its right), for + and ×.
    let carries: [Int: Int]
    /// Columns of `a` that lent 1 to the column on their right, for −.
    let borrows: Set<Int>

    init(a: Int, b: Int, op: String) {
        self.a = a; self.b = b; self.op = op
        var carries: [Int: Int] = [:], borrows = Set<Int>()
        switch op {
        case "-":
            result = a - b
            var borrow = 0
            for column in 0..<ColumnCalc.digits(a) {
                let top = ColumnCalc.digit(a, column) - borrow, bottom = ColumnCalc.digit(b, column)
                borrow = top < bottom ? 1 : 0
                if borrow == 1 { borrows.insert(column + 1) }
            }
        case "×":
            result = a * b
            var carry = 0
            for column in 0..<ColumnCalc.digits(a) {
                carry = (ColumnCalc.digit(a, column) * b + carry) / 10
                if carry > 0 { carries[column + 1] = carry }
            }
        default:
            result = a + b
            var carry = 0
            for column in 0..<max(ColumnCalc.digits(a), ColumnCalc.digits(b)) {
                carry = (ColumnCalc.digit(a, column) + ColumnCalc.digit(b, column) + carry) / 10
                if carry > 0 { carries[column + 1] = carry }
            }
        }
        self.carries = carries
        self.borrows = borrows
    }

    var width: Int { max(Self.digits(a), Self.digits(b), Self.digits(result)) }

    static func digits(_ n: Int) -> Int { String(abs(n)).count }
    static func digit(_ n: Int, _ column: Int) -> Int { (abs(n) / Int(pow(10, Double(column)))) % 10 }
    /// The digit shown in a column, or nil left of the number's first digit.
    static func shown(_ n: Int, _ column: Int) -> Int? { column < digits(n) ? digit(n, column) : nil }
}

// MARK: - Board view

struct WhiteboardView: View {
    let elements: [BoardElement]
    let focus: BoardFocus?
    var placeholder: AnyView? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(elements) { element in
                        BoardElementView(element: element)
                            .id(element.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading)), removal: .opacity))
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(duration: 0.45), value: elements)
            }
            .onChange(of: focus) { _, focus in
                guard let focus else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(focus.id, anchor: .center) }
            }
        }
        .overlay { if elements.isEmpty, let placeholder { placeholder } }
        .background(BoardPaper())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.line, lineWidth: 2))
    }
}

/// White paper with a faint square grid, like an exercise book.
struct BoardPaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var grid = Path()
            let step: CGFloat = 32
            for x in stride(from: step, to: size.width, by: step) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: step, to: size.height, by: step) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(grid, with: .color(Color(hex: 0xEEF2F6)), lineWidth: 1)
        }
    }
}

struct BoardElementView: View {
    let element: BoardElement
    var body: some View {
        switch element.kind {
        case let .text(text, style): BoardText(text: text, style: style)
        case let .vertical(a, b, op, reveal, focus): VerticalCalcView(calc: ColumnCalc(a: a, b: b, op: op), reveal: reveal, focus: focus)
        case let .numberLine(from, to, step, marks, jumps): NumberLineView(from: from, to: to, step: step, marks: marks, jumps: jumps)
        case let .dots(groups, per, highlight, label): DotsView(groups: groups, per: per, highlight: highlight, label: label)
        case let .bar(rows, total): BarModelView(rows: rows, total: total)
        case let .clock(hour, minute, label): ClockView(hour: hour, minute: minute, label: label)
        case let .pinyin(title, lines): PinyinLinesView(title: title, lines: lines)
        case let .hanzi(char, pinyin, parts, words, note): HanziCardView(char: char, pinyin: pinyin, parts: parts, words: words, note: note)
        case let .word(word, syllables, meaning, example): WordCardView(word: word, syllables: syllables, meaning: meaning, example: example)
        }
    }
}

/// 拼音行: each character with its syllable above it; punctuation sits on the line without one.
struct PinyinLinesView: View {
    let title: String
    let lines: [BoardElement.PinyinLine]
    var body: some View {
        VStack(spacing: 8) {
            if !title.isEmpty { Text(title).font(.system(size: 32, weight: .heavy, design: .rounded)).foregroundStyle(Color.ink) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowRow(spacing: 2) {
                    ForEach(Array(cells(line).enumerated()), id: \.offset) { _, cell in
                        VStack(spacing: 2) {
                            Text(cell.mark ?? " ").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(Color.pine)
                            Text(cell.char).font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(cell.mark == nil ? Color.ink3 : Color.ink)
                        }
                        .frame(minWidth: 50)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Characters paired with their syllables in order; punctuation and other symbols get none.
    private func cells(_ line: BoardElement.PinyinLine) -> [(char: String, mark: String?)] {
        var next = 0
        return line.text.map { ch in
            let isHan = ch.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FFFF).contains($0.value) }
            defer { if isHan { next += 1 } }
            return (String(ch), isHan && next < line.pinyin.count ? line.pinyin[next] : nil)
        }
    }
}

/// 生字卡: the character in a 田字格 with its pinyin above, then its parts and words.
struct HanziCardView: View {
    let char: String, pinyin: String, parts: [String], words: [String], note: String
    private let grid = Color(hex: 0xC94A3A)
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 4) {
                Text(pinyin).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Color.pine)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.card)
                    Canvas { context, size in
                        var dash = Path()
                        dash.move(to: CGPoint(x: size.width / 2, y: 0)); dash.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                        dash.move(to: CGPoint(x: 0, y: size.height / 2)); dash.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        dash.move(to: .zero); dash.addLine(to: CGPoint(x: size.width, y: size.height))
                        dash.move(to: CGPoint(x: size.width, y: 0)); dash.addLine(to: CGPoint(x: 0, y: size.height))
                        context.stroke(dash, with: .color(grid.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    }
                    RoundedRectangle(cornerRadius: 6).stroke(grid, lineWidth: 3)
                    Text(char).font(.system(size: 120, weight: .regular, design: .serif)).foregroundStyle(Color.ink)
                }
                .frame(width: 160, height: 160)
            }
            VStack(alignment: .leading, spacing: 12) {
                if !parts.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            if index > 0 { Text("+").font(.system(size: 30, weight: .bold)).foregroundStyle(Color.ink3) }
                            Text(part).font(.system(size: 34, weight: .bold)).foregroundStyle(Color.honeyInk)
                                .padding(.horizontal, 12).padding(.vertical, 2).background(Color.honeySoft, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !words.isEmpty {
                    FlowRow(spacing: 8) {
                        ForEach(words, id: \.self) { word in
                            Text(word).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.pine)
                                .padding(.horizontal, 12).padding(.vertical, 4).background(Color.pineSoft, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !note.isEmpty { Text(note).font(.system(size: 21)).foregroundStyle(Color.ink2) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("生字 \(char) \(pinyin)")
    }
}

/// 单词卡: the word, its syllables, what it means, and an example.
struct WordCardView: View {
    let word: String, syllables: String, meaning: String, example: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(word).font(.system(size: 56, weight: .heavy, design: .rounded)).foregroundStyle(Color.ink)
            if !syllables.isEmpty { Text(syllables).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(Color.honeyInk).kerning(1.5) }
            if !meaning.isEmpty { Text(meaning).font(.system(size: 28, weight: .bold)).foregroundStyle(Color.pine) }
            if !example.isEmpty { Text(example).font(.system(size: 22, design: .rounded)).italic().foregroundStyle(Color.ink2) }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.line, lineWidth: 2))
    }
}

struct BoardText: View {
    let text: String
    let style: String
    var body: some View {
        switch style {
        case "title":
            Text(text).font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(Color.ink)
        case "answer":
            Text(text).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.pine)
                .padding(.horizontal, 18).padding(.vertical, 8).background(Color.pineSoft, in: RoundedRectangle(cornerRadius: 16))
        case "hint":
            Label(text, systemImage: "lightbulb.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.honeyInk)
                .padding(.horizontal, 16).padding(.vertical, 10).background(Color.honeySoft, in: RoundedRectangle(cornerRadius: 16))
        default:
            Text(text).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(Color.ink)
        }
    }
}

/// 竖式: operands right-aligned, carries above the line, result digits revealed from the ones column.
struct VerticalCalcView: View {
    let calc: ColumnCalc
    let reveal: Int
    let focus: Int
    private let cell: CGFloat = 64

    var body: some View {
        let columns = calc.width + 1 // one extra on the left for the operator
        VStack(alignment: .trailing, spacing: 0) {
            row(columns) { column in borrowMark(column) }.frame(height: 20)
            row(columns) { column in digit(ColumnCalc.shown(calc.a, column)) }
            row(columns, operatorSign: calc.op) { column in digit(ColumnCalc.shown(calc.b, column)) }
            row(columns) { column in carryMark(column) }.frame(height: 24)
            Rectangle().fill(Color.ink).frame(width: CGFloat(columns) * cell, height: 4).clipShape(Capsule())
            row(columns) { column in
                digit(column < reveal ? ColumnCalc.shown(calc.result, column) : nil, color: .pine)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("竖式 \(calc.a) \(calc.op) \(calc.b)")
    }

    /// One row of cells, rightmost cell = ones column; `operatorSign` fills the leftmost cell.
    private func row<Cell: View>(_ columns: Int, operatorSign: String? = nil, @ViewBuilder cellContent: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 0) {
            ForEach((0..<columns).reversed(), id: \.self) { column in
                ZStack {
                    if column == focus { Color.honeySoft }
                    if column == columns - 1, let operatorSign {
                        Text(operatorSign).font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(Color.ink2)
                    } else {
                        cellContent(column)
                    }
                }
                .frame(width: cell)
            }
        }
    }

    private func digit(_ value: Int?, color: Color = .ink) -> some View {
        Text(value.map(String.init) ?? " ").font(.system(size: 50, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(color).frame(height: cell)
            .id(value) // a digit being written is a new view, so it scales in
            .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder private func carryMark(_ column: Int) -> some View {
        if let carry = calc.carries[column], column - 1 < reveal {
            Text(String(carry)).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Color.redPen)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
        }
    }

    @ViewBuilder private func borrowMark(_ column: Int) -> some View {
        if calc.borrows.contains(column), column - 1 < reveal {
            Circle().fill(Color.redPen).frame(width: 9, height: 9)
        }
    }
}

struct NumberLineView: View {
    let from: Int, to: Int, step: Int
    let marks: [Int]
    let jumps: [BoardElement.Jump]

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 24, right = size.width - 24, axis = size.height - 46
            func x(_ n: Int) -> CGFloat { left + (right - left) * CGFloat(n - from) / CGFloat(to - from) }
            var line = Path(); line.move(to: CGPoint(x: left - 12, y: axis)); line.addLine(to: CGPoint(x: right + 12, y: axis))
            context.stroke(line, with: .color(.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            for n in stride(from: from, through: to, by: step) {
                var tick = Path(); tick.move(to: CGPoint(x: x(n), y: axis - 10)); tick.addLine(to: CGPoint(x: x(n), y: axis + 10))
                context.stroke(tick, with: .color(.ink), lineWidth: 2)
                context.draw(Text(String(n)).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundColor(.ink2), at: CGPoint(x: x(n), y: axis + 28))
            }
            for n in marks {
                context.fill(Path(ellipseIn: CGRect(x: x(n) - 9, y: axis - 9, width: 18, height: 18)), with: .color(.redPen))
            }
            for jump in jumps {
                let start = CGPoint(x: x(jump.from), y: axis - 12), end = CGPoint(x: x(jump.to), y: axis - 12)
                let height = min(90, max(36, abs(end.x - start.x) * 0.45))
                let control = CGPoint(x: (start.x + end.x) / 2, y: axis - 12 - height * 1.6)
                var arc = Path(); arc.move(to: start); arc.addQuadCurve(to: end, control: control)
                context.stroke(arc, with: .color(.pine), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                let direction: CGFloat = end.x > start.x ? -1 : 1
                var head = Path(); head.move(to: CGPoint(x: end.x + direction * 10, y: end.y - 10)); head.addLine(to: end); head.addLine(to: CGPoint(x: end.x + direction * 2, y: end.y - 14))
                context.stroke(head, with: .color(.pine), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if !jump.label.isEmpty {
                    context.draw(Text(jump.label).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.pine),
                                 at: CGPoint(x: control.x, y: axis - 12 - height * 0.8 - 18))
                }
            }
        }
        .frame(height: 190)
        .frame(maxWidth: 820)
        .accessibilityLabel("数轴 \(from) 到 \(to)")
    }
}

struct DotsView: View {
    let groups: Int, per: Int, highlight: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowRow(spacing: 14) {
                ForEach(0..<groups, id: \.self) { group in
                    let columns = per <= 4 ? per : Int(ceil(Double(per) / 2))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: max(1, min(columns, 6))), spacing: 8) {
                        ForEach(0..<per, id: \.self) { _ in Circle().fill(group < highlight ? Color.honey : Color(hex: 0x1F55B0)).frame(width: 22, height: 22) }
                    }
                    .padding(12)
                    .background(group < highlight ? Color.honeySoft : Color(hex: 0xE4EEFB), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            if !label.isEmpty { Text(label).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink2) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(groups) 组，每组 \(per) 个")
    }
}

/// Wraps children onto new lines when they do not fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(subviews, width: bounds.width).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}

/// 线段图: each row's parts share one scale; an unknown part (nil value) is drawn dashed with its label.
struct BarModelView: View {
    let rows: [BoardElement.BarRow]
    let total: String
    private let colors: [Color] = [Color(hex: 0x1F55B0), Color(hex: 0xE39A3B), .pine, Color(hex: 0x5B3FB0), Color(hex: 0xA63A16)]

    var body: some View {
        let known = rows.flatMap(\.parts).compactMap(\.value)
        let unknownWidth = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        let length = { (part: BoardElement.BarPart) in part.value ?? unknownWidth }
        let longest = rows.map { $0.parts.map(length).reduce(0, +) }.max() ?? 1
        GeometryReader { geometry in
            let labelWidth: CGFloat = rows.contains { !$0.label.isEmpty } ? 96 : 0
            let scale = (min(geometry.size.width, 820) - labelWidth - 8) / CGFloat(longest)
            VStack(alignment: .leading, spacing: 18) {
                if !total.isEmpty {
                    HStack(spacing: 0) {
                        Spacer().frame(width: labelWidth)
                        VStack(spacing: 2) {
                            Text(total).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
                            Brace().stroke(Color.ink2, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).frame(height: 14)
                        }
                        .frame(width: CGFloat(longest) * scale)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        Text(row.label).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(Color.ink2)
                            .frame(width: labelWidth, alignment: .leading)
                        ForEach(Array(row.parts.enumerated()), id: \.offset) { partIndex, part in
                            let color = colors[(rowIndex + partIndex) % colors.count]
                            ZStack {
                                if part.value == nil {
                                    RoundedRectangle(cornerRadius: 6).stroke(Color.redPen, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18))
                                    RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3)
                                }
                                Text(part.label).font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(part.value == nil ? Color.redPen : Color.ink).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
                            }
                            .frame(width: max(24, CGFloat(length(part)) * scale), height: 44)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(rows.count) * 62 + (total.isEmpty ? 0 : 50))
        .frame(maxWidth: 820)
    }
}

/// A horizontal curly brace opening downward, spanning the frame.
struct Brace: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX, top = rect.minY, bottom = rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 12, y: rect.midY), control: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: mid - 10, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: mid, y: top), control: CGPoint(x: mid, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: mid + 10, y: rect.midY), control: CGPoint(x: mid, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 12, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bottom), control: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct ClockView: View {
    let hour: Int, minute: Int
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - 6
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.cardSoft))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.ink), lineWidth: 5)
                func point(_ fraction: Double, _ length: CGFloat) -> CGPoint {
                    let angle = fraction * 2 * .pi - .pi / 2
                    return CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
                }
                for tick in 0..<60 {
                    var path = Path(); path.move(to: point(Double(tick) / 60, radius - (tick % 5 == 0 ? 14 : 7))); path.addLine(to: point(Double(tick) / 60, radius - 3))
                    context.stroke(path, with: .color(.ink2), lineWidth: tick % 5 == 0 ? 3 : 1)
                }
                for n in 1...12 {
                    context.draw(Text(String(n)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.ink), at: point(Double(n) / 12, radius - 34))
                }
                let hourFraction = (Double(hour % 12) + Double(minute) / 60) / 12
                var hourHand = Path(); hourHand.move(to: center); hourHand.addLine(to: point(hourFraction, radius * 0.5))
                context.stroke(hourHand, with: .color(.ink), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                var minuteHand = Path(); minuteHand.move(to: center); minuteHand.addLine(to: point(Double(minute) / 60, radius * 0.78))
                context.stroke(minuteHand, with: .color(.redPen), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(.ink))
            }
            .frame(width: 240, height: 240)
            if !label.isEmpty { Text(label).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Color.ink) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("钟面 \(hour) 点 \(minute) 分")
    }
}
