import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Child app (iPad): pick yourself, then 今天 · 全部作业 · 奖励时间.
struct ChildApp: View {
    @EnvironmentObject private var store: HomeworkStore
    @AppStorage("child.current") private var childIdText = ""

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            if let child = store.child(UUID(uuidString: childIdText)) {
                ChildShell(child: child, switchChild: { childIdText = "" })
            } else {
                ProfilePicker(choose: { childIdText = $0.id.uuidString })
            }
        }
    }
}

struct ProfilePicker: View {
    @EnvironmentObject private var store: HomeworkStore
    let choose: (RemoteChild) -> Void
    @State private var settings = false

    var body: some View {
        VStack(spacing: 36) {
            HStack { Spacer(); ParentLockButton { settings = true } }.padding(.horizontal, 32)
            Spacer()
            BearView(size: 120)
            Text(store.children.isEmpty ? "等家长添加孩子" : "今天谁来学习？").font(.system(size: 40, weight: .black)).foregroundStyle(Color.ink)
            if store.children.isEmpty {
                Text("家长在手机上“作业 → 设置”里添加孩子后，这里会出现头像。").font(.title3).foregroundStyle(Color.ink2)
                if store.syncing { ProgressView() }
            } else {
                Text("点一下你的头像").font(.title3).foregroundStyle(Color.ink2)
                HStack(spacing: 28) {
                    ForEach(store.children) { child in
                        let open = store.items(child: child.id).filter { $0.date <= store.today && $0.needsWork }.count
                        Button { choose(child) } label: {
                            VStack(spacing: 14) {
                                Avatar(child: child, size: 110)
                                Text(child.name).font(.system(size: 28, weight: .bold)).foregroundStyle(Color.ink)
                                Text(open == 0 ? "\(child.grade) 年级 · 作业都完成啦" : "\(child.grade) 年级 · 还有 \(open) 项作业").font(.callout).foregroundStyle(Color.ink2)
                            }
                            .frame(width: 230, height: 250).background(Color.card, in: RoundedRectangle(cornerRadius: 32))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            Text("学习记录保存在家里的服务器上").font(.footnote).foregroundStyle(Color.ink3)
        }
        .padding(.vertical, 20)
        .sheet(isPresented: $settings) { IPadSettings() }
        .refreshable { await store.sync() }
    }
}

struct ParentLockButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("家长", systemImage: "lock") }
            .font(.callout).foregroundStyle(Color.ink2).padding(.horizontal, 16).frame(height: 44)
            .background(Color.card, in: Capsule()).overlay(Capsule().stroke(Color.line))
    }
}

enum ChildTab: String, CaseIterable, Identifiable {
    case today = "今天", all = "全部作业", reward = "奖励时间"
    var id: String { rawValue }
}

enum ChildRoute: Hashable { case homework(UUID), submit(UUID) }

struct ChildShell: View {
    @EnvironmentObject private var store: HomeworkStore
    let child: RemoteChild
    let switchChild: () -> Void
    @State private var tab = ChildTab.today
    @State private var path: [ChildRoute] = []
    @State private var settings = false
    @State private var teacher = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                topBar
                Group {
                    switch tab {
                    case .today: TodayView(child: child, open: { path.append(.homework($0)) }, showRewards: { tab = .reward })
                    case .all: AllHomeworkView(child: child, open: { path.append(.homework($0)) })
                    case .reward: RewardView(child: child)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ChildRoute.self) { route in
                switch route {
                case .homework(let id): ChildHomeworkView(id: id, submit: { path.append(.submit(id)) })
                case .submit(let id): SubmitPhotosView(id: id, done: { path = [.homework(id)] })
                }
            }
        }
        .sheet(isPresented: $settings) { IPadSettings() }
        .fullScreenCover(isPresented: $teacher) { TeacherView(child: child).environmentObject(store) }
    }

