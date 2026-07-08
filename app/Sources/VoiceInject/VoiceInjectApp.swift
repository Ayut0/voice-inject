import SwiftUI

@main
struct VoiceInjectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("VoiceInject") {
            MainWindow()
                .environment(model)
                .task { model.startDaemon() }
        }
    }
}
