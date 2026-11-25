import SwiftUI
import UIKit

/// App entry: role choice and pairing until this device is connected, then the parent or child app.
struct RootView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.scenePhase) private var scenePhase

    /// The sync loop restarts whenever this changes. `scenePhase` read inside an already running task keeps the value it had
    /// when the task began (at cold launch that is not yet `.active`), so the phase has to be part of the task's id.
    private struct SyncLoop: Equatable { var deviceId: UUID?; var active: Bool }

    var body: some View {
        let loop = SyncLoop(deviceId: store.session?.deviceId, active: scenePhase == .active)
        return Group {
            if let session = store.session {
                if session.isParent { ParentApp() } else { ChildApp() }
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .tint(.pine)
        .storeErrors()
        .task(id: loop) {
            // In the foreground: sync, then hold a request open until the server has news (long polling stands in for
            // push notifications until the app has an Apple Developer account). Cancelled when the app leaves the foreground.
            // The store's background photo prefetching (parent phone) follows the same foreground state.
            store.setActive(loop.active)
            guard loop.active, loop.deviceId != nil else { return }
            while !Task.isCancelled {
                await store.sync()
                await store.waitForChanges()
            }
        }
    }
}

struct OnboardingView: View {
    enum Step { case choose, parent, parentSecret, child }
    @State private var step = Step.choose

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            switch step {
            case .choose: choose
            case .parent: ParentAccountView(back: { step = .choose }, useSecret: { step = .parentSecret })
            case .parentSecret: ParentConnectView(back: { step = .parent })
            case .child: ChildPairView(back: { step = .choose })
            }
        }
    }

    private var choose: some View {
        ScrollView {
            VStack(spacing: 28) {
                BearView(size: 110).padding(.top, 40)
                Text("小熊伴学").font(.system(size: 36, weight: .black)).foregroundStyle(Color.ink)
                Text("家长用手机布置和批改作业，孩子用 iPad 完成作业。").font(.title3).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                VStack(spacing: 16) {
                    roleButton("我是家长", detail: "用手机号登录或注册，录入作业、批改、设置奖励", icon: "person.fill") { step = .parent }
                    roleButton("这是孩子的 iPad", detail: "用家长手机上生成的配对码连接", icon: "ipad.landscape") { step = .child }
                }
                .frame(maxWidth: 520)
            }
            .padding(24).frame(maxWidth: .infinity)
        }
    }

    private func roleButton(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.pine).frame(width: 52, height: 52).background(Color.pineSoft, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold()).foregroundStyle(Color.ink)
                    Text(detail).font(.subheadline).foregroundStyle(Color.ink2).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.ink3)
            }
            .padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
private let defaultServer = "http://127.0.0.1:8787"
#else
private let defaultServer = "https://"
#endif

/// Parent sign-in: log in with a phone number and password, or register (a new family, or another parent's family with
/// an invite code). The old parent-secret connection is still one tap away for servers set up before accounts.
struct ParentAccountView: View {
    enum Mode: String, CaseIterable { case login = "登录", register = "注册" }
    @EnvironmentObject private var store: HomeworkStore
    let back: () -> Void
    let useSecret: () -> Void
    @State private var mode = Mode.login
    @State private var server = defaultServer
    @State private var phone = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var name = ""
    @State private var invite = ""
    @State private var busy = false

