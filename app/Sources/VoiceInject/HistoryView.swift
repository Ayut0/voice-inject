import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var copiedID: UUID?

    var body: some View {
        @Bindable var history = model.history

        VStack(spacing: 0) {
            HStack {
                Toggle("Record history", isOn: $history.recordingEnabled)
                Spacer()
                Button("Clear", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(10)

            Divider()

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "clock",
                    description: Text(history.recordingEnabled
                        ? "Dictations will appear here."
                        : "History recording is turned off.")
                )
            } else {
                List(history.entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                            Text("\(entry.at.formatted(date: .abbreviated, time: .standard)) · \(entry.lang) · \(String(format: "%.1fs", Double(entry.durationMs) / 1000))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            copy(entry)
                        } label: {
                            Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedID == entry.id { copiedID = nil }
        }
    }
}
