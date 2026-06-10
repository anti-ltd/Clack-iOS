import SwiftUI
import iUXiOS

@main
struct ClackApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Bring up the PushToTalk channel manager as soon as the UI
                // exists — registration is async and we want the system pill
                // ready before the user reaches for the talk button.
                .task { await model.channels.activate() }
        }
    }
}
