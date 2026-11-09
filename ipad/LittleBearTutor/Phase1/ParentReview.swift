import AVFoundation
import PencilKit


import SwiftUI
import UIKit

// MARK: - Grading: mark up each page, then grade and comment

enum MarkTool: String, CaseIterable, Identifiable {
    case pen, check, circle
    var id: String { rawValue }
    var label: String { switch self { case .pen: "红笔"; case .check: "打勾"; case .circle: "圈出" } }
    var icon: String { switch self { case .pen: "pencil.tip"; case .check: "checkmark"; case .circle: "circle" } }
}

/// Red-pen drawings per page, with an undo history and PNG export at the photo's displayed frame.
@MainActor final class AnnotationModel: ObservableObject {
    @Published var drawings: [Int: PKDrawing] = [:]
    @Published private var history: [Int: [PKDrawing]] = [:]
    var sizes: [Int: CGSize] = [:]

    func set(_ drawing: PKDrawing, page: Int) {
        history[page, default: []].append(drawings[page] ?? PKDrawing())
        drawings[page] = drawing
    }
    /// Adds a ✓ or ○ in red pen at a point in the page's coordinates.
    func stamp(_ tool: MarkTool, at p: CGPoint, page: Int) {
        let points: [CGPoint]
        switch tool {
        case .check: points = [CGPoint(x: p.x - 16, y: p.y), CGPoint(x: p.x - 5, y: p.y + 13), CGPoint(x: p.x + 20, y: p.y - 18)]
        case .circle: points = (0...36).map { i in let a = Double(i) / 36 * 2 * .pi; return CGPoint(x: p.x + 34 * cos(a), y: p.y + 24 * sin(a)) }
        case .pen: return
        }
        let strokePoints = points.enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) * 0.01, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var drawing = drawings[page] ?? PKDrawing()
        drawing.strokes.append(PKStroke(ink: AnnotationCanvas.ink.ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date())))
        set(drawing, page: page)
    }
    func canUndo(_ page: Int) -> Bool { !(history[page]?.isEmpty ?? true) }
    func undo(_ page: Int) {
        guard let previous = history[page]?.popLast() else { return }
        drawings[page] = previous
    }
    var isEmpty: Bool { drawings.values.allSatisfy { $0.strokes.isEmpty } }

    /// One transparent PNG per page (so overlays line up with pages by index), or none when nothing was marked.
    func overlays(pages: Int) -> [Data] {
        guard !isEmpty else { return [] }
        return (0..<pages).map { page in
            let size = sizes[page] ?? CGSize(width: 300, height: 400)
            let image = (drawings[page] ?? PKDrawing()).image(from: CGRect(origin: .zero, size: size), scale: 2)
            return image.pngData() ?? Data()
        }
    }
}

struct AnnotationCanvas: UIViewRepresentable {
    @ObservedObject var model: AnnotationModel
    let page: Int
    let tool: MarkTool

    static let ink = PKInkingTool(.pen, color: UIColor(red: 0.82, green: 0.24, blue: 0.17, alpha: 1), width: 5)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = Self.ink
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        canvas.drawingGestureRecognizer.isEnabled = tool == .pen
        let drawing = model.drawings[page] ?? PKDrawing()
        if canvas.drawing != drawing {
            context.coordinator.applying = true
            canvas.drawing = drawing
            context.coordinator.applying = false
        }
    }

    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: AnnotationCanvas
        var applying = false
        init(_ parent: AnnotationCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard !applying, canvas.drawing != parent.model.drawings[parent.page] else { return }
            parent.model.set(canvas.drawing, page: parent.page)
        }

    }
}

/// One submitted page sized to the photo, with the drawing layer exactly on top of it.
struct AnnotatePage: View {
    @EnvironmentObject private var store: HomeworkStore
    let fileId: UUID
    let page: Int
    @ObservedObject var model: AnnotationModel
    let tool: MarkTool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityIdentifier("review-page")
                    .overlay(GeometryReader { geo in
                        ZStack {
                            AnnotationCanvas(model: model, page: page, tool: tool)
                            // Stamps are placed by a plain SwiftUI tap, which nothing inside PencilKit can swallow.
                            if tool != .pen {
                                Color.clear.contentShape(Rectangle())
                                    .onTapGesture(coordinateSpace: .local) { point in model.stamp(tool, at: point, page: page) }
                                    .accessibilityLabel("在这一页上\(tool.label)")
                            }
                        }
                        .onAppear { model.sizes[page] = geo.size }
                        .onChange(of: geo.size) { _, size in model.sizes[page] = size }
                    })
            } else { ProgressView().tint(.white) }
        }
        .task { if let data = try? await store.fileData(fileId) { image = UIImage(data: data) } }
    }
}

