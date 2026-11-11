import SwiftUI

@main struct LittleBearTutorApp: App {
    @StateObject private var model: AppModel
    @StateObject private var store: HomeworkStore
    private let legacy: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        // UI tests start from a clean install. Never compiled into Release builds.
        if args.contains("-ui-testing-reset") {
            LocalStore().remove()
            PhotoStore().deleteAll()
            CredentialStore().clear()
            SessionStore().clear()
        }
        // End-to-end tests preconfigure the gateway, since the simulator cannot pass the parent lock.
        if let i = args.firstIndex(of: "-e2e-service"), i + 2 < args.count {
            try? CredentialStore().save(url: args[i + 1], token: args[i + 2], consent: true)
        }
        // Simulator testing: start already connected. -phase1-session <server> <role> <deviceId> <familyId> <token>
        if let i = args.firstIndex(of: "-phase1-session"), i + 5 < args.count,
           let device = UUID(uuidString: args[i + 3]), let family = UUID(uuidString: args[i + 4]) {
            try? SessionStore().save(DeviceSession(server: args[i + 1], deviceId: device, role: args[i + 2], familyId: family, token: args[i + 5]))
        }
        // The pre-phase-1 single-iPad app (tutor, practice, local records) is kept for its UI tests.
        legacy = args.contains("-legacy-ui")
        #else
        legacy = false
        #endif
        _model = StateObject(wrappedValue: AppModel())
        let store = HomeworkStore()
        #if DEBUG
        if args.contains("-ui-testing-reset") { store.wipeLocal() }
        #endif
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            if legacy { ContentView().environmentObject(model) }
            else { RootView().environmentObject(store) }
        }
    }
}