    private var topBar: some View {
        HStack {
            Button(action: switchChild) {
                HStack(spacing: 10) { Avatar(child: child, size: 40); Text(child.name).font(.system(size: 18, weight: .medium)); Image(systemName: "chevron.down").font(.caption).foregroundStyle(Color.ink3) }
                    .foregroundStyle(Color.ink).padding(.leading, 6).padding(.trailing, 16).frame(height: 52)
                    .background(Color.card, in: Capsule()).overlay(Capsule().stroke(Color.line))
            }
            .accessibilityLabel("换人，现在是\(child.name)")
            Spacer()
            HStack(spacing: 4) {
                ForEach(ChildTab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue).font(.system(size: 19, weight: tab == t ? .bold : .medium)).foregroundStyle(tab == t ? Color.ink : Color.ink2)
                            .padding(.horizontal, 26).frame(height: 50).background(tab == t ? Color.card : .clear, in: Capsule())
                    }
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(5).background(Color(hex: 0xEAE4D8), in: Capsule())
            Spacer()
            Button { teacher = true } label: {
                HStack(spacing: 8) { BearView(size: 34); Text("小熊老师").font(.system(size: 18, weight: .bold)) }
                    .foregroundStyle(Color.ink).padding(.leading, 8).padding(.trailing, 18).frame(height: 52)
                    .background(Color.honeySoft, in: Capsule()).overlay(Capsule().stroke(Color.honey.opacity(0.5)))
            }
            .accessibilityLabel("和小熊老师语音聊天")
            ParentLockButton { settings = true }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }
}

// MARK: - 今天

struct TodayView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    let child: RemoteChild
    let open: (UUID) -> Void
    let showRewards: () -> Void

    private var homework: [RemoteHomework] {
        store.items(child: child.id).filter { !$0.isRoutine && ($0.date == store.today || ($0.date < store.today && $0.needsWork)) }
            .sorted { (rank($0), $0.date, $0.subject) < (rank($1), $1.date, $1.subject) }
    }
    private var routines: [RemoteHomework] { store.items(child: child.id).filter { $0.isRoutine && $0.date == store.today }.sorted { $0.content < $1.content } }
    private func rank(_ item: RemoteHomework) -> Int { switch item.status { case "NEEDS_CORRECTION": 0; case "NOT_STARTED": 1; case "SUBMITTED": 2; default: 3 } }

    var body: some View {
        ScrollView {
            let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            layout {
                main.frame(maxWidth: .infinity, alignment: .top)
                aside.frame(width: sizeClass == .compact ? nil : 340)
            }
            .padding(.horizontal, 28).padding(.bottom, 32)
        }
        .refreshable { await store.sync() }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 18) {
            let done = homework.filter { !$0.needsWork }.count
            HStack(spacing: 18) {
                BearView(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(child.name)，\(greeting)！").font(.system(size: 32, weight: .black))
                    Text(homework.isEmpty ? "今天还没有作业。" : done == homework.count ? "今天的作业都交啦，真棒！" : "今天有 \(homework.count) 项作业，交了 \(done) 项。").font(.title3).foregroundStyle(Color.ink2)
                }
            }
            if !homework.isEmpty {
                HStack(spacing: 6) { ForEach(homework.indices, id: \.self) { i in Capsule().fill(i < done ? Color.pine : Color.line).frame(height: 10) } }
                    .accessibilityLabel("完成 \(done) 项，共 \(homework.count) 项")
            }
            let firstOpen = homework.first(where: \.needsWork)?.id
            ForEach(homework) { item in
                TodayCard(item: item, highlighted: item.id == firstOpen, pending: store.pending(item.id) != nil) { open(item.id) }
            }
            SyncFootnote()
        }
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !routines.isEmpty {
                Card {
                    HStack { Text("每天坚持").font(.title3.bold()); Spacer(); Text("\(routines.filter { !$0.needsWork }.count) / \(routines.count) 做完").foregroundStyle(Color.ink3) }
                    ForEach(routines) { item in
                        HStack(spacing: 12) {
                            if item.needsWork { Circle().stroke(Color(hex: 0xD5CCBC), lineWidth: 2).frame(width: 30, height: 30) }
                            else { Image(systemName: "checkmark").font(.system(size: 15, weight: .black)).foregroundStyle(.white).frame(width: 30, height: 30).background(Color.pine, in: Circle()) }
                            VStack(alignment: .leading) {
                                Text(item.content).font(.headline).foregroundStyle(item.needsWork ? Color.ink : Color.ink2)
                                Text(modeLabel(item)).font(.caption).foregroundStyle(Color.ink3)
                            }
                            Spacer()
                            if item.needsWork || item.status == "NEEDS_CORRECTION" { Button("开始") { open(item.id) }.buttonStyle(SecondaryButtonStyle(height: 44)) }
                        }
                    }
                }
            }
            if let latest = store.items(child: child.id).filter({ $0.latestReview != nil && $0.date >= Day.add(store.today, -2) }).max(by: { ($0.latestReview?.reviewedAt ?? "") < ($1.latestReview?.reviewedAt ?? "") }),
               let review = latest.latestReview {
                Card(background: .honeySoft) {
                    Text("家长批改好了").font(.subheadline.bold()).foregroundStyle(Color.honeyInk)
                    Text("\(SubjectStyle.label(latest.subject)) · \(GradeStyle.label(review.grade))").font(.title3.bold())
                    Text(latest.content).lineLimit(1).foregroundStyle(Color.ink2)
                    Button("去看看") { open(latest.id) }.buttonStyle(PrimaryButtonStyle(color: .ink, height: 48)).frame(maxWidth: .infinity)
                }
            }
            Button(action: showRewards) {
                HStack(spacing: 12) {
                    Image(systemName: "play.rectangle").font(.title2).foregroundStyle(Color.honey)
                    VStack(alignment: .leading) { Text("我的奖励时间").font(.caption).foregroundStyle(Color(hex: 0xD9D2C5)); Text("已攒 \(store.rewards[child.id]?.balance ?? 0) 分钟").font(.title3.bold()) }
                    Spacer(); Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white).padding(.horizontal, 20).frame(minHeight: 64).background(Color.ink, in: RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.plain)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
    }
}

