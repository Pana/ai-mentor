import SwiftUI

// MARK: - Settings: the family's parents and this phone's account

/// Settings sections for the family's parents (list, invite, remove) and the account signed in on this phone.
struct FamilyParentsSection: View {
    @EnvironmentObject private var store: HomeworkStore
    @State private var parents: FamilyParents?
    @State private var invite: InviteCode?
    @State private var removing: FamilyParent?

    var body: some View {
        Section {
            ForEach(parents?.parents ?? []) { parent in
                HStack {
                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.pine)
                    VStack(alignment: .leading) {
                        Text(parent.self_ ? "\(parent.name)（我）" : parent.name).foregroundStyle(Color.ink)
                        Text(parent.phone).font(.caption).foregroundStyle(Color.ink3)
                    }
                }
                .swipeActions { if !parent.self_ { Button("移出", role: .destructive) { removing = parent } } }
            }
            if let count = parents?.unboundDevices, count > 0 {
                Text("另有 \(count) 台家长手机用家长密钥连接，没有登录账号。").font(.footnote).foregroundStyle(Color.ink2)
            }
            if let invite {
                VStack(spacing: 6) {
                    Text(Self.spaced(invite.code)).font(.system(size: 36, weight: .black, design: .monospaced)).kerning(3)
                    Text("24 小时内有效，只能用一次").font(.footnote).foregroundStyle(Color.ink2)
                    ShareLink(item: shareText(invite.code)) { Label("发给家人", systemImage: "square.and.arrow.up") }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Button { Task { await perform(store) { invite = try await store.inviteCode() } } } label: {
                Label(invite == nil ? "邀请家长" : "重新生成邀请码", systemImage: "person.badge.plus")
            }
        } header: { Text("家长") } footer: {
            Text("另一位家长用手机号注册时填上邀请码，就能和你一起管理孩子的作业。")
        }
        .task { await reload() }
        .alert("把\(removing?.name ?? "")移出家庭？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移出", role: .destructive) {
                if let parent = removing { Task { await perform(store) { try await store.removeParent(parent.id); await reload() } } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("对方的手机会退出登录，账号会被删除。孩子和作业不受影响。") }
    }

    private func reload() async { parents = try? await store.parents() }

    private func shareText(_ code: String) -> String {
        "我在用小熊伴学管孩子的作业。注册时填邀请码 \(code)（24 小时内有效）就能加入我们家。服务器：\(store.session?.server ?? "")"
    }

    static func spaced(_ code: String) -> String { code.count == 8 ? "\(code.prefix(4)) \(code.suffix(4))" : code }
}

struct AccountSection: View {
    @EnvironmentObject private var store: HomeworkStore
    @State private var binding = false
    @State private var changingPassword = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        Section {
            if let account = store.account {
                LabeledContent("手机号", value: account.phone)
                Button { newName = account.name; renaming = true } label: {
                    LabeledContent("称呼") { Text(account.name).foregroundStyle(Color.ink2) }.foregroundStyle(Color.ink)
                }
                Button("修改密码") { changingPassword = true }
            } else {
                Button("设置手机号登录") { binding = true }
            }
        } header: { Text("我的账号") } footer: {
            if store.account == nil {
                Text("这台手机是用家长密钥连接的。设置手机号和密码后，换手机时直接登录。")
            }
        }
        .task { try? await store.refreshMe() }
        .sheet(isPresented: $binding) { BindAccountView() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .alert("修改称呼", isPresented: $renaming) {
            TextField("称呼", text: $newName)
            Button("保存") { Task { await perform(store) { try await store.renameAccount(newName) } } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) {}
        }
    }
}

/// A phone connected with the parent secret sets up a phone number and password for its family.
struct BindAccountView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("手机号", text: $phone).keyboardType(.numberPad).textContentType(.telephoneNumber)
                        .onChange(of: phone) { _, value in phone = String(value.filter(\.isNumber).prefix(11)) }
                    SecureField("密码", text: $password).textContentType(.newPassword)
                    SecureField("再输一次密码", text: $confirm).textContentType(.newPassword)
                    TextField("你的称呼（如 妈妈）", text: $name)
                } footer: {
                    if !confirm.isEmpty && confirm != password { Text("两次输入的密码不一样。").foregroundStyle(.red) }
                    else { Text("密码至少 8 位。这台手机和家里的数据都不变。") }
                }
            }
            .navigationTitle("设置手机号登录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        busy = true
                        Task { await perform(store) { try await store.bindAccount(phone: phone, password: password, name: name); dismiss() }; busy = false }
                    }
                    .disabled(busy || phone.count != 11 || password.count < 8 || password != confirm || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .keyboardDoneButton()
        }
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject private var store: HomeworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("原密码", text: $old).textContentType(.password)
                    SecureField("新密码", text: $new).textContentType(.newPassword)
                    SecureField("再输一次新密码", text: $confirm).textContentType(.newPassword)
                } footer: {
                    if !confirm.isEmpty && confirm != new { Text("两次输入的密码不一样。").foregroundStyle(.red) }
                    else { Text("新密码至少 8 位。改完后，用这个账号登录的其他手机要重新登录。") }
                }
            }
            .navigationTitle("修改密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        busy = true
                        Task { await perform(store) { try await store.changePassword(old: old, new: new); dismiss() }; busy = false }
                    }
                    .disabled(busy || old.isEmpty || new.count < 8 || new != confirm)
                }
            }
            .keyboardDoneButton()
        }
    }
}
