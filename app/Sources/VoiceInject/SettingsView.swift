import SwiftUI
import UniformTypeIdentifiers

/// Converts a whisper.cpp ggml model filename into a friendlier label,
/// e.g. "ggml-base.en.bin" -> "base (English)". Falls back to the bare
/// filename for anything that doesn't follow the ggml-<name>.bin
/// convention (custom models aren't required to follow it).
func modelDisplayName(_ path: String) -> String {
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard filename.hasPrefix("ggml-") else { return filename }
    var name = String(filename.dropFirst("ggml-".count))
    if name.hasSuffix(".en") {
        name.removeLast(3)
        name += " (English)"
    }
    return name
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var draft: DaemonConfig?
    @State private var loadError: String?
    @State private var saveState: SaveState = .idle
    @State private var isChoosingModel = false

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        Form {
            if var cfg = draft {
                Section {
                    Picker("Language", selection: Binding(
                        get: { cfg.lang },
                        set: { cfg.lang = $0; draft = cfg }
                    )) {
                        Text("English").tag("en")
                        Text("Japanese").tag("ja")
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Model", value: modelDisplayName(cfg.model))
                    Button("Change Model…") { isChoosingModel = true }
                        .fileImporter(isPresented: $isChoosingModel, allowedContentTypes: [.data]) { result in
                            if case .success(let url) = result {
                                draft?.model = url.path
                            }
                        }

                    Stepper(value: Binding(
                        get: { cfg.maxRecordMs },
                        set: { cfg.maxRecordMs = $0; draft = cfg }
                    ), in: 5_000...120_000, step: 5_000) {
                        HStack {
                            Text("Max recording")
                            Spacer()
                            Text("\(cfg.maxRecordMs / 1000)s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: Binding(
                        get: { cfg.silenceTimeoutMs },
                        set: { cfg.silenceTimeoutMs = $0; draft = cfg }
                    ), in: 1_000...10_000, step: 1_000) {
                        HStack {
                            Text("Silence timeout")
                            Spacer()
                            Text("\(cfg.silenceTimeoutMs / 1000)s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("CONFIGURATION")
                }

                HStack {
                    Spacer()
                    switch saveState {
                    case .saved: Text("Saved ✓").foregroundStyle(.green)
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    default: EmptyView()
                    }
                    Button("Save") { save(cfg) }
                        .disabled(saveState == .saving)
                }
            } else if let loadError {
                Text("Could not load config: \(loadError)").foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading config…")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            try await model.loadConfig()
            draft = model.config
        } catch {
            loadError = "\(error)"
        }
    }

    private func save(_ cfg: DaemonConfig) {
        saveState = .saving
        Task {
            do {
                try await model.saveConfig(cfg)
                saveState = .saved
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if saveState == .saved { saveState = .idle }
            } catch {
                saveState = .failed("\(error)")
            }
        }
    }
}