struct TodayCard: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    let highlighted: Bool
    let pending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SubjectTag(subject: item.subject)
                        StatusChip(item: item, pending: pending)
                        Chip(text: modeLabel(item))
                        if item.date < store.today { Chip(text: "\(Day.short(item.date)) 的作业", fg: Color(hex: 0xA04A06), bg: Color(hex: 0xFDEBDC)) }
                    }
                    Text(item.content).font(.system(size: 22, weight: .bold)).foregroundStyle(item.needsWork ? Color.ink : Color.ink2).multilineTextAlignment(.leading).lineLimit(3)
                    if item.status == "NEEDS_CORRECTION", let comment = item.latestReview?.comment, !comment.isEmpty {
                        Text("家长说：\(comment)").font(.system(size: 17)).foregroundStyle(Color.honeyInk).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.honeySoft, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Spacer(minLength: 0)
                if item.needsWork {
                    Text(item.status == "NEEDS_CORRECTION" || highlighted ? "继续" : "开始").font(.system(size: 20, weight: .bold))
                        .foregroundStyle(highlighted ? .white : Color.pine).padding(.horizontal, 28).frame(height: 58)
                        .background(highlighted ? Color.pine : Color.card, in: Capsule()).overlay(Capsule().stroke(Color.pine, lineWidth: highlighted ? 0 : 2))
                }
            }
            .padding(22).background(Color.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(highlighted ? Color.pine : Color.clear, lineWidth: 2))
            .opacity(item.needsWork ? 1 : 0.85)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 全部作业 (grouped by date)

struct AllHomeworkView: View {
    @EnvironmentObject private var store: HomeworkStore
    let child: RemoteChild
    let open: (UUID) -> Void
    enum Filter: String, CaseIterable, Identifiable { case all = "全部", open = "还没做完", waiting = "等家长批改", marked = "有批注"; var id: String { rawValue } }
    @State private var filter = Filter.all

    private func matches(_ item: RemoteHomework) -> Bool {
        switch filter {
        case .all: true
        case .open: item.needsWork
        case .waiting: item.awaitingReview
        case .marked: item.latestReview.map { !$0.comment.isEmpty || !$0.annotationFileIds.isEmpty } ?? false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(Filter.allCases) { f in
                        let count = f == .all ? nil : store.items(child: child.id).filter { item in Self.match(f, item) }.count
                        Button { filter = f } label: {
                            Text(count.map { "\(f.rawValue) \($0)" } ?? f.rawValue).font(.system(size: 17, weight: filter == f ? .bold : .regular))
                                .foregroundStyle(filter == f ? .white : Color.ink).padding(.horizontal, 20).frame(height: 44)
                                .background(filter == f ? Color.ink : Color.card, in: Capsule()).overlay(Capsule().stroke(filter == f ? .clear : Color.line))
                        }
                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                    }
                }
                let groups = store.grouped(child: child.id, filter: matches).filter { $0.day <= Day.add(store.today, 7) }
                if groups.isEmpty { Text("这里还没有作业。").font(.title3).foregroundStyle(Color.ink2).padding(.top, 40).frame(maxWidth: .infinity) }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Day.label(group.day, today: store.today)).font(.system(size: 20, weight: .bold))
                        VStack(spacing: 0) {
                            ForEach(group.items) { item in
                                Button { open(item.id) } label: {
                                    HStack(spacing: 16) {
                                        SubjectTag(subject: item.subject).frame(width: 64)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.content).font(.system(size: 19, weight: .medium)).foregroundStyle(Color.ink).lineLimit(2).multilineTextAlignment(.leading)
                                            if let comment = item.latestReview?.comment, !comment.isEmpty { Text("家长的批注：\(comment)").font(.subheadline).foregroundStyle(Color.honeyInk).lineLimit(1) }
                                        }
                                        Spacer()
                                        Text(item.isOffline ? "本子上写" : "在 iPad 上做").font(.subheadline).foregroundStyle(Color.ink3)
                                        StatusChip(item: item, pending: store.pending(item.id) != nil).frame(width: 108)
                                        Image(systemName: "chevron.right").foregroundStyle(Color(hex: 0xB3A998))
                                    }
                                    .padding(.horizontal, 22).frame(minHeight: 68).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if item.id != group.items.last?.id { Divider().padding(.leading, 22) }
                            }
                        }
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 22))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 32)
        }
        .refreshable { await store.sync() }
    }

    private static func match(_ f: Filter, _ item: RemoteHomework) -> Bool {
        switch f {
        case .all: true
        case .open: item.needsWork
        case .waiting: item.awaitingReview
        case .marked: item.latestReview.map { !$0.comment.isEmpty || !$0.annotationFileIds.isEmpty } ?? false
        }
    }
}