    private var digits: String { phone.filter(\.isNumber) }
    private var mismatch: Bool { mode == .register && !confirm.isEmpty && confirm != password }
    private var ready: Bool {
        guard digits.count == 11, !password.isEmpty else { return false }
        if mode == .login { return true }
        return password.count >= 8 && password == confirm && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (invite.isEmpty || invite.filter(\.isNumber).count == 8)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录或注册", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section {
                    TextField("服务器地址", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("手机号", text: $phone).keyboardType(.numberPad).textContentType(.telephoneNumber)
                        .onChange(of: phone) { _, value in phone = String(value.filter(\.isNumber).prefix(11)) }
                    SecureField("密码", text: $password).textContentType(mode == .register ? .newPassword : .password)
                    if mode == .register {
                        SecureField("再输一次密码", text: $confirm).textContentType(.newPassword)
                    }
                } footer: {
                    if mismatch { Text("两次输入的密码不一样。").foregroundStyle(.red) }
                    else if mode == .register { Text("密码至少 8 位。") }
                }
                if mode == .register {
                    Section {
                        TextField("你的称呼（如 妈妈）", text: $name)
                        TextField("邀请码（选填）", text: $invite).keyboardType(.numberPad)
                            .onChange(of: invite) { _, value in invite = String(value.filter(\.isNumber).prefix(8)) }
                    } footer: {
                        Text("家里已经有家长注册过：请对方在“设置 → 家长 → 邀请家长”生成 8 位邀请码，填上就和对方在同一个家庭。不填就新建一个家庭。")
                    }
                }
                Section {
                    Button { submit() } label: { HStack { Text(busy ? "请稍候…" : mode.rawValue); if busy { ProgressView() } } }
                        .disabled(busy || !ready)
                        .accessibilityIdentifier("account-submit")
                }
                Section {
                    Button("用家长密钥连接", action: useSecret).font(.footnote)
                } footer: {
                    Text("家长密钥是旧的连接方式（服务器配置里的 PARENT_BOOTSTRAP_TOKEN）。连接后可以在设置里补设手机号登录。")
                }
            }
            .navigationTitle("家长登录")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回", action: back) } }
            .keyboardDoneButton()
        }
    }

    private func submit() {
        busy = true
        let deviceName = UIDevice.current.name
        Task {
            await perform(store) {
                if mode == .login {
                    try await store.login(server: server, phone: digits, password: password, deviceName: deviceName)
                } else {
                    try await store.register(server: server, phone: digits, password: password, name: name, inviteCode: invite, deviceName: deviceName)
                }
            }
            busy = false
        }
    }
}

struct ParentConnectView: View {
    @EnvironmentObject private var store: HomeworkStore
    let back: () -> Void
    @State private var server = defaultServer
    @State private var secret = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("家长密钥", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.oneTimeCode)
                } footer: {
                    Text("家长密钥是服务器配置里的 PARENT_BOOTSTRAP_TOKEN，只在第一次连接时用，换取这台手机自己的登录凭证。")
                }
                Section {
                    Button { connect() } label: { HStack { Text(busy ? "正在连接…" : "连接"); if busy { ProgressView() } } }
                        .disabled(busy || secret.count < 24)
                }
            }
            .navigationTitle("连接家长手机")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回", action: back) } }
            .keyboardDoneButton()
        }
    }

    private func connect() {
        busy = true
        Task {
            await perform(store) { try await store.connectParent(server: server, secret: secret, name: UIDevice.current.name) }
            busy = false
        }
    }
}

struct ChildPairView: View {
    @EnvironmentObject private var store: HomeworkStore
    let back: () -> Void
    @State private var server = defaultServer
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("6 位配对码", text: $code).keyboardType(.numberPad).font(.title2.monospacedDigit())
                        .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                } footer: {
                    Text("在家长手机上打开“作业 → 设置 → 连接孩子的 iPad”，会显示配对码，10 分钟内有效。")
                }
                Section {
                    Button { pair() } label: { HStack { Text(busy ? "正在连接…" : "连接"); if busy { ProgressView() } } }
                        .disabled(busy || code.count != 6)
                }
            }
            .navigationTitle("连接孩子的 iPad")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回", action: back) } }
            .keyboardDoneButton()
        }
    }

    private func pair() {
        busy = true
        Task {
            await perform(store) { try await store.pairChild(server: server, code: code, name: UIDevice.current.name) }
            busy = false
        }
    }
}
