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

    @State private var config: DaemonConfig?
    @State private var loadError: String?
    @State private var saveState: SaveState = .idle
    @State private var isChoosingModel = false

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        Form {
            if var cfg = config {
                Picker("Language", selection: Binding(
                    get: { cfg.lang },
                    set: { cfg.lang = $0; config = cfg }
                )) {
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                }

                LabeledContent("Model", value: modelDisplayName(cfg.model))
                Button("Change Model…") { isChoosingModel = true }
                    .fileImporter(isPresented: $isChoosingModel, allowedContentTypes: [.data]) { result in
                        if case .success(let url) = result {
                            config?.model = url.path
                        }
                    }

                Stepper("Max recording: \(cfg.maxRecordMs / 1000)s",
                        value: Binding(
                            get: { cfg.maxRecordMs },
                            set: { cfg.maxRecordMs = $0; config = cfg }
                        ), in: 5_000...120_000, step: 5_000)

                Stepper("Silence timeout: \(cfg.silenceTimeoutMs / 1000)s",
                        value: Binding(
                            get: { cfg.silenceTimeoutMs },
                            set: { cfg.silenceTimeoutMs = $0; config = cfg }
                        ), in: 1_000...10_000, step: 1_000)

                HStack {
                    Button("Save") { save(cfg) }
                        .disabled(saveState == .saving)
                    switch saveState {
                    case .saved: Text("Saved ✓").foregroundStyle(.green)
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
            } else if let loadError {
                Text("Could not load config: \(loadError)").foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading config…")
            }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            config = try await model.client.getConfig()
        } catch {
            loadError = "\(error)"
        }
    }

    private func save(_ cfg: DaemonConfig) {
        saveState = .saving
        Task {
            do {
                var patch = ConfigPatch()
                patch.lang = cfg.lang
                patch.model = cfg.model
                patch.maxRecordMs = cfg.maxRecordMs
                patch.silenceTimeoutMs = cfg.silenceTimeoutMs
                try await model.client.setConfig(patch)
                saveState = .saved
            } catch {
                saveState = .failed("\(error)")
            }
        }
    }
}