// MARK: - One homework item: do it, wait for the parent, or read the feedback

struct ChildHomeworkView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let item = store.homework[id] {
                HStack(spacing: 14) {
                    Button { dismiss() } label: { Label("返回", systemImage: "chevron.left").font(.system(size: 18, weight: .medium)) }
                        .foregroundStyle(Color.ink).padding(.horizontal, 16).frame(height: 48).background(Color.card, in: Capsule())
                    SubjectTag(subject: item.subject)
                    StatusChip(item: item, pending: store.pending(item.id) != nil)
                    Chip(text: modeLabel(item), bg: .card)
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                Group {
                    if store.pending(item.id) != nil { WaitingView(item: item, uploading: true) }
                    else if item.status == "REVIEWED" || item.status == "NEEDS_CORRECTION" { FeedbackView(item: item, redo: item.status == "NEEDS_CORRECTION" ? redo(item) : nil) }
                    else if item.status == "SUBMITTED" { WaitingView(item: item, uploading: false) }
                    else { work(item) }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            } else {
                ContentUnavailableView("这项作业已经删除了", systemImage: "trash", description: Text("可能是家长改了作业。"))
                Button("返回") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .background(Color.paper)
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func work(_ item: RemoteHomework) -> some View {
        if item.isOffline { OfflineTaskView(item: item, submit: submit) }
        else if item.isTimer { TimerTaskView(item: item) }
        else { RecordingTaskView(item: item) }
    }

    private func redo(_ item: RemoteHomework) -> () -> Void {
        if item.isOffline { return submit }
        return { /* online corrections are redone in place */ }
    }
}

/// Homework content as numbered lines, plus the parent's note and the teacher's pictures.
struct HomeworkContent: View {
    let item: RemoteHomework
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("作业 · \(Day.short(item.date))\(item.dueDate.map { "，\(Day.short($0)) 交" } ?? "")").font(.subheadline.bold()).foregroundStyle(Color.ink3)
            let lines = item.content.split(whereSeparator: { $0 == "\n" || $0 == "；" || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if lines.count > 1 { Text("\(i + 1).").foregroundStyle(Color.ink3) }
                        Text(line)
                    }.font(.system(size: 22, weight: .medium))
                }
            }
            if item.status == "NEEDS_CORRECTION", let review = item.latestReview, !review.comment.isEmpty {
                Text("家长说：\(review.comment)").font(.system(size: 18)).foregroundStyle(Color.honeyInk).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.honeySoft, in: RoundedRectangle(cornerRadius: 14))
            }
            if !item.attachmentIds.isEmpty {
                TabView {
                    ForEach(item.attachmentIds, id: \.self) { RemoteImage(fileId: $0).padding(8) }
                }
                .tabViewStyle(.page(indexDisplayMode: item.attachmentIds.count > 1 ? .always : .never))
                .frame(minHeight: 280).background(Color.cardSoft, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}

struct OfflineTaskView: View {
    let item: RemoteHomework
    let submit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView { HomeworkContent(item: item).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                Button(action: submit) { Label(item.status == "NEEDS_CORRECTION" ? "订正好了，拍照再交" : "写完了，拍照交作业", systemImage: "camera") }
                    .buttonStyle(PrimaryButtonStyle(height: 64))
            }
        }
        .padding(28).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
    }
}

