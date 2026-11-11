import SwiftUI
import UIKit

/// App entry: role choice and pairing until this device is connected, then the parent or child app.
struct RootView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
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
        .task(id: store.session?.deviceId) {
            // Foreground polling stands in for push notifications until the app has an Apple Developer account.
            while !Task.isCancelled {
                if scenePhase == .active { await store.sync() }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.sync() } } }
    }
}

struct OnboardingView: View {
    enum Step { case choose, parent, child }
    @State private var step = Step.choose

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            switch step {
            case .choose: choose
            case .parent: ParentConnectView(back: { step = .choose })
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
                    roleButton("我是家长", detail: "在这台手机上录入作业、批改、设置奖励", icon: "person.fill") { step = .parent }
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
