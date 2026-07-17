import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            TabView {
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock") }
                // Issue #32 adds Setup here.
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.daemonStatus {
        case .running:
            statusRow("Daemon running — hold ⌥Space to dictate", color: .green,
                       buttonTitle: "Stop Daemon") { model.stopDaemon() }
        case .starting:
            statusRow("Starting daemon…", color: .orange)
        case .restarting:
            statusRow("Daemon stopped unexpectedly — restarting…", color: .orange)
        case .stopping:
            statusRow("Stopping daemon…", color: .orange)
        case .stopped:
            statusRow("Daemon stopped", color: .gray,
                       buttonTitle: "Start Daemon") { model.startDaemonManually() }
        case .failed(let stderr):
            VStack(alignment: .leading, spacing: 8) {
                statusRow("Daemon failed to stay running", color: .red)
                if !stderr.isEmpty {
                    ScrollView {
                        Text(stderr)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                Button("Restart Daemon") { model.restartDaemon() }
            }
            .padding()
        }
    }

    private func statusRow(_ text: String, color: Color, buttonTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
            Spacer()
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
            }
        }
        .padding(8)
    }
}
