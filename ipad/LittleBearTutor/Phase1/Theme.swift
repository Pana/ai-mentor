import SwiftUI
import UIKit

// MARK: - Palette (matches the design canvas)

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let paper = Color(hex: 0xF5F1E8)
    static let card = Color.white
    static let cardSoft = Color(hex: 0xFBF8F2)
    static let line = Color(hex: 0xE6DFD2)
    static let ink = Color(hex: 0x23201C)
    static let ink2 = Color(hex: 0x5E574E)
    static let ink3 = Color(hex: 0x7A7268)
    static let pine = Color(hex: 0x1E6F55)
    static let pineSoft = Color(hex: 0xE3F1EA)
    static let honey = Color(hex: 0xF0A531)
    static let honeySoft = Color(hex: 0xFDF0D8)
    static let honeyInk = Color(hex: 0x8A5300)
    static let chip = Color(hex: 0xF0EBE1)
    static let redPen = Color(hex: 0xD23C2B)
}

enum SubjectStyle {
    static let all = ["CHINESE", "MATH", "ENGLISH", "OTHER"]
    static func label(_ subject: String) -> String {
        ["CHINESE": "语文", "MATH": "数学", "ENGLISH": "英语"][subject] ?? "其他"
    }
    static func colors(_ subject: String) -> (fg: Color, bg: Color) {
        switch subject {
        case "CHINESE": (Color(hex: 0xA63A16), Color(hex: 0xFCE8E0))
        case "MATH": (Color(hex: 0x1F55B0), Color(hex: 0xE4EEFB))
        case "ENGLISH": (Color(hex: 0x5B3FB0), Color(hex: 0xEEE8FB))
        default: (Color(hex: 0x4C5A3A), Color(hex: 0xE9EEDF))
        }
    }
}

enum GradeStyle {
    static let all = ["EXCELLENT", "GOOD", "FAIR", "TRY_AGAIN"]
    static func label(_ grade: String) -> String {
        ["EXCELLENT": "优", "GOOD": "良", "FAIR": "中", "TRY_AGAIN": "再努力"][grade] ?? grade
    }
    static func color(_ grade: String) -> Color {
        switch grade { case "EXCELLENT": .pine; case "GOOD": Color(hex: 0x4E9A7E); case "FAIR": Color(hex: 0x8A7A3A); default: Color(hex: 0xA04A06) }
    }
}

/// How a homework item is done, in the child's words.
func modeLabel(_ item: RemoteHomework) -> String {
    if item.isOffline { return "本子上写 · 拍照交" }
    if item.isRecording { return "在 iPad 上录音" }
    if let minutes = item.durationMinutes { return "在 iPad 上计时 \(minutes) 分钟" }
    return "在 iPad 上做"
}

// MARK: - Small pieces

struct SubjectTag: View {
    let subject: String
    var size: CGFloat = 15
    var body: some View {
        let c = SubjectStyle.colors(subject)
        Text(SubjectStyle.label(subject)).font(.system(size: size, weight: .bold)).foregroundStyle(c.fg)
            .padding(.horizontal, size * 0.7).padding(.vertical, size * 0.2).background(c.bg, in: RoundedRectangle(cornerRadius: size * 0.65))
    }
}

struct Chip: View {
    let text: String
    var fg: Color = .ink2
    var bg: Color = .chip
    var size: CGFloat = 15
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, size * 0.7).padding(.vertical, size * 0.25).background(bg, in: RoundedRectangle(cornerRadius: size * 0.65))
    }
}

/// Status in the child's words: 还没开始 / 要订正 / 等家长批改 / 已批改.
struct StatusChip: View {
    let item: RemoteHomework
    var size: CGFloat = 15
    var pending = false
    var body: some View {
        if pending { Chip(text: "等网络上传", fg: .ink2, bg: .chip, size: size) }
        else {
            switch item.status {
            case "NEEDS_CORRECTION": Chip(text: "要订正", fg: Color(hex: 0xA04A06), bg: Color(hex: 0xFDEBDC), size: size)
            case "SUBMITTED": Chip(text: "等家长批改", fg: Color(hex: 0x34557A), bg: Color(hex: 0xE8EEF6), size: size)
            case "REVIEWED":
                if let grade = item.latestReview?.grade { GradeBadge(grade: grade, size: size * 1.9) }
                else { Chip(text: "完成了", fg: .pine, bg: .pineSoft, size: size) }
            default: Chip(text: "还没开始", size: size)
            }
        }
    }
}