struct WaitingView: View {
    let item: RemoteHomework
    let uploading: Bool
    var body: some View {
        VStack(spacing: 20) {
            BearView(size: 96)
            Text(uploading ? "交上了，等网络好了就发给家长" : (item.isTimer ? "打卡完成！" : "交上了，等家长批改")).font(.system(size: 30, weight: .black))
            Text(item.content).font(.title3).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
            if let latest = item.latest, item.isOffline {
                HStack { ForEach(latest.fileIds, id: \.self) { RemoteImage(fileId: $0, contentMode: .fill).frame(width: 120, height: 160).clipShape(RoundedRectangle(cornerRadius: 12)) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
    }
}

// MARK: - Feedback

struct FeedbackView: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    let redo: (() -> Void)?
    @State private var page = 0

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            let submission = item.submissions.last(where: { $0.review != nil }) ?? item.latest
            Group {
                if let submission, item.isOffline, !submission.fileIds.isEmpty {
                    TabView(selection: $page) {
                        ForEach(Array(submission.fileIds.enumerated()), id: \.offset) { i, file in AnnotatedPage(photo: file, overlay: overlayFile(submission, i)).padding(16).tag(i) }
                    }
                    .tabViewStyle(.page(indexDisplayMode: submission.fileIds.count > 1 ? .always : .never))
                } else if item.isRecording, let audio = submission?.fileIds.first {
                    VStack(spacing: 16) { BearView(size: 90); Text(item.content).font(.title2.bold()); AudioPlayerButton(fileId: audio) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) { BearView(size: 90); Text(item.content).font(.title2.bold()); if let s = submission?.durationSeconds { Text("坚持了 \(s / 60) 分钟").font(.title3).foregroundStyle(Color.ink2) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xEDE8DD), in: RoundedRectangle(cornerRadius: 28))

            VStack(alignment: .leading, spacing: 16) {
                if let review = item.latestReview {
                    Card {
                        HStack(spacing: 16) {
                            GradeBadge(grade: review.grade, size: 72)
                            VStack(alignment: .leading) {
                                Text("家长的评分").font(.subheadline).foregroundStyle(Color.ink3)
                                Text(review.requireCorrection ? "订正好再交一次" : "批改完成").font(.title3.bold())
                            }
                        }
                        if !review.comment.isEmpty { Text(review.comment).font(.system(size: 18)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.cardSoft, in: RoundedRectangle(cornerRadius: 14)) }
                    }
                }
                let earned = (store.rewards[item.childId]?.entries ?? []).filter { $0.refId.hasPrefix(item.id.uuidString.lowercased()) && $0.minutes > 0 }
                if !earned.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这项作业的奖励").font(.subheadline).foregroundStyle(Color(hex: 0xD9D2C5))
                        ForEach(earned) { e in HStack { Text(["ON_TIME": "按时交", "GRADE": "评分", "CHECKIN": "打卡"][e.reason] ?? "奖励"); Spacer(); Text("+\(e.minutes) 分钟").bold().foregroundStyle(Color.honey) } }
                    }
                    .font(.system(size: 17)).foregroundStyle(.white).padding(20).background(Color.ink, in: RoundedRectangle(cornerRadius: 24))
                }
                Spacer()
                if let redo, item.isOffline {
                    Button(action: redo) { Label("订正好了，拍照再交", systemImage: "camera") }.buttonStyle(PrimaryButtonStyle(height: 64)).frame(maxWidth: .infinity)
                } else if item.status == "NEEDS_CORRECTION" {
                    if item.isTimer { TimerTaskView(item: item).frame(height: 300) } else { RecordingTaskView(item: item).frame(height: 300) }
                }
            }
            .frame(width: 380)
        }
    }
}

// MARK: - Photo submission (several pages)

struct SubmitPhotosView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let done: () -> Void
    @State private var pages: [Data] = []
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: { Label("回到作业", systemImage: "chevron.left").font(.system(size: 18, weight: .medium)) }
                    .foregroundStyle(Color.ink).padding(.horizontal, 16).frame(height: 48).background(Color.card, in: Capsule())
                Text("拍照交作业").font(.system(size: 24, weight: .black))
                if let item = store.homework[id] { SubjectTag(subject: item.subject); Text(item.content).lineLimit(1).foregroundStyle(Color.ink2) }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    if pages.isEmpty {
                        Spacer()
                        Image(systemName: "doc.viewfinder").font(.system(size: 80)).foregroundStyle(Color.ink3)
                        Text("把写好的这一页放平，拍完整就行").font(.title2).foregroundStyle(Color.ink2)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { i, data in
                                    ZStack(alignment: .topTrailing) {
                                        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(height: 260).frame(maxWidth: .infinity).background(Color(hex: 0xEDE8DD)).clipShape(RoundedRectangle(cornerRadius: 14)) }
                                        Button { pages.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white, .black.opacity(0.6)) }
                                            .padding(8).accessibilityLabel("删除第 \(i + 1) 页")
                                        Text("第 \(i + 1) 页").font(.subheadline.bold()).padding(.horizontal, 10).padding(.vertical, 4).background(.white, in: Capsule())
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
                                    }
                                }
                            }
                        }
                    }
                    if pages.count < 6 {
                        PhotoSourceButtons(cameraTitle: pages.isEmpty ? "拍第 1 页" : "再拍一页") { add($0) }.controlSize(.large)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))

                VStack(alignment: .leading, spacing: 16) {
                    Text(pages.isEmpty ? "还没拍" : "已经拍了 \(pages.count) 页").font(.title3.bold())
                    Text("最多 6 页").foregroundStyle(Color.ink3)
                    if let dark = pages.firstIndex(where: { Self.isDark($0) }) {
                        HStack(alignment: .top, spacing: 12) {
                            BearView(size: 40)
                            Text("第 \(dark + 1) 页有点暗，靠近台灯再拍一次会更清楚。").font(.system(size: 16))
                        }
                        .padding(14).background(Color.honeySoft, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Spacer()
                    Button { send() } label: { HStack { Text(sending ? "正在交…" : "交给家长批改"); if sending { ProgressView().tint(.white) } } }
                        .buttonStyle(PrimaryButtonStyle(height: 64)).frame(maxWidth: .infinity).disabled(pages.isEmpty || sending)
                }
                .padding(22).frame(width: 340).frame(maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .background(Color.paper)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func add(_ data: Data) {
        guard let image = UIImage(data: data), let jpeg = PhotoStore.gatewayJPEG(image) else { return }
        pages.append(jpeg)
    }

    private func send() {
        guard let item = store.homework[id] else { return }
        sending = true
        Task { await store.submit(item, pages: pages); sending = false; done() }
    }

    /// Average brightness of a small thumbnail; very dark photos are hard for a parent to read.
    static func isDark(_ data: Data) -> Bool {
        guard let image = UIImage(data: data)?.cgImage else { return false }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) < 70
    }
}

// MARK: - Online: timer

struct TimerTaskView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.scenePhase) private var scenePhase
    let item: RemoteHomework
    @State private var elapsed = 0
    @State private var running = false
    @State private var sending = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var goal: Int { max(1, item.durationMinutes ?? 5) * 60 }
    private var key: String { "timer.\(item.id.uuidString)" }

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 24) {
                Text(item.content).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.ink2)
                ZStack {
                    Circle().stroke(Color.chip, lineWidth: 22)
                    Circle().trim(from: 0, to: min(1, Double(elapsed) / Double(goal))).stroke(Color.pine, style: StrokeStyle(lineWidth: 22, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 4) {
                        Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60)).font(.system(size: 60, weight: .black).monospacedDigit())
                        Text(elapsed >= goal ? "时间到啦！" : "还差 \((goal - elapsed) / 60) 分 \((goal - elapsed) % 60) 秒").font(.title3).foregroundStyle(Color.ink2)
                    }
                }
                .frame(width: 280, height: 280)
                .accessibilityElement(children: .combine)
                HStack(spacing: 16) {
                    Button { running.toggle() } label: { Label(running ? "暂停" : (elapsed == 0 ? "开始" : "继续"), systemImage: running ? "pause.fill" : "play.fill") }
                        .buttonStyle(SecondaryButtonStyle(height: 60))
                    Button { finish() } label: { Text(elapsed >= goal ? (sending ? "正在打卡…" : "完成打卡") : "满 \(goal / 60) 分钟就能打卡") }
                        .buttonStyle(PrimaryButtonStyle(color: elapsed >= goal ? .pine : Color(hex: 0x8FB5A6), height: 60)).disabled(elapsed < goal || sending)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
        }
        .onReceive(tick) { _ in if running && scenePhase == .active { elapsed += 1; if elapsed % 10 == 0 { save() } } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { running = false; save() } }
        .onAppear { elapsed = UserDefaults.standard.integer(forKey: key) }
        .onDisappear { running = false; save() }
    }

    private func save() { UserDefaults.standard.set(elapsed, forKey: key) }

    private func finish() {
        sending = true
        Task {
            await store.submit(item, durationSeconds: elapsed)
            UserDefaults.standard.removeObject(forKey: key)
            sending = false
        }
    }
}

