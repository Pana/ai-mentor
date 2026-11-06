import SwiftUI

@main struct LittleBearTutorApp: App {
    @StateObject private var model: AppModel

    init() {
        #if DEBUG
        // UI tests start from a clean install. Never compiled into Release builds.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            LocalStore().remove()
            PhotoStore().deleteAll()
            CredentialStore().clear()
        }
        // End-to-end tests preconfigure the gateway, since the simulator cannot pass the parent lock.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-e2e-service"), i + 2 < args.count {
            try? CredentialStore().save(url: args[i + 1], token: args[i + 2], consent: true)
        }
        #endif
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}