struct GradeBadge: View {
    let grade: String
    var size: CGFloat = 30
    var body: some View {
        Text(GradeStyle.label(grade)).font(.system(size: grade == "TRY_AGAIN" ? size * 0.32 : size * 0.52, weight: .black))
            .foregroundStyle(.white).frame(width: size, height: size).background(GradeStyle.color(grade), in: Circle())
            .accessibilityLabel("评分 \(GradeStyle.label(grade))")
    }
}

struct Avatar: View {
    let child: RemoteChild
    var size: CGFloat = 40
    private static let palette: [(Color, Color)] = [(Color(hex: 0xCDE7DA), .pine), (Color(hex: 0xFCE3D2), Color(hex: 0xA63A16)), (Color(hex: 0xE4EEFB), Color(hex: 0x1F55B0)), (Color(hex: 0xEEE8FB), Color(hex: 0x5B3FB0))]
    var body: some View {
        let colors = Self.palette[Int(child.id.uuid.15) % Self.palette.count]
        Text(String(child.name.prefix(1))).font(.system(size: size * 0.45, weight: .black)).foregroundStyle(colors.1)
            .frame(width: size, height: size).background(colors.0, in: Circle())
    }
}

/// The little bear, drawn so it needs no image assets.
struct BearView: View {
    var size: CGFloat = 64
    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 64
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color) {
                context.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: .color(color))
            }
            let ear = Color(hex: 0xC9822B), inner = Color(hex: 0xF6D7A7), dark = Color(hex: 0x2A1E14)
            circle(16, 16, 10, ear); circle(48, 16, 10, ear); circle(16, 16, 5, inner); circle(48, 16, 5, inner)
            circle(32, 35, 24, Color(hex: 0xE39A3B))
            context.fill(Path(ellipseIn: CGRect(x: 21 * s, y: 35.5 * s, width: 22 * s, height: 17 * s)), with: .color(inner))
            circle(23, 31, 3, dark); circle(41, 31, 3, dark)
            context.fill(Path(ellipseIn: CGRect(x: 28.4 * s, y: 37.4 * s, width: 7.2 * s, height: 5.2 * s)), with: .color(dark))
            var smile = Path()
            smile.move(to: CGPoint(x: 28 * s, y: 46 * s))
            smile.addQuadCurve(to: CGPoint(x: 36 * s, y: 46 * s), control: CGPoint(x: 32 * s, y: 49 * s))
            context.stroke(smile, with: .color(dark), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("小熊")
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var background: Color = .card
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .pine
    var height: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: height * 0.34, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, height * 0.5).frame(minHeight: height)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: height * 0.33, weight: .bold)).foregroundStyle(Color.ink)
            .padding(.horizontal, height * 0.45).frame(minHeight: height)
            .background(Color.card.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().stroke(Color.line, lineWidth: 2))
    }
}

/// An image stored on the server, cached on the device.
struct RemoteImage: View {
    @EnvironmentObject private var store: HomeworkStore
    let fileId: UUID
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else if failed { Image(systemName: "photo").font(.title).foregroundStyle(Color.ink3).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.chip) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.chip) }
        }
        .task(id: fileId) {
            if let data = try? await store.fileData(fileId), let loaded = UIImage(data: data) { image = loaded } else { failed = true }
        }
    }
}

/// A submitted page with the parent's red-pen overlay drawn on top at the same aspect-fit frame.
struct AnnotatedPage: View {
    let photo: UUID
    let overlay: UUID?
    var body: some View {
        ZStack {
            RemoteImage(fileId: photo)
            if let overlay { RemoteImage(fileId: overlay).allowsHitTesting(false) }
        }
    }
}

struct SyncFootnote: View {
    @EnvironmentObject private var store: HomeworkStore
    var body: some View {
        HStack(spacing: 6) {
            if store.syncing { ProgressView().controlSize(.mini) }
            if !store.outbox.isEmpty { Text("\(store.outbox.count) 项等网络上传") }
            else if let date = store.lastSynced { Text("已同步 \(date.formatted(date: .omitted, time: .shortened))") }
            else { Text("还没有同步") }
        }
        .font(.footnote).foregroundStyle(Color.ink3)
    }
}

/// Shows `store.errorMessage` once as an alert.
struct StoreErrorAlert: ViewModifier {
    @EnvironmentObject private var store: HomeworkStore
    func body(content: Content) -> some View {
        content.alert("提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") {}
        } message: { Text(store.errorMessage ?? "") }
    }
}

extension View {
    func storeErrors() -> some View { modifier(StoreErrorAlert()) }
}

/// Runs an async action and routes its error to the store's alert.
@MainActor func perform(_ store: HomeworkStore, _ action: @escaping () async throws -> Void) async {
    do { try await action() } catch is CancellationError {} catch { store.errorMessage = error.localizedDescription }
}