// MARK: - Online: recording (reading aloud, recitation)

@MainActor final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recording = false
    @Published var seconds = 0
    @Published var file: URL?
    @Published var denied = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else { denied = true; return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        guard recorder?.record() == true else { return }
        file = nil; seconds = 0; recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.seconds += 1 } }
    }

    func stop() {
        timer?.invalidate()
        guard let recorder else { return }
        recorder.stop()
        file = recorder.url
        recording = false
        self.recorder = nil
    }
}

struct RecordingTaskView: View {
    @EnvironmentObject private var store: HomeworkStore
    let item: RemoteHomework
    @StateObject private var recorder = Recorder()
    @StateObject private var playback = AudioPlayback()
    @State private var sending = false

    var body: some View {
        VStack(spacing: 22) {
            Text(item.content).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            if recorder.recording {
                HStack(spacing: 8) { Circle().fill(Color(hex: 0xD9572B)).frame(width: 12, height: 12); Text("正在录音 \(recorder.seconds / 60):\(String(format: "%02d", recorder.seconds % 60))") }
                    .font(.title3).foregroundStyle(Color(hex: 0xA04A06)).padding(.horizontal, 18).frame(height: 44).background(Color(hex: 0xFDEBDC), in: Capsule())
            } else if recorder.file != nil {
                Text("录好了，可以先听一遍").font(.title3).foregroundStyle(Color.ink2)
            } else {
                Text("准备好就点“开始录音”，大声读出来").font(.title3).foregroundStyle(Color.ink2)
            }
            if recorder.denied { Text("需要允许使用麦克风：请家长到 设置 → 小熊伴学 打开麦克风。").foregroundStyle(Color(hex: 0xA04A06)) }
            HStack(spacing: 16) {
                if recorder.recording {
                    Button { recorder.stop() } label: { Label("录好了", systemImage: "stop.fill") }.buttonStyle(PrimaryButtonStyle(color: Color(hex: 0xD9572B), height: 60))
                } else {
                    Button { Task { playback.stop(); await recorder.start() } } label: { Label(recorder.file == nil ? "开始录音" : "重新录", systemImage: "mic.fill") }
                        .buttonStyle(SecondaryButtonStyle(height: 60))
                    if let file = recorder.file, let data = try? Data(contentsOf: file) {
                        Button { playback.toggle(data) } label: { Label(playback.playing ? "停止" : "听一遍", systemImage: playback.playing ? "stop.fill" : "play.fill") }
                            .buttonStyle(SecondaryButtonStyle(height: 60))
                        Button { send(data) } label: { Text(sending ? "正在交…" : "交给家长听") }.buttonStyle(PrimaryButtonStyle(height: 60)).disabled(sending)
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
        .onDisappear { if recorder.recording { recorder.stop() } }
    }

    private func send(_ data: Data) {
        sending = true
        Task { await store.submit(item, audio: data); sending = false }
    }
}

// MARK: - 奖励时间

struct RewardView: View {
    @EnvironmentObject private var store: HomeworkStore
    let child: RemoteChild
    @AppStorage("reward.endsAt") private var endsAt: Double = 0
    @State private var now = Date()
    @State private var busy = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var openToday: Int { store.items(child: child.id).filter { $0.date == store.today && $0.needsWork }.count }

    var body: some View {
        let summary = store.rewards[child.id]
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                Text("已经攒了").font(.title3).foregroundStyle(Color(hex: 0xD9D2C5))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(summary?.balance ?? 0)").font(.system(size: 88, weight: .black)).foregroundStyle(Color.honey)
                    Text("分钟").font(.title.bold())
                }
                Text("今天最多能用 \(store.rules.dailyCap) 分钟，已用 \(summary?.usedToday ?? 0) 分钟").foregroundStyle(Color(hex: 0xD9D2C5))
                Divider().background(Color(hex: 0x3D3832))
                Text("最近怎么攒到的").font(.headline).foregroundStyle(Color(hex: 0xD9D2C5))
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach((summary?.entries ?? []).prefix(12)) { e in
                            HStack { Text(rewardReason(e, store: store)).lineLimit(1); Spacer(); Text(e.minutes > 0 ? "+\(e.minutes)" : "\(e.minutes)").bold().foregroundStyle(e.minutes > 0 ? Color.honey : Color(hex: 0xD9D2C5)) }
                        }
                    }
                }
            }
            .font(.system(size: 17)).foregroundStyle(.white).padding(28).frame(width: 400).frame(maxHeight: .infinity).background(Color.ink, in: RoundedRectangle(cornerRadius: 28))

            VStack(spacing: 16) {
                if endsAt > now.timeIntervalSince1970 {
                    let left = Int(endsAt - now.timeIntervalSince1970)
                    VStack(spacing: 16) {
                        Text("奖励时间进行中").font(.title.bold())
                        Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 80, weight: .black).monospacedDigit()).foregroundStyle(Color.pine)
                        Text("时间到了要放下 iPad 休息哦。").foregroundStyle(Color.ink2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.card, in: RoundedRectangle(cornerRadius: 28))
                } else {
                    if store.rules.requireAllSubmitted && openToday > 0 {
                        Label("今天还有 \(openToday) 项作业没交，全部交完就能用奖励时间", systemImage: "lock").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(hex: 0xA04A06)).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xFDEBDC), in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        Label("可以使用时段：\(store.rules.windowStart)–\(store.rules.windowEnd)", systemImage: "clock").foregroundStyle(Color.ink2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card(padding: 28) {
                        HStack(spacing: 16) {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 40)).foregroundStyle(Color(hex: 0x1F55B0))
                            VStack(alignment: .leading) { Text("看动画、玩游戏").font(.system(size: 28, weight: .black)); Text("用攒到的时间，选好多久").foregroundStyle(Color.ink2) }
                        }
                        HStack(spacing: 12) {
                            ForEach([5, 10, 15], id: \.self) { minutes in
                                Button("\(minutes) 分钟") { start(minutes) }.buttonStyle(SecondaryButtonStyle(height: 60)).frame(maxWidth: .infinity)
                                    .disabled(busy || (summary?.balance ?? 0) < minutes)
                            }
                        }
                    }
                    Spacer()
                    Text("时间到了，动画和游戏会自动锁上。（需要家长在 iPad 上开启“屏幕使用时间”授权后才会真正锁定。）").font(.footnote).foregroundStyle(Color.ink3).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
        .onReceive(tick) { now = $0 }
    }

    private func start(_ minutes: Int) {
        busy = true
        Task {
            await perform(store) {
                let session = try await store.startReward(child: child.id, minutes: minutes)
                let end = ISO8601DateFormatter.fractional.date(from: session.endsAt) ?? Date().addingTimeInterval(Double(minutes) * 60)
                endsAt = end.timeIntervalSince1970
                RewardUnlock.shared.unlock(until: end)
            }
            busy = false
        }
    }
}

