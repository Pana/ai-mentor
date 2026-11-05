import SwiftUI

@main struct LittleBearTutorApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}