struct ReviewFlow: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    let item: RemoteHomework
    let submission: Submission
    @StateObject private var marks = AnnotationModel()
    @State private var page = 0
    @State private var tool = MarkTool.pen
    @State private var grading = false

    var body: some View {
        NavigationStack {
            Group {
                if item.isOffline && !grading { annotate } else { GradeForm(item: item, submission: submission, marks: marks, onDone: { dismiss() }) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if grading && item.isOffline { Button("批注") { grading = false } } else { Button("取消") { dismiss() } }
                }
            }
        }
    }

    private var annotate: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(submission.fileIds.enumerated()), id: \.offset) { index, file in
                    AnnotatePage(fileId: file, page: index, model: marks, tool: tool).padding(12).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: submission.fileIds.count > 1 ? .always : .never))
            VStack(spacing: 12) {
                HStack {
                    ForEach(MarkTool.allCases) { t in
                        Button { tool = t } label: {
                            VStack(spacing: 2) { Image(systemName: t.icon).font(.title3); Text(t.label).font(.caption2) }
                                .frame(width: 60, height: 52).background(tool == t ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(tool == t ? Color(hex: 0xE5584A) : Color(hex: 0xD9D2C5))
                        }
                        .accessibilityLabel(t.label)
                        .accessibilityIdentifier("tool-\(t.rawValue)")
                        .accessibilityAddTraits(tool == t ? .isSelected : [])
                    }
                    Button { marks.undo(page) } label: {
                        VStack(spacing: 2) { Image(systemName: "arrow.uturn.backward").font(.title3); Text("撤销").font(.caption2) }.frame(width: 60, height: 52).foregroundStyle(Color(hex: 0xD9D2C5))
                    }.disabled(!marks.canUndo(page))
                }
                Button("下一步：打分") { grading = true }.buttonStyle(PrimaryButtonStyle(height: 50)).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(Color(hex: 0x26241F))
        }
        .background(Color(hex: 0x1B1A18).ignoresSafeArea())
        .toolbarBackground(Color(hex: 0x1B1A18), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle("\(SubjectStyle.label(item.subject)) · 第 \(page + 1) / \(submission.fileIds.count) 页")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GradeForm: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    let submission: Submission
    @ObservedObject var marks: AnnotationModel
    let onDone: () -> Void
    @State private var grade = "EXCELLENT"
    @State private var requireCorrection = false
    @State private var comment = ""
    @State private var saving = false
    private let phrases = ["字很工整", "比昨天进步了", "再细心一点", "订正好就是优"]

    var body: some View {
        Form {
            Section {
                HStack {
                    SubjectTag(subject: item.subject, size: 13)
                    Text(item.content).lineLimit(2)
                }
                if !item.isRoutine { Text(submission.onTime ? "按时交（\(store.rules.finishTime) 前）" : "晚于 \(store.rules.finishTime) 交").font(.footnote).foregroundStyle(submission.onTime ? Color.pine : Color(hex: 0xA04A06)) }
                if item.isRecording, let audio = submission.fileIds.first { AudioPlayerButton(fileId: audio) }
                if item.isOffline { Text(marks.isEmpty ? "没有批注" : "已批注").font(.footnote).foregroundStyle(Color.ink3) }
            }
            Section("评分") {
                HStack(spacing: 8) {
                    ForEach(GradeStyle.all, id: \.self) { g in
                        Button { grade = g } label: {
                            Text(GradeStyle.label(g)).font(.system(size: g == "TRY_AGAIN" ? 15 : 20, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(grade == g ? Color.pineSoft : Color.card, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(grade == g ? Color.pine : Color.line, lineWidth: grade == g ? 2 : 1))
                                .foregroundStyle(grade == g ? Color.pine : Color.ink)
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(grade == g ? .isSelected : [])
                    }
                }
                Toggle("要求订正后再交", isOn: $requireCorrection)
            }
            Section("评语") {
                TextField("写给孩子的话", text: $comment, axis: .vertical).lineLimit(2...5)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(phrases, id: \.self) { p in Button(p) { comment = comment.isEmpty ? p : comment + "，" + p }.buttonStyle(.bordered).font(.footnote) } }
                }
            }
            Section {
                if !item.isRoutine && submission.onTime && submission.attempt == 1 { HStack { Text("按时交"); Spacer(); Text("+\(store.rules.onTime) 分钟").bold() } }
                HStack { Text("评分 \(GradeStyle.label(grade))"); Spacer(); Text("+\(gradeTopUp) 分钟").bold() }
                if requireCorrection { Text("订正后评分提高，会补上差额。").font(.footnote).foregroundStyle(Color.ink2) }
            } header: { Text("这次的奖励") }
            .listRowBackground(Color.honeySoft)
            Section {
                Button { save() } label: { HStack { Text(saving ? "正在发送…" : "完成批改，发给\(store.child(item.childId)?.name ?? "孩子")").bold(); if saving { ProgressView() } } }
                    .disabled(saving)
            }
        }
        .navigationTitle("打分与评语")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("发送") { save() }.disabled(saving) } }
    }

    /// Grade points minus what earlier grades on this homework already paid.
    private var gradeTopUp: Int {
        let earlier = item.submissions.compactMap { $0.review?.grade }.map { store.rules.points(for: $0) }.max() ?? 0
        return max(0, store.rules.points(for: grade) - earlier)
    }

    private func save() {
        saving = true
        Task {
            await perform(store) {
                try await store.review(submission, of: item, grade: grade, comment: comment, requireCorrection: requireCorrection,
                                       overlays: marks.overlays(pages: submission.fileIds.count))
                onDone()
            }
            saving = false
        }
    }
}

// MARK: - Audio playback (recorded reading / recitation)

@MainActor final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    private var player: AVAudioPlayer?
    func stop() { player?.stop(); playing = false }
    func toggle(_ data: Data) {
        if playing { stop(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        playing = player?.play() ?? false
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}

struct AudioPlayerButton: View {
    @EnvironmentObject private var store: HomeworkStore
    let fileId: UUID
    @StateObject private var playback = AudioPlayback()
    @State private var data: Data?
    var body: some View {
        Button {
            if let data { playback.toggle(data) }
        } label: {
            Label(data == nil ? "正在加载录音…" : (playback.playing ? "停止" : "播放录音"), systemImage: playback.playing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.bordered).disabled(data == nil)
        .task { data = try? await store.fileData(fileId) }
    }
}