/// Where Screen Time shielding plugs in. Needs the Family Controls entitlement (paid Apple Developer Program),
/// `.child` authorization on the iPad, and a DeviceActivity monitor extension to re-lock when time is up.
@MainActor final class RewardUnlock {
    static let shared = RewardUnlock()
    var isAvailable: Bool { false }
    func unlock(until: Date) { /* ManagedSettingsStore: clear shields for the chosen apps; DeviceActivityCenter: schedule re-lock. */ }
}

// MARK: - iPad settings (parent only)

struct IPadSettings: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = ParentAuthenticator()
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Group {
                if auth.unlocked {
                    Form {
                        Section("这台 iPad") {
                            LabeledContent("服务器", value: store.session?.server ?? "")
                            LabeledContent("孩子", value: store.children.map(\.name).joined(separator: "、"))
                            Button("立即同步") { Task { await store.sync() } }
                        }
                        Section {
                            LabeledContent("奖励时间锁定", value: RewardUnlock.shared.isAvailable ? "已开启" : "未开启")
                        } footer: { Text("锁定动画和游戏 App 需要“屏幕使用时间”授权，加入付费 Apple 开发者计划后开放。孩子的 iPad 要登录孩子自己的 Apple ID，并在家长的家庭共享里。") }
                        Section { Button("断开这台 iPad", role: .destructive) { confirmingSignOut = true } }
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.shield").font(.system(size: 52)).foregroundStyle(Color.pine)
                        Text("家长设置").font(.title2.bold())
                        Text(auth.message ?? "用 iPad 锁屏密码或面容验证家长身份。").foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                        Button("验证家长身份") { auth.authenticate() }.buttonStyle(.borderedProminent)
                    }.padding(40)
                }
            }
            .navigationTitle("家长设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if !auth.unlocked { auth.authenticate() } }
            .confirmationDialog("断开后需要家长重新生成配对码。", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("断开", role: .destructive) { store.signOut(); dismiss() }
            }
        }
    }
}
