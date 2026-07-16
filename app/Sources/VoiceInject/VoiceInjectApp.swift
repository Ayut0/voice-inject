import AppKit
import SwiftUI

@main
struct VoiceInjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("VoiceInject") {
            MainWindow()
                .environment(model)
                .task {
                    appDelegate.model = model
                    model.startDaemon()
                }
        }
    }
}

/// Owns the app-termination sequence: without this, quitting (⌘Q, Apple
/// event, log out) has no shutdown path at all, so the daemon is never
/// asked to stop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
