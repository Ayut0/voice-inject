import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var activeTab: Tab = .settings

    enum Tab { case settings, history }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            tabBar
            ZStack {
                SettingsView()
                    .opacity(activeTab == .settings ? 1 : 0)
                    .allowsHitTesting(activeTab == .settings)
                HistoryView()
                    .opacity(activeTab == .history ? 1 : 0)
                    .allowsHitTesting(activeTab == .history)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(title: "Settings", systemImage: "slider.horizontal.3", tab: .settings)
            tabButton(title: "History", systemImage: "clock", tab: .history)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(title: String, systemImage: String, tab: Tab) -> some View {
        let isActive = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                        .shadow(color: .black.opacity(isActive ? 0.12 : 0), radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.daemonStatus {
        case .running:
            banner(text: "Daemon running — hold ⌥Space to dictate", color: .green,
                   buttonTitle: "Stop Daemon") { model.stopDaemon() }
        case .starting:
            banner(text: "Starting daemon…", color: .orange)
        case .restarting:
            banner(text: "Daemon stopped unexpectedly — restarting…", color: .orange)
        case .stopping:
            banner(text: "Stopping daemon…", color: .orange)
        case .stopped:
            banner(text: "Daemon stopped", color: .gray,
                   buttonTitle: "Start Daemon") { model.startDaemonManually() }
        case .failed(let stderr):
            failedBanner(stderr: stderr)
        }
    }

    private func banner(text: String, color: Color, buttonTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.7), radius: 3)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                }
            }
            if let cfg = model.config {
                Text(configSubline(cfg))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.16))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
    }

    private func failedBanner(stderr: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .shadow(color: Color.red.opacity(0.7), radius: 3)
                Text("Daemon failed to stay running")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            if !stderr.isEmpty {
                ScrollView {
                    Text(stderr)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            Button("Restart Daemon") { model.restartDaemon() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.16))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.red).frame(width: 3)
        }
    }
}

func configSubline(_ cfg: DaemonConfig) -> String {
    "\(modelDisplayName(cfg.model)) · max \(cfg.maxRecordMs / 1000)s · silence \(cfg.silenceTimeoutMs / 1000)s"
}
