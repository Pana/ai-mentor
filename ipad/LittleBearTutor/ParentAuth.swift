import LocalAuthentication
import SwiftUI

@MainActor final class ParentAuthenticator: ObservableObject {
    @Published private(set) var unlocked = false
    @Published var message: String?

    func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "请先在 iPad 设置锁屏密码或 Face ID，再进入家长设置。"
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证家长身份后查看和修改家庭学习记录") { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.unlocked = success
                if !success { self.message = error?.localizedDescription ?? "未完成家长验证。" }
            }
        }
    }
    func lock() { unlocked = false }
}

struct ParentSettingsGate: View {
    @StateObject private var auth = ParentAuthenticator()
    var body: some View {
        Group {
            if auth.unlocked { SettingsView(onLock: auth.lock) }
            else VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.system(size: 52)).foregroundStyle(.green)
                Text("家长设置已锁定").font(.title2.bold())
                Text(auth.message ?? "使用 iPad 锁屏密码或 Face ID 进入。").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("验证家长身份") { auth.authenticate() }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        }
        .navigationTitle("家长设置")
        .task { if !auth.unlocked { auth.authenticate() } }
    }
}
