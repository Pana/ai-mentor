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
        #endif
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}
