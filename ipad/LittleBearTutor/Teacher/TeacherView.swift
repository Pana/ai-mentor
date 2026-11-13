import SwiftUI
import UIKit

/// 小熊老师: a full-screen voice conversation with a whiteboard. The child just talks (no button to hold);
/// tapping the bear while it talks interrupts it, and the keyboard is there for when speech is not available.
struct TeacherView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var teacher = TeacherSession()
    let child: RemoteChild
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private let suggestions = ["教我算 38 + 27", "今天有什么作业？", "怎么看钟表上的时间？", "为什么会有白天和黑夜？"]

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                topBar
                Group {
                    if wide {
                        HStack(spacing: 24) {
                            board
                            panel(wide: true).frame(width: min(360, geometry.size.width * 0.3))
                        }
                    } else {
                        VStack(spacing: 20) {
                            board
                            panel(wide: false).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                if typing { inputBar }
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .task { connect() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            teacher.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func connect() {
        guard let session = store.session else { return }
        teacher.start(session: session, child: child)
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Label("结束", systemImage: "xmark").font(.system(size: 19, weight: .bold)).foregroundStyle(Color.ink)
                    .padding(.horizontal, 20).frame(height: 52).background(Color.card, in: Capsule()).overlay(Capsule().stroke(Color.line))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("小熊老师").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Color.ink)
                Text("和\(child.name)一起学").font(.system(size: 15)).foregroundStyle(Color.ink3)
            }
            Spacer()
            if teacher.voiceInput {
                Button { teacher.muted.toggle() } label: {
                    Image(systemName: teacher.muted ? "mic.slash.fill" : "mic.fill").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(teacher.muted ? Color.redPen : Color.ink).frame(width: 52, height: 52)
                        .background(Color.card, in: Circle()).overlay(Circle().stroke(Color.line))
                }
                .accessibilityLabel(teacher.muted ? "打开麦克风" : "关闭麦克风")
            }
            Button { typing.toggle() } label: {
                Image(systemName: "keyboard").font(.system(size: 22, weight: .semibold)).foregroundStyle(typing ? Color.pine : Color.ink)
                    .frame(width: 52, height: 52).background(typing ? Color.pineSoft : Color.card, in: Circle()).overlay(Circle().stroke(Color.line))
            }
            .accessibilityLabel("打字")
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var board: some View {
        WhiteboardView(elements: teacher.elements, focus: teacher.focus, placeholder: AnyView(emptyBoard))
    }

    private var emptyBoard: some View {
        VStack(spacing: 22) {
            Text("想学什么，直接跟小熊说吧！").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Color.ink2)
            FlowRow(spacing: 12) {
                ForEach(suggestions, id: \.self) { text in
                    Button { teacher.say(text) } label: {
                        Text(text).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.pine)
                            .padding(.horizontal, 18).frame(height: 48).background(Color.pineSoft, in: Capsule())
                    }
                    .disabled(!teacher.canTalk)
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(32)
    }

    /// The bear and what is being said: a column beside the board in landscape, a row under it in portrait.
    @ViewBuilder private func panel(wide: Bool) -> some View {
        if wide {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                orb(size: 200)
                status
                texts
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .center, spacing: 24) {
                VStack(spacing: 10) { orb(size: 140); status }
                VStack(spacing: 12) { texts }.frame(maxWidth: .infinity)
            }
        }
    }

    private func orb(size: CGFloat) -> some View {
        BearOrb(phase: teacher.phase, level: teacher.voiceLevel, size: size)
            .onTapGesture { teacher.interrupt() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("小熊说话时点一下可以打断")
    }

    private var status: some View {
        Text(statusText).font(.system(size: 20, weight: .bold)).foregroundStyle(statusColor).multilineTextAlignment(.center)
    }

    @ViewBuilder private var texts: some View {
        if teacher.awaitingAnswer && teacher.phase == .listening {
            Chip(text: "轮到你说啦", fg: .honeyInk, bg: .honeySoft, size: 17)
        }
        if !teacher.caption.isEmpty {
            Text(teacher.caption).font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(Color.ink)
                .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.7)
                .padding(16).frame(maxWidth: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 20))
                .animation(.easeInOut(duration: 0.2), value: teacher.caption)
        }
        if !teacher.heard.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Avatar(child: child, size: 30)
                Text(teacher.heard).font(.system(size: 18)).foregroundStyle(Color.ink2).lineLimit(3)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.chip, in: RoundedRectangle(cornerRadius: 16))
        }
        if let notice = teacher.notice {
            Text(notice).font(.system(size: 16)).foregroundStyle(Color.honeyInk).multilineTextAlignment(.center)
        }
        if case .failed = teacher.phase {
            Button("再试一次", action: connect).buttonStyle(SecondaryButtonStyle())
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("打字问小熊", text: $draft)
                .font(.system(size: 20)).padding(.horizontal, 20).frame(height: 56)
                .background(Color.card, in: Capsule()).overlay(Capsule().stroke(Color.line))
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .onAppear { fieldFocused = true }
            Button("发送", action: sendDraft).buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !teacher.canTalk)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.paper)
    }

    private func sendDraft() {
        guard teacher.canTalk else { return } // keep the text when the connection is down
        teacher.say(draft)
        draft = ""
    }

    private var statusText: String {
        switch teacher.phase {
        case .connecting: "正在叫小熊老师…"
        case .listening: teacher.muted ? "麦克风关着，可以打字" : (teacher.voiceInput ? "我在听，说吧" : "打字和小熊说话吧")
        case .hearing: "听着呢…"
        case .thinking: "让我想一想…"
        case .speaking: "点我可以打断"
        case .ended: "下次见"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        if case .failed = teacher.phase { return .redPen }
        return teacher.phase == .hearing ? .pine : .ink2
    }
}

/// The bear in a ring that breathes while listening, follows the child's voice, spins while thinking
/// and pulses while talking.
struct BearOrb: View {
    let phase: TeacherSession.Phase
    @ObservedObject var level: VoiceLevel
    var size: CGFloat = 200
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(ringColor.opacity(0.14))
                .scaleEffect(scale)
                .animation(.easeOut(duration: 0.12), value: level.value)
            Circle().stroke(ringColor.opacity(0.5), lineWidth: 6)
                .scaleEffect(phase == .speaking && pulse ? 1.08 : 1)
            if phase == .thinking {
                Circle().trim(from: 0, to: 0.25).stroke(Color.honey, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
                    .onDisappear { spin = false }
            }
            BearView(size: size * 0.64)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }

    private var scale: CGFloat {
        switch phase {
        case .hearing: 0.9 + CGFloat(level.value) * 0.35
        case .listening: pulse ? 0.95 : 0.9
        case .speaking: pulse ? 1.05 : 0.95
        default: 0.9
        }
    }

    private var ringColor: Color {
        switch phase {
        case .hearing: .pine
        case .speaking: .honey
        case .failed: .redPen
        default: .ink3
        }
    }
}
