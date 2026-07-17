# Issue #42: Main Window Polished Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `MainWindow`, `SettingsView`, and `HistoryView` to the "2a — Polished" design (design spec: `docs/superpowers/specs/2026-07-17-issue-42-main-window-polished-redesign-design.md`) with zero behavior regressions.

**Architecture:** Hoist daemon config ownership from `SettingsView` into `AppModel` (single source of truth for the banner subline and the Settings form), replace `TabView` with a custom always-mounted segmented tab bar (preserves `@State` across switches), and restyle each view's markup in place using native SwiftUI controls and macOS semantic colors.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, `swift build` / `swift test` (run from `app/`).

## Global Constraints

- Swift tools version 5.10, macOS 14+ target (`app/Package.swift`) — no API newer than macOS 14.
- Prefer macOS semantic colors (`.primary`, `.secondary`, `Color(nsColor: .controlBackgroundColor)`, `.separator`, `.accentColor`, system `.green`/`.orange`/`.red`/`.gray`) over hardcoded hex in `MainWindow.swift`, `SettingsView.swift`, `HistoryView.swift`. (`HUDView.swift`'s hardcoded hex is an intentional exception for its always-dark overlay panel — does not apply here.)
- No changes to daemon protocol, socket transport, config persistence, or history JSONL format.
- Do not touch `HUDView.swift`, `HUDState.swift`, `HUDPanelController.swift`, `DaemonTransport.swift`, `UnixSocketTransport.swift`, `RestartPolicy.swift`, `Protocol.swift`, or `DaemonClient.swift`'s wire-level request/response logic.
- The Setup/first-run tab (#32) is out of scope — the tab bar has exactly two tabs (Settings, History).
- `swift build` and `swift test`, run from `app/`, must pass after every task.
- Every commit message ends with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

---

## Task 1: AppModel config hoisting

**Files:**
- Modify: `app/Sources/VoiceInject/AppModel.swift`
- Modify: `app/Tests/VoiceInjectTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `DaemonClient.getConfig() async throws -> DaemonConfig`, `DaemonClient.setConfig(_ patch: ConfigPatch) async throws` (existing, `DaemonClient.swift:60-66`). `MockTransport` (existing test helper, `DaemonClientTests.swift:5-14`, same test target — no import needed).
- Produces: `AppModel.config: DaemonConfig?` (read-only outside the class), `AppModel.loadConfig() async throws`, `AppModel.saveConfig(_ newConfig: DaemonConfig) async throws`, `AppModel.init(client: DaemonClient)` (test-only entry point, skips daemon-process/transport setup). Tasks 2 and 4 read `model.config` and call `model.loadConfig()` / `model.saveConfig(_:)`.

- [ ] **Step 1: Write the failing tests**

Add to `app/Tests/VoiceInjectTests/AppModelTests.swift`, inside `final class AppModelTests`:

```swift
    func testLoadConfigPopulatesConfig() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        async let load: Void = model.loadConfig()
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true,\"data\":{\"lang\":\"en\",\"model\":\"/m\",\"minRecordMs\":700,\"maxRecordMs\":60000,\"silenceTimeoutMs\":4000,\"minTextLength\":3,\"maxTextLength\":5000,\"camelCaseRule\":false,\"maxSymbolRatio\":0.5}}\n")

        try await load
        XCTAssertEqual(model.config?.lang, "en")
        XCTAssertEqual(model.config?.maxRecordMs, 60_000)
    }

    func testSaveConfigUpdatesConfigOnSuccess() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        let newConfig = DaemonConfig(lang: "ja", model: "/m2", minRecordMs: 700, maxRecordMs: 45_000, silenceTimeoutMs: 3_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)

        async let save: Void = model.saveConfig(newConfig)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(String(data: transport.sent[0], encoding: .utf8)!.contains("\"name\":\"setConfig\""))
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true}\n")

        try await save
        XCTAssertEqual(model.config, newConfig)
    }

    func testSaveConfigLeavesConfigUnchangedOnFailure() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        async let load: Void = model.loadConfig()
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true,\"data\":{\"lang\":\"en\",\"model\":\"/m\",\"minRecordMs\":700,\"maxRecordMs\":60000,\"silenceTimeoutMs\":4000,\"minTextLength\":3,\"maxTextLength\":5000,\"camelCaseRule\":false,\"maxSymbolRatio\":0.5}}\n")
        try await load
        let original = model.config

        let badConfig = DaemonConfig(lang: "xx", model: "/m", minRecordMs: 700, maxRecordMs: 60_000, silenceTimeoutMs: 4_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)

        async let save: Void = model.saveConfig(badConfig)
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":2,\"ok\":false,\"error\":\"unsupported language\"}\n")

        do {
            try await save
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertEqual(model.config, original)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app && swift test --filter AppModelTests 2>&1 | tail -30`
Expected: FAIL — compile error, `AppModel(client:)` and `model.loadConfig()`/`model.saveConfig(_:)` don't exist yet.

- [ ] **Step 3: Implement config hoisting in AppModel**

In `app/Sources/VoiceInject/AppModel.swift`, replace the `private var maxRecordMs: Int64 = 60_000 // refreshed from getConfig` line (line 26) with:

```swift
    private(set) var config: DaemonConfig?
```

Replace the entire `init()` method (lines 28-45) with:

```swift
    init() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client = DaemonClient(transport: transport)
        // Transport connects in startDaemon(), after the child binds the socket.
        self.pendingTransport = transport
        wireClientCallbacks()
    }

    /// Test-only entry point: skips daemon-process/transport setup so
    /// config loading/saving can be exercised against a MockTransport-
    /// backed client without a live daemon socket (see AppModelTests).
    init(client: DaemonClient) {
        self.client = client
        wireClientCallbacks()
    }

    private func wireClientCallbacks() {
        client.onPhaseChange = { [weak self] phase in
            self?.hudInput { $0.phaseChanged(phase, now: Date()) }
            if phase == .idle {
                Task { @MainActor [weak self] in try? await self?.loadConfig() }
            }
        }
        client.onErrorEvent = { [weak self] _, message in
            self?.hudInput { $0.errorOccurred(message: message, now: Date()) }
            // Issue #32 extends this fan-out with its checklist hook.
        }
        client.onTranscript = { [weak self] payload in
            self?.history.record(payload)
        }
    }

    func loadConfig() async throws {
        config = try await client.getConfig()
    }

    func saveConfig(_ newConfig: DaemonConfig) async throws {
        var patch = ConfigPatch()
        patch.lang = newConfig.lang
        patch.model = newConfig.model
        patch.minRecordMs = newConfig.minRecordMs
        patch.maxRecordMs = newConfig.maxRecordMs
        patch.silenceTimeoutMs = newConfig.silenceTimeoutMs
        patch.minTextLength = newConfig.minTextLength
        patch.maxTextLength = newConfig.maxTextLength
        patch.camelCaseRule = newConfig.camelCaseRule
        patch.maxSymbolRatio = newConfig.maxSymbolRatio
        try await client.setConfig(patch)
        config = newConfig
    }
```

In `startDaemon()` (lines 96-101), replace:

```swift
        let transport = pendingTransport
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            transport?.connect()
            refreshMaxRecordMs()
        }
```

with:

```swift
        let transport = pendingTransport
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            transport?.connect()
            try? await loadConfig()
        }
```

Replace the `hudInput` method (lines 175-183) — only the `hud.apply` line changes:

```swift
    private func hudInput(_ mutate: (inout HUDState) -> Void) {
        mutate(&hudState)
        hud.apply(hudState.display, maxRecordMs: config?.maxRecordMs ?? 60_000)
        if case .errorFlash = hudState.display {
            hud.scheduleErrorExpiry(after: HUDState.errorFlashDuration) { [weak self] in
                self?.hudInput { $0.tick(now: Date()) }
            }
        }
    }
```

Delete the now-unused `refreshMaxRecordMs()` method (lines 185-192):

```swift
    /// The bar max tracks live config (user may change it in Settings).
    private func refreshMaxRecordMs() {
        Task { @MainActor in
            if let cfg = try? await client.getConfig() {
                maxRecordMs = cfg.maxRecordMs
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && swift test --filter AppModelTests 2>&1 | tail -40`
Expected: PASS — all `AppModelTests` methods, including the 3 new ones and the pre-existing 5.

- [ ] **Step 5: Build the whole package to confirm nothing else broke**

Run: `cd app && swift build 2>&1 | tail -40`
Expected: builds clean (no other file references `maxRecordMs` or `refreshMaxRecordMs` yet — Tasks 2-5 will start reading `model.config` instead).

- [ ] **Step 6: Commit**

```bash
git add app/Sources/VoiceInject/AppModel.swift app/Tests/VoiceInjectTests/AppModelTests.swift
git commit -m "$(cat <<'EOF'
Hoist daemon config ownership into AppModel

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: MainWindow status banner restyle

**Files:**
- Modify: `app/Sources/VoiceInject/MainWindow.swift`
- Create: `app/Tests/VoiceInjectTests/MainWindowTests.swift`

**Interfaces:**
- Consumes: `AppModel.config: DaemonConfig?` and `AppModel.daemonStatus: DaemonStatus` (Task 1 / existing), `modelDisplayName(_ path: String) -> String` (existing, `SettingsView.swift:8`).
- Produces: `configSubline(_ cfg: DaemonConfig) -> String` (top-level function in `MainWindow.swift`). `statusBanner` is restyled but its call site (`MainWindow.body`) is untouched until Task 3.

- [ ] **Step 1: Write the failing test for configSubline**

Create `app/Tests/VoiceInjectTests/MainWindowTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class ConfigSublineTests: XCTestCase {
    func testFormatsEnglishModelWithMaxAndSilence() {
        let cfg = DaemonConfig(lang: "en", model: "/x/ggml-base.en.bin", minRecordMs: 700, maxRecordMs: 45_000, silenceTimeoutMs: 3_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)
        XCTAssertEqual(configSubline(cfg), "base (English) · max 45s · silence 3s")
    }

    func testFormatsCustomModelName() {
        let cfg = DaemonConfig(lang: "ja", model: "/x/my-custom-model.bin", minRecordMs: 700, maxRecordMs: 60_000, silenceTimeoutMs: 4_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)
        XCTAssertEqual(configSubline(cfg), "my-custom-model · max 60s · silence 4s")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter ConfigSublineTests 2>&1 | tail -20`
Expected: FAIL — compile error, `configSubline` doesn't exist yet.

- [ ] **Step 3: Restyle the status banner**

Replace the entire contents of `app/Sources/VoiceInject/MainWindow.swift` with:

```swift
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
```

(This step temporarily keeps `TabView`/`.tabItem` — Task 3 replaces it with the custom segmented tab bar. Keeping the banner and tab-bar changes in separate steps means a build error in one doesn't hide behind the other.)

- [ ] **Step 4: Run test to verify it passes, then build**

Run: `cd app && swift test --filter ConfigSublineTests 2>&1 | tail -20`
Expected: PASS.

Run: `cd app && swift build 2>&1 | tail -40`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/MainWindow.swift app/Tests/VoiceInjectTests/MainWindowTests.swift
git commit -m "$(cat <<'EOF'
Restyle status banner for all 6 daemon states

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: MainWindow tab bar replacement

**Files:**
- Modify: `app/Sources/VoiceInject/MainWindow.swift`

**Interfaces:**
- Consumes: `SettingsView()`, `HistoryView()` (existing, unchanged initializers).
- Produces: none consumed by later tasks — this is the final structural change to `MainWindow.swift`.

- [ ] **Step 1: Replace TabView with a persistent custom segmented tab bar**

In `app/Sources/VoiceInject/MainWindow.swift`, replace the `struct MainWindow` declaration through the end of its `body` (from `struct MainWindow: View {` through the closing `}` of `.frame(minWidth: 480, minHeight: 360)`) with:

```swift
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
```

(Leave `statusBanner`, `banner(...)`, and `failedBanner(...)` from Task 2 untouched below this — only the top of the struct through the end of `body` changes. `configSubline` at the bottom of the file is also untouched.)

- [ ] **Step 2: Build**

Run: `cd app && swift build 2>&1 | tail -40`
Expected: builds clean. `Tab` is now `MainWindow.Tab` — no other file references the old `TabView`/`.tabItem` structure, so nothing else needs updating.

- [ ] **Step 3: Run full test suite**

Run: `cd app && swift test 2>&1 | tail -60`
Expected: all tests still pass (this task has no unit-testable logic of its own — SwiftUI view layout, consistent with `HUDView.swift` having no tests in this codebase).

- [ ] **Step 4: Commit**

```bash
git add app/Sources/VoiceInject/MainWindow.swift
git commit -m "$(cat <<'EOF'
Replace TabView with a persistent custom segmented tab bar

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SettingsView grouped card restyle

**Files:**
- Modify: `app/Sources/VoiceInject/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.config: DaemonConfig?`, `AppModel.loadConfig() async throws`, `AppModel.saveConfig(_ newConfig: DaemonConfig) async throws` (Task 1). `modelDisplayName(_:)` stays in this file, unchanged, still consumed by `MainWindow.configSubline` (Task 2).
- Produces: none consumed elsewhere — `SaveState` stays private to this file.

- [ ] **Step 1: Restyle SettingsView and wire it to AppModel's config**

Replace the entire contents of `app/Sources/VoiceInject/SettingsView.swift` from `struct SettingsView: View {` to the end of the file with:

```swift
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
```

The `modelDisplayName(_:)` function above `struct SettingsView` (lines 4-17 of the original file) is unchanged — do not remove it, `MainWindow.configSubline` depends on it.

- [ ] **Step 2: Build and run the full test suite**

Run: `cd app && swift build 2>&1 | tail -40`
Expected: builds clean.

Run: `cd app && swift test 2>&1 | tail -60`
Expected: all tests pass, including `ModelDisplayNameTests` (unchanged) and the Task 1 `AppModelTests` config tests.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/VoiceInject/SettingsView.swift
git commit -m "$(cat <<'EOF'
Restyle Settings as a grouped card, wire draft state to AppModel

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HistoryView hover-lift rows, ghost copy button, Clear-disabled fix

**Files:**
- Modify: `app/Sources/VoiceInject/HistoryView.swift`
- Create: `app/Tests/VoiceInjectTests/HistoryViewTests.swift`

**Interfaces:**
- Consumes: `HistoryStore.entries`, `HistoryStore.recordingEnabled`, `HistoryStore.clear()` (existing, unchanged).
- Produces: `historyClearDisabled(recordingEnabled: Bool, entriesIsEmpty: Bool) -> Bool` (top-level function in `HistoryView.swift`). Nothing else consumes it outside this file.

- [ ] **Step 1: Write the failing test for the Clear-disabled logic**

Create `app/Tests/VoiceInjectTests/HistoryViewTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class HistoryClearDisabledTests: XCTestCase {
    func testDisabledWhenRecordingOffEvenWithEntries() {
        XCTAssertTrue(historyClearDisabled(recordingEnabled: false, entriesIsEmpty: false))
    }

    func testDisabledWhenEntriesEmptyEvenWhileRecording() {
        XCTAssertTrue(historyClearDisabled(recordingEnabled: true, entriesIsEmpty: true))
    }

    func testEnabledWhenRecordingOnAndEntriesPresent() {
        XCTAssertFalse(historyClearDisabled(recordingEnabled: true, entriesIsEmpty: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter HistoryClearDisabledTests 2>&1 | tail -20`
Expected: FAIL — compile error, `historyClearDisabled` doesn't exist yet.

- [ ] **Step 3: Restyle HistoryView**

Replace the entire contents of `app/Sources/VoiceInject/HistoryView.swift` from `struct HistoryView: View {` to the end of the file with:

```swift
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var copiedID: UUID?
    @State private var hoveredID: UUID?

    var body: some View {
        @Bindable var history = model.history

        VStack(spacing: 0) {
            HStack {
                Toggle("Record history", isOn: $history.recordingEnabled)
                Spacer()
                Button("Clear", role: .destructive) { history.clear() }
                    .disabled(historyClearDisabled(recordingEnabled: history.recordingEnabled, entriesIsEmpty: history.entries.isEmpty))
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
                        Button(copiedID == entry.id ? "Copied ✓" : "Copy") {
                            copy(entry)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(copiedID == entry.id ? Color.green : Color.secondary)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoveredID == entry.id ? Color.primary.opacity(0.04) : Color.clear)
                    )
                    .onHover { isHovered in hoveredID = isHovered ? entry.id : nil }
                    .listRowSeparator(.hidden)
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

func historyClearDisabled(recordingEnabled: Bool, entriesIsEmpty: Bool) -> Bool {
    !recordingEnabled || entriesIsEmpty
}
```

- [ ] **Step 4: Run test to verify it passes, then build**

Run: `cd app && swift test --filter HistoryClearDisabledTests 2>&1 | tail -20`
Expected: PASS.

Run: `cd app && swift build 2>&1 | tail -40`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/HistoryView.swift app/Tests/VoiceInjectTests/HistoryViewTests.swift
git commit -m "$(cat <<'EOF'
Restyle History rows with hover-lift, ghost copy button, fix Clear-disabled logic

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Full verification pass

**Files:** none (verification only; fixes if verification surfaces a real bug go in the file they belong to, then a follow-up commit).

**Interfaces:** none — this task consumes the finished app, produces nothing for later tasks.

- [ ] **Step 1: Full automated suite**

Run: `cd app && swift build 2>&1 | tail -40 && swift test 2>&1 | tail -80`
Expected: build succeeds, all tests pass (existing `AppModelTests`, `DaemonClientTests`, `DaemonProcessTests`, `RestartPolicyTests`, `HUDStateTests`, `HistoryStoreTests`, `LineBufferTests`, `ProtocolTests`, `ModelDisplayNameTests`, plus the new `ConfigSublineTests`, `HistoryClearDisabledTests`, and the 3 new `AppModelTests` config tests).

- [ ] **Step 2: Launch and manually verify against the issue's agent-verifiable acceptance criteria**

Use the `run` skill (or `swift run` from `app/` with `VOICE_INJECT_BIN` pointing at a `go build ./cmd/voice-inject` binary) to launch the app, then walk this checklist against the issue's acceptance criteria:

- [ ] Status banner: trigger or simulate each of the 6 states (running, starting, restarting, stopping, stopped, failed) and confirm the tinted bar, leading rule, glow dot, and config subline (hidden only in failed) all render.
- [ ] Failed state: stderr scroll box and red "Restart Daemon" button both render and the button works.
- [ ] Tab bar: segmented look, active tab is a raised chip, inactive is transparent/secondary.
- [ ] Settings: grouped card layout, segmented Language picker, tabular-nums stepper readouts, Save button footer right-aligned; Save cycle idle → saving → "Saved ✓" (green, self-clears ~1.6s) → idle; induce a save error (e.g. stop the daemon mid-save) and confirm inline red error text.
- [ ] Tab switching: start editing a Settings field (don't save), switch to History and back — the edit must still be there.
- [ ] History: both empty-state copy variants (off vs. empty), row hover-lift background, Copy → "Copied ✓" (green, 1.5s) micro-interaction, Clear disabled exactly when recording is off or the list is empty.
- [ ] Light and dark mode: toggle macOS appearance and re-check the banner, tab bar, Settings card, and History rows in both.
- [ ] Regression check: config save still round-trips to the daemon socket (reload Settings after a save and confirm the new values persisted), history toggle/clear/copy still function end-to-end.

- [ ] **Step 3: Address any gaps found in Step 2**

If a checklist item fails, fix it in the relevant file (`MainWindow.swift` / `SettingsView.swift` / `HistoryView.swift` / `AppModel.swift`), re-run Step 1, and commit the fix separately with a message describing what was wrong (not a generic "fix bug").

- [ ] **Step 4: Final commit if Step 3 made no changes**

If Step 2 found no gaps, there's nothing to commit for this task — the branch is ready for `finishing-a-development-branch`.
