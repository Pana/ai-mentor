import SwiftUI

// The parent's view of each child tablet's reward-time lock, from the tablet's heartbeat (Android tablets report it).
// Same wording as the Android parent app (`ParentLock.kt`).

/// "11/22 15:39" in the family's time zone; empty when the time can't be read.
func lockTime(_ iso: String, zone: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

/// One line about a tablet's lock: a warning when `problem` is set, otherwise that it is working.
func lockMessage(_ lock: LockStatus, zone: String) -> String {
    let name = lock.name.isEmpty ? "孩子的平板" : lock.name
    let at = lockTime(lock.reportedAt, zone: zone)
    switch lock.problem {
    case "off": return "\(name) 的奖励时间锁定已关闭，被锁的动画和游戏现在随时能打开。请在平板上点“家长 → 奖励时间锁定”重新开启。"
    case "paused": return "\(name) 的锁定最近被系统暂停过，那段时间被锁的 App 能打开。请在平板的应用信息里把省电策略改成“无限制”。"
    case "silent": return "\(name) 超过一天没有报告锁定状态（最后一次 \(at)）。平板可能关机或断网，也可能锁定被关掉了。"
    default:
        return "\(name)：锁定正常，锁住 \(lock.lockedApps) 个 App" + (at.isEmpty ? "" : "，\(at) 报告") + (lock.adminActive ? "" : "。没开“防止卸载”")
    }
}

/// Shown above every parent tab while any tablet's lock needs attention.
struct LockAlertBanner: View {
    @EnvironmentObject private var store: HomeworkStore
    var onTap: () -> Void

    var body: some View {
        let problems = store.locks.filter { $0.problem != nil }
        if !problems.isEmpty {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.deviceId) { lock in
                        Text("⚠ " + lockMessage(lock, zone: store.timeZone.identifier)).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                    }
                }
                .foregroundStyle(Color.honeyInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.honeySoft)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The 奖励 tab's section listing every tablet that reports a lock.
struct LockStatusSection: View {
    @EnvironmentObject private var store: HomeworkStore

    var body: some View {
        Section("孩子平板的锁定") {
            if store.locks.isEmpty {
                Text("还没有平板开启锁定。安卓平板可以锁住动画和游戏 App，平时打不开，用奖励时间才放开：在孩子平板上点“家长 → 奖励时间锁定”设置。")
                    .font(.footnote).foregroundStyle(Color.ink3)
            }
            ForEach(store.locks, id: \.deviceId) { lock in
                Text((lock.problem != nil ? "⚠ " : "✓ ") + lockMessage(lock, zone: store.timeZone.identifier))
                    .font(.subheadline).foregroundStyle(lock.problem != nil ? Color.honeyInk : Color.pine)
            }
        }
    }
}
