# First-Run Checklist + Model Downloader (Issue #32) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Setup tab that turns silent dependency/permission failures into an actionable checklist (pass/fail rows with fix buttons) plus an in-app Whisper model downloader, so setup never requires reading terminal output or knowing filesystem conventions.

**Architecture:** Each check is a `SetupCheck` value with an injectable `probe` closure — tests exercise the aggregation and rendering logic with fake probes, never real macOS APIs. `SetupChecker` (`@Observable`) runs the probes and holds results. `ModelCatalog` is pure data (names, sizes, URLs, destinations — unit-tested). `ModelDownloader` (`@Observable`) streams a download with progress and finishes by calling `setConfig(model:)`. The Go daemon keeps its fail-fast startup (per #28); the Setup tab additionally surfaces `AppModel.daemonStatus == .failed` stderr so a daemon that refused to start points the user here.

**Tech Stack:** Swift 5.10+, SwiftUI, `ApplicationServices` (`AXIsProcessTrusted`), `AVFoundation` (`AVCaptureDevice.authorizationStatus`), `URLSession` bytes streaming. Zero third-party dependencies. Builds on the issue #29 package (plus the #30 fan-out convention: `AppModel` owns all `DaemonClient` callbacks).

## Global Constraints

- Checks: ffmpeg in PATH, whisper-cli in PATH, model file at configured path, Accessibility permission, Microphone permission (issue #32)
- Binary lookup must include `/opt/homebrew/bin` and `/usr/local/bin` (GUI apps don't inherit shell PATH)
- Fix actions: System Settings deep links `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` / `?Privacy_Microphone`; copyable `brew install` commands; model downloader (issue #32)
- Model catalog (README table): tiny 75 MiB, base 142 MiB (recommended), small 466 MiB, medium 1.5 GiB, large-v3-turbo 1.5 GiB; source `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<name>.bin`; destination `~/.local/share/whisper-cpp/models/`
- After a successful download: `setConfig(model: <destination path>)` (issue #32)
- The downloader always installs into `defaultModelsDir()`, even if the user configured a custom model path elsewhere — `setConfig` then repoints config to the default dir. Deliberate v1 simplification.
- "Re-run checks" re-evaluates without an app restart (issue #32)
- Do NOT set `client.onErrorEvent` directly — extend `AppModel`'s fan-out (convention established in #30's plan)
- All code under `app/Sources/VoiceInject/`, tests under `app/Tests/VoiceInjectTests/`; `swift test` must pass; imperative commit subjects

---

### Task 1: `SetupCheck` + `SetupChecker`

**Files:**
- Create: `app/Sources/VoiceInject/SetupChecker.swift`
- Test: `app/Tests/VoiceInjectTests/SetupCheckerTests.swift`

**Interfaces:**
- Produces (used by Task 3):
  - `struct SetupCheck: Identifiable { enum Fix: Equatable { case openSettings(URL), copyCommand(String), downloadModel }; let id: String; let title: String; let failureHelp: String; let fix: Fix?; let probe: @MainActor () -> Bool }`
  - `enum CheckStatus: Equatable { case unknown, pass, fail }`
  - `@Observable @MainActor final class SetupChecker { init(checks: [SetupCheck]); private(set) var results: [String: CheckStatus]; var allPass: Bool; func runAll() }`
  - `@MainActor func standardChecks(modelPath: @escaping () -> String) -> [SetupCheck]` — the five real checks; `modelPath` supplies the current configured model path
  - `func findExecutable(_ name: String) -> String?` — searches `PATH` entries plus `/opt/homebrew/bin`, `/usr/local/bin`

- [ ] **Step 1: Write the failing test**

`app/Tests/VoiceInjectTests/SetupCheckerTests.swift`:

```swift
import XCTest
@testable import VoiceInject

@MainActor
final class SetupCheckerTests: XCTestCase {
    private func check(_ id: String, pass: Bool) -> SetupCheck {
        SetupCheck(id: id, title: id, failureHelp: "help \(id)", fix: nil, probe: { pass })
    }

    func testResultsStartUnknown() {
        let checker = SetupChecker(checks: [check("a", pass: true)])
        XCTAssertEqual(checker.results["a"], CheckStatus.unknown)
        XCTAssertFalse(checker.allPass)
    }

    func testRunAllEvaluatesEveryProbe() {
        let checker = SetupChecker(checks: [check("a", pass: true), check("b", pass: false)])
        checker.runAll()
        XCTAssertEqual(checker.results["a"], .pass)
        XCTAssertEqual(checker.results["b"], .fail)
        XCTAssertFalse(checker.allPass)
    }

    func testAllPassWhenEverythingPasses() {
        let checker = SetupChecker(checks: [check("a", pass: true), check("b", pass: true)])
        checker.runAll()
        XCTAssertTrue(checker.allPass)
    }

    func testRerunReflectsChangedState() {
        var passing = false
        let dynamic = SetupCheck(id: "d", title: "d", failureHelp: "h", fix: nil, probe: { passing })
        let checker = SetupChecker(checks: [dynamic])
        checker.runAll()
        XCTAssertEqual(checker.results["d"], .fail)
        passing = true
        checker.runAll() // "Re-run checks" without restart
        XCTAssertEqual(checker.results["d"], .pass)
    }

    func testStandardChecksHaveExpectedIDsAndFixes() {
        let checks = standardChecks(modelPath: { "/tmp/model.bin" })
        XCTAssertEqual(checks.map(\.id), ["ffmpeg", "whisper-cli", "model", "accessibility", "microphone"])

        let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        XCTAssertEqual(byID["ffmpeg"]?.fix, .copyCommand("brew install ffmpeg"))
        XCTAssertEqual(byID["whisper-cli"]?.fix, .copyCommand("brew install whisper-cpp"))
        XCTAssertEqual(byID["model"]?.fix, .downloadModel)
        XCTAssertEqual(byID["accessibility"]?.fix,
            .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!))
        XCTAssertEqual(byID["microphone"]?.fix,
            .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!))
    }

    func testModelProbeChecksConfiguredPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelFile = dir.appendingPathComponent("m.bin")

        var path = modelFile.path
        let checks = standardChecks(modelPath: { path })
        let model = checks.first { $0.id == "model" }!

        XCTAssertFalse(model.probe())
        try Data("x".utf8).write(to: modelFile)
        XCTAssertTrue(model.probe())
        path = dir.appendingPathComponent("gone.bin").path
        XCTAssertFalse(model.probe()) // probe re-reads the provider each run
    }

    func testFindExecutableLocatesLs() {
        // /bin/ls exists on every macOS box and /bin is in the default PATH.
        XCTAssertNotNil(findExecutable("ls"))
        XCTAssertNil(findExecutable("definitely-not-a-real-binary-xyz"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter SetupCheckerTests`
Expected: FAIL — `SetupCheck` undefined.

- [ ] **Step 3: Write the implementation**

`app/Sources/VoiceInject/SetupChecker.swift`:

```swift
import ApplicationServices
import AVFoundation
import Foundation
import Observation

enum CheckStatus: Equatable {
    case unknown, pass, fail
}

struct SetupCheck: Identifiable {
    enum Fix: Equatable {
        case openSettings(URL)
        case copyCommand(String)
        case downloadModel
    }

    let id: String
    let title: String
    let failureHelp: String
    let fix: Fix?
    let probe: @MainActor () -> Bool
}

@Observable @MainActor
final class SetupChecker {
    let checks: [SetupCheck]
    private(set) var results: [String: CheckStatus]

    init(checks: [SetupCheck]) {
        self.checks = checks
        self.results = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, CheckStatus.unknown) })
    }

    var allPass: Bool {
        !results.isEmpty && results.values.allSatisfy { $0 == .pass }
    }

    func runAll() {
        for check in checks {
            results[check.id] = check.probe() ? .pass : .fail
        }
    }
}

/// Locates a binary in PATH plus the Homebrew prefixes GUI apps miss.
func findExecutable(_ name: String) -> String? {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init)
    dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
    for dir in dirs {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// The five real checks. `modelPath` is read at probe time so a config
/// change (or a finished download) is picked up by "Re-run checks".
@MainActor
func standardChecks(modelPath: @escaping () -> String) -> [SetupCheck] {
    [
        SetupCheck(
            id: "ffmpeg",
            title: "ffmpeg installed",
            failureHelp: "ffmpeg records the microphone. Install it with Homebrew, then re-run checks.",
            fix: .copyCommand("brew install ffmpeg"),
            probe: { findExecutable("ffmpeg") != nil }
        ),
        SetupCheck(
            id: "whisper-cli",
            title: "whisper-cli installed",
            failureHelp: "whisper-cli transcribes locally. Install it with Homebrew, then re-run checks.",
            fix: .copyCommand("brew install whisper-cpp"),
            probe: { findExecutable("whisper-cli") != nil }
        ),
        SetupCheck(
            id: "model",
            title: "Whisper model file present",
            failureHelp: "No model file at the configured path. Download one here.",
            fix: .downloadModel,
            probe: { FileManager.default.fileExists(atPath: modelPath()) }
        ),
        SetupCheck(
            id: "accessibility",
            title: "Accessibility permission granted",
            failureHelp: "Needed to press ⌘V for you. Enable VoiceInject in System Settings.",
            fix: .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!),
            probe: { AXIsProcessTrusted() }
        ),
        SetupCheck(
            id: "microphone",
            title: "Microphone permission granted",
            failureHelp: "Needed to record your voice. Enable VoiceInject in System Settings.",
            fix: .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!),
            probe: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        ),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter SetupCheckerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/SetupChecker.swift app/Tests/VoiceInjectTests/SetupCheckerTests.swift
git commit -m "Add setup checker with injectable probes"
```

---

### Task 2: `ModelCatalog` + `ModelDownloader`

**Files:**
- Create: `app/Sources/VoiceInject/ModelCatalog.swift`
- Create: `app/Sources/VoiceInject/ModelDownloader.swift`
- Test: `app/Tests/VoiceInjectTests/ModelCatalogTests.swift`

**Interfaces:**
- Produces (used by Task 3):
  - `struct ModelCatalog { struct Entry: Identifiable, Equatable { let name: String; let sizeLabel: String; let note: String; var id: String { name }; var fileName: String; var sourceURL: URL; func destinationURL(modelsDir: URL) -> URL }; static let entries: [Entry]; static func defaultModelsDir() -> URL }`
  - `@Observable @MainActor final class ModelDownloader { enum DownloadState: Equatable { case idle, downloading(entry: String, fraction: Double), finished(path: String), failed(String) }; private(set) var state: DownloadState; func download(_ entry: ModelCatalog.Entry, to modelsDir: URL, onInstalled: @escaping (String) async -> Void) }`

- [ ] **Step 1: Write the failing catalog test**

`app/Tests/VoiceInjectTests/ModelCatalogTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class ModelCatalogTests: XCTestCase {
    func testCatalogMatchesReadmeTable() {
        XCTAssertEqual(ModelCatalog.entries.map(\.name),
                       ["tiny", "base", "small", "medium", "large-v3-turbo"])
        let base = ModelCatalog.entries[1]
        XCTAssertEqual(base.sizeLabel, "142 MiB")
        XCTAssertTrue(base.note.contains("recommended"))
    }

    func testURLAndDestinationConstruction() {
        let entry = ModelCatalog.entries.first { $0.name == "large-v3-turbo" }!
        XCTAssertEqual(entry.fileName, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(entry.sourceURL.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
        let dest = entry.destinationURL(modelsDir: URL(fileURLWithPath: "/tmp/models"))
        XCTAssertEqual(dest.path, "/tmp/models/ggml-large-v3-turbo.bin")
    }

    func testDefaultModelsDirIsWhisperCppConvention() {
        let dir = ModelCatalog.defaultModelsDir().path
        XCTAssertTrue(dir.hasSuffix(".local/share/whisper-cpp/models"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter ModelCatalogTests`
Expected: FAIL — `ModelCatalog` undefined.

- [ ] **Step 3: Write the catalog**

`app/Sources/VoiceInject/ModelCatalog.swift`:

```swift
import Foundation

/// Whisper model catalog — mirrors the README table.
struct ModelCatalog {
    struct Entry: Identifiable, Equatable {
        let name: String
        let sizeLabel: String
        let note: String

        var id: String { name }
        var fileName: String { "ggml-\(name).bin" }
        var sourceURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        }
        func destinationURL(modelsDir: URL) -> URL {
            modelsDir.appendingPathComponent(fileName)
        }
    }

    static let entries: [Entry] = [
        Entry(name: "tiny", sizeLabel: "75 MiB", note: "Fastest, least accurate"),
        Entry(name: "base", sizeLabel: "142 MiB", note: "Good balance (recommended)"),
        Entry(name: "small", sizeLabel: "466 MiB", note: "More accurate, slower"),
        Entry(name: "medium", sizeLabel: "1.5 GiB", note: "High accuracy"),
        Entry(name: "large-v3-turbo", sizeLabel: "1.5 GiB", note: "Best accuracy/speed ratio"),
    ]

    static func defaultModelsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/whisper-cpp/models")
    }
}
```

- [ ] **Step 4: Run catalog test to verify it passes, then write the downloader**

Run: `cd app && swift test --filter ModelCatalogTests` → PASS. Then create `app/Sources/VoiceInject/ModelDownloader.swift` (I/O wrapper; exercised by Task 3's manual acceptance):

```swift
import Foundation
import Observation

@Observable @MainActor
final class ModelDownloader {
    enum DownloadState: Equatable {
        case idle
        case downloading(entry: String, fraction: Double)
        case finished(path: String)
        case failed(String)
    }

    private(set) var state: DownloadState = .idle
    private var task: Task<Void, Never>?

    /// Streams the model to a temp file, moves it into place, then hands
    /// the installed path to `onInstalled` (which calls setConfig).
    /// The byte transfer runs OFF the main actor — a 1.5 GiB stream with
    /// per-MiB disk flushes must never stall the UI; only `state`
    /// updates hop back to the main actor.
    func download(_ entry: ModelCatalog.Entry, to modelsDir: URL, onInstalled: @escaping (String) async -> Void) {
        guard task == nil else { return }
        state = .downloading(entry: entry.name, fraction: 0)

        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                let path = try await Self.transfer(entry: entry, modelsDir: modelsDir) { fraction in
                    Task { @MainActor in
                        self?.state = .downloading(entry: entry.name, fraction: fraction)
                    }
                }
                await onInstalled(path)
                self?.state = .finished(path: path)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// nonisolated: runs on the cooperative pool, not the main actor.
    private nonisolated static func transfer(
        entry: ModelCatalog.Entry,
        modelsDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let destination = entry.destinationURL(modelsDir: modelsDir)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let (bytes, response) = try await URLSession.shared.bytes(from: entry.sourceURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let total = Double(http.expectedContentLength)

        let tmp = modelsDir.appendingPathComponent(entry.fileName + ".partial")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)

        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 { // flush + progress per MiB
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress(Double(written) / total) }
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
        return destination.path
    }
}
```

- [ ] **Step 5: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/VoiceInject/ModelCatalog.swift app/Sources/VoiceInject/ModelDownloader.swift app/Tests/VoiceInjectTests/ModelCatalogTests.swift
git commit -m "Add model catalog and streaming downloader"
```

---

### Task 3: `SetupView` + wiring into AppModel and MainWindow

**Files:**
- Create: `app/Sources/VoiceInject/SetupView.swift`
- Modify: `app/Sources/VoiceInject/AppModel.swift`
- Modify: `app/Sources/VoiceInject/MainWindow.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `AppModel`, `daemonStatus`, `client.getConfig/setConfig` (#29); the #30 fan-out convention
- Produces: `AppModel.setup: SetupChecker`, `AppModel.downloader: ModelDownloader`, `AppModel.currentModelPath: String`

- [ ] **Step 1: Wire into `AppModel`**

In `app/Sources/VoiceInject/AppModel.swift`, add stored properties:

```swift
    private(set) var currentModelPath: String = ""
    let downloader = ModelDownloader()
    private(set) lazy var setup: SetupChecker = SetupChecker(
        checks: standardChecks(modelPath: { [weak self] in self?.currentModelPath ?? "" })
    )
```

Extend the existing `onErrorEvent` fan-out from #30 — replace the whole closure assignment (signature included: `stage` is now used) with:

```swift
        client.onErrorEvent = { [weak self] stage, message in
            self?.hudInput { $0.errorOccurred(message: message, now: Date()) }
            // A pipeline error may mean a dependency vanished (e.g. the
            // model file was deleted): refresh the checklist.
            self?.setup.runAll()
            _ = stage
        }
```

Add a config-refresh helper and call it where #30's plan refreshes `maxRecordMs` — merge both into one method (replace `refreshMaxRecordMs` and its call site):

```swift
    /// Pulls the live config for everything app-side that mirrors it.
    private func refreshConfigMirror() {
        Task { @MainActor in
            if let cfg = try? await client.getConfig() {
                maxRecordMs = cfg.maxRecordMs
                currentModelPath = cfg.model
            }
        }
    }
```

…and in `startDaemon()`, after `daemonStatus = .running`, add:

```swift
        refreshConfigMirror()
```

Also update #30's call site inside `onPhaseChange` to use the merged method:

```swift
            if phase == .idle { self?.refreshConfigMirror() }
```

- [ ] **Step 2: Write the view**

`app/Sources/VoiceInject/SetupView.swift`:

```swift
import AppKit
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showDownloader = false
    @State private var copiedCommand: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                if case .failed(let stderr) = model.daemonStatus, !stderr.isEmpty {
                    Section("Daemon failed to start") {
                        Text(stderr)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }

                Section("Dependencies & permissions") {
                    ForEach(model.setup.checks) { check in
                        row(for: check)
                    }
                }
            }

            HStack {
                Button("Re-run checks") { model.setup.runAll() }
                Spacer()
                if model.setup.allPass {
                    Label("All checks pass", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
        }
        .task { model.setup.runAll() }
        .sheet(isPresented: $showDownloader) {
            ModelDownloadSheet()
                .environment(model)
        }
    }

    @ViewBuilder
    private func row(for check: SetupCheck) -> some View {
        let status = model.setup.results[check.id] ?? .unknown
        HStack(alignment: .firstTextBaseline) {
            statusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                if status == .fail {
                    Text(check.failureHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .fail, let fix = check.fix {
                fixButton(fix)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: CheckStatus) -> some View {
        switch status {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fixButton(_ fix: SetupCheck.Fix) -> some View {
        switch fix {
        case .openSettings(let url):
            Button("Open System Settings") { NSWorkspace.shared.open(url) }
        case .copyCommand(let cmd):
            Button(copiedCommand == cmd ? "Copied ✓" : "Copy: \(cmd)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                copiedCommand = cmd
            }
            .font(.system(.caption, design: .monospaced))
        case .downloadModel:
            Button("Download a model…") { showDownloader = true }
        }
    }
}

struct ModelDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download a Whisper model").font(.headline)

            ForEach(ModelCatalog.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.body.monospaced())
                        Text("\(entry.sizeLabel) — \(entry.note)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") {
                        model.downloader.download(entry, to: ModelCatalog.defaultModelsDir()) { path in
                            var patch = ConfigPatch()
                            patch.model = path
                            try? await model.client.setConfig(patch)
                            await MainActor.run { model.setup.runAll() }
                        }
                    }
                    .disabled(isDownloading)
                }
            }

            switch model.downloader.state {
            case .downloading(let name, let fraction):
                ProgressView(value: fraction) { Text("Downloading \(name)… \(Int(fraction * 100))%") }
            case .finished(let path):
                Label("Installed: \(path)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption)
            case .idle:
                EmptyView()
            }

            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isDownloading: Bool {
        if case .downloading = model.downloader.state { return true }
        return false
    }
}
```

- [ ] **Step 3: Add the tab to `MainWindow`**

In `app/Sources/VoiceInject/MainWindow.swift`, replace the Setup placeholder comment — it reads `// Issue #32 adds Setup here.` if issue #31 has landed, or `// Issue #31 adds History here; issue #32 adds Setup.` if not (in that case, keep the `#31` half of the comment as a new line) — with:

```swift
                SetupView()
                    .tabItem { Label("Setup", systemImage: "checklist") }
```

- [ ] **Step 4: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: PASS

- [ ] **Step 5: Manual acceptance (issue #32 criteria)**

Rebuild: `app/make-app.sh && open app/VoiceInject.app`, then:

1. Setup tab shows five rows, each pass/fail with an icon — on a fully configured machine, all green and the "All checks pass" seal.
2. Simulate a missing model: `mv ~/.local/share/whisper-cpp/models/ggml-base.bin{,.bak}`, click "Re-run checks" → model row flips red with help text and "Download a model…" — no app restart needed. (`mv` it back, or proceed to step 3 instead.)
3. Open the downloader, download **tiny** (smallest) → progress bar advances; on completion Settings shows the new model path (`getConfig` reflects the `setConfig`), the model row turns green, and a dictation transcribes with the new model.
4. Revoke Accessibility for VoiceInject in System Settings → Re-run checks → row red; "Open System Settings" lands on the Accessibility pane; re-grant → Re-run → green.
5. `brew` rows: temporarily `PATH=/usr/bin` isn't practical for a GUI app — instead verify the copy button puts `brew install ffmpeg` on the clipboard.
6. Kill the daemon binary's model file and restart the app → daemon fail-fasts (per #28), banner shows failed, and the Setup tab's "Daemon failed to start" section shows the stderr pointing at the model.
7. `swift test` passes.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/VoiceInject/SetupView.swift app/Sources/VoiceInject/AppModel.swift app/Sources/VoiceInject/MainWindow.swift
git commit -m "Add setup checklist tab with model downloader"
```

---

## Self-Review (completed at plan time)

- **Spec/issue coverage:** five distinct human-readable checks (T1 `standardChecks`, acceptance 1), Homebrew-path lookup (T1 `findExecutable`), fix actions per type — System Settings deep links, copyable brew commands, downloader (T1 fixes + T3 `fixButton`, acceptance 3–5), catalog matches the README table with correct URLs/destinations (T2 tests), `setConfig(model:)` on completion + checklist refresh (T3 sheet closure, acceptance 3), re-run without restart (T1 `testRerunReflectsChangedState`, acceptance 2), daemon fail-fast stderr surfaced in Setup (T3 view section, acceptance 6 — this fulfills the spec's "plain alert until Phase 5 → now routed to the checklist UI").
- **Type consistency:** `ConfigPatch.model` optional field matches #29; `AppModel.daemonStatus.failed(stderr:)` case matches #29; fan-out extension modifies exactly the closure #30 created (called out, not duplicated); `refreshConfigMirror` explicitly supersedes #30's `refreshMaxRecordMs` with a merge instruction.
- **Placeholder scan:** none. Known judgment call: probes run synchronously on the main actor (file/PATH checks are microseconds; acceptable).
