# History Tab (Issue #31) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A History tab listing past transcriptions (timestamp, text, copy button) backed by a JSONL file the Swift app owns, with a privacy toggle that stops recording new entries — rescuing text that pasted into the wrong place.

**Architecture:** `HistoryStore` (`@Observable @MainActor`) owns the JSONL file: loads it at init (skipping corrupt lines), appends one line per transcript, keeps entries newest-first in memory. It is populated exclusively from `DaemonClient.onTranscript` — the daemon stays stateless. The file URL and `UserDefaults` are injected so tests run against temp directories. `HistoryView` renders the store; `AppModel` wires the transcript callback gated on the privacy setting.

**Tech Stack:** Swift 5.10+, SwiftUI, Foundation (`JSONEncoder`/`JSONDecoder` with ISO8601 dates, `FileHandle` append), `NSPasteboard`. Zero third-party dependencies. Builds on the issue #29 package under `app/`.

## Global Constraints

- History is populated ONLY from `onTranscript` events; no daemon changes in this issue (spec: daemon stays stateless)
- History file: `~/Library/Application Support/voice-inject/history.jsonl` — one JSON object per line: `text`, `lang`, `durationMs`, `at` (ISO8601)
- Privacy toggle off ⇒ new transcripts are not recorded; dictation/pasting unaffected (spec)
- History persists across app restarts; corrupt lines are skipped, never fatal
- Newest first in the UI
- Consume `TranscriptPayload { text, lang, durationMs }` and the `client.onTranscript` hook from #29 — do not redefine
- All code under `app/Sources/VoiceInject/`, tests under `app/Tests/VoiceInjectTests/`; `swift test` must pass; imperative commit subjects

---

### Task 1: `HistoryStore`

**Files:**
- Create: `app/Sources/VoiceInject/HistoryStore.swift`
- Test: `app/Tests/VoiceInjectTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `TranscriptPayload` (#29)
- Produces (used by Task 2):
  - `struct HistoryEntry: Codable, Equatable, Identifiable { let id: UUID; let at: Date; let text: String; let lang: String; let durationMs: Int64 }` — `id` is a real UUID persisted in the JSONL line (the ISO8601 `at` field drops sub-second precision, so a date-derived id would collide for two dictations in the same second after a reload); lines written before this field existed decode with a fresh UUID
  - `@Observable @MainActor final class HistoryStore { init(fileURL: URL, defaults: UserDefaults = .standard); private(set) var entries: [HistoryEntry]; var recordingEnabled: Bool { get set } /* persisted */; func record(_ payload: TranscriptPayload, at: Date = Date()); func clear() }`
  - `record` is a no-op when `recordingEnabled` is false
  - `static func defaultFileURL() -> URL` — the Application Support path

- [x] **Step 1: Write the failing test**

`app/Tests/VoiceInjectTests/HistoryStoreTests.swift`:

```swift
import XCTest
@testable import VoiceInject

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        suiteName = "HistoryStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName) // no plist litter
    }

    private func payload(_ text: String) -> TranscriptPayload {
        TranscriptPayload(text: text, lang: "en", durationMs: 1200)
    }

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    func testRecordAppendsNewestFirstAndPersists() throws {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("first"), at: t(0))
        store.record(payload("second"), at: t(10))

        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])

        // A fresh store (app restart) loads the same entries.
        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
        XCTAssertEqual(reloaded.entries[1].durationMs, 1200)
        XCTAssertEqual(reloaded.entries[1].lang, "en")
    }

    func testSameSecondEntriesKeepDistinctIDsAcrossReload() {
        // ISO8601 truncates to whole seconds; ids must not collide.
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("a"), at: t(0))
        store.record(payload("b"), at: t(0.5))

        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(Set(reloaded.entries.map(\.id)).count, 2)
    }

    func testCorruptLinesAreSkipped() throws {
        let good = #"{"at":"2026-07-04T12:00:00Z","text":"kept","lang":"en","durationMs":900}"#
        try Data("not json\n\(good)\n{broken\n".utf8).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.entries.map(\.text), ["kept"])
    }

    func testMissingFileMeansEmptyHistory() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.entries, [])
    }

    func testDisabledRecordingIsNoOp() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.recordingEnabled = false
        store.record(payload("secret"), at: t(0))

        XCTAssertEqual(store.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The toggle persists across restarts.
        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertFalse(reloaded.recordingEnabled)
    }

    func testClearRemovesEntriesAndFile() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("bye"), at: t(0))
        store.clear()
        XCTAssertEqual(store.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter HistoryStoreTests`
Expected: FAIL — `HistoryStore` undefined.

- [x] **Step 3: Write the implementation**

`app/Sources/VoiceInject/HistoryStore.swift`:

```swift
import Foundation
import Observation

struct HistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    let text: String
    let lang: String
    let durationMs: Int64

    init(id: UUID = UUID(), at: Date, text: String, lang: String, durationMs: Int64) {
        self.id = id
        self.at = at
        self.text = text
        self.lang = lang
        self.durationMs = durationMs
    }

    // ISO8601 truncates to whole seconds, so `at` cannot serve as the
    // identity; a missing id (line written by an older build) gets a
    // fresh UUID on load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        at = try c.decode(Date.self, forKey: .at)
        text = try c.decode(String.self, forKey: .text)
        lang = try c.decode(String.self, forKey: .lang)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
    }
}

/// Owns the transcript history JSONL file. The daemon never writes
/// history — entries come only from onTranscript events.
@Observable @MainActor
final class HistoryStore {
    private static let enabledKey = "historyRecordingEnabled"

    private(set) var entries: [HistoryEntry] = []

    var recordingEnabled: Bool {
        didSet { defaults.set(recordingEnabled, forKey: Self.enabledKey) }
    }

    private let fileURL: URL
    private let defaults: UserDefaults

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/voice-inject/history.jsonl")
    }

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.recordingEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
    }

    func record(_ payload: TranscriptPayload, at date: Date = Date()) {
        guard recordingEnabled else { return }
        let entry = HistoryEntry(at: date, text: payload.text, lang: payload.lang, durationMs: payload.durationMs)
        entries.insert(entry, at: 0)
        appendToFile(entry)
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = Self.decoder()
        var loaded: [HistoryEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) else {
                continue // corrupt line: skip, never fatal
            }
            loaded.append(entry)
        }
        entries = loaded.reversed() // file is oldest-first; UI is newest-first
    }

    private func appendToFile(_ entry: HistoryEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            NSLog("[HistoryStore] append failed: \(error)")
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter HistoryStoreTests`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/HistoryStore.swift app/Tests/VoiceInjectTests/HistoryStoreTests.swift
git commit -m "Add JSONL-backed history store with privacy toggle"
```

---

### Task 2: `HistoryView` + wiring into AppModel and MainWindow

**Files:**
- Create: `app/Sources/VoiceInject/HistoryView.swift`
- Modify: `app/Sources/VoiceInject/AppModel.swift`
- Modify: `app/Sources/VoiceInject/MainWindow.swift`

**Interfaces:**
- Consumes: `HistoryStore` (Task 1); `AppModel`, `MainWindow` (#29); `client.onTranscript` (#29)
- Produces: `AppModel.history: HistoryStore` (public, used by views; #32 does not touch it)

Note the fan-out convention from issue #30's plan: `AppModel` owns all `DaemonClient` callbacks. `onTranscript` has no other consumer, so wiring it directly here is consistent with that rule.

- [x] **Step 1: Add the store to `AppModel`**

In `app/Sources/VoiceInject/AppModel.swift`, add the property:

```swift
    let history = HistoryStore(fileURL: HistoryStore.defaultFileURL())
```

and add to the end of `init()`:

```swift
        client.onTranscript = { [weak self] payload in
            self?.history.record(payload)
        }
```

(`record` itself checks `recordingEnabled`, so the gate lives in exactly one place.)

- [x] **Step 2: Write the view**

`app/Sources/VoiceInject/HistoryView.swift`:

```swift
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
```

- [x] **Step 3: Add the tab to `MainWindow`**

In `app/Sources/VoiceInject/MainWindow.swift`, replace:

```swift
            TabView {
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                // Issue #31 adds History here; issue #32 adds Setup.
            }
```

with:

```swift
            TabView {
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock") }
                // Issue #32 adds Setup here.
            }
```

- [x] **Step 4: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: PASS

- [x] **Step 5: Manual acceptance (issue #31 criteria)**

Rebuild: `app/make-app.sh && open app/VoiceInject.app`, then:

1. Dictate three times into another app → History tab shows three rows, newest first, each with timestamp, language, and duration.
2. Click a row's copy button → icon flips to a checkmark; ⌘V in a text field pastes that transcript.
3. `cat ~/Library/Application\ Support/voice-inject/history.jsonl` → three JSON lines, oldest first, ISO8601 `at` field.
4. Quit and relaunch the app → the three rows are still there.
5. Turn "Record history" off, dictate → text still pastes into the target app, but no new row and no new JSONL line. Toggle survives an app restart.
6. Clear → list empties and the JSONL file is gone.
7. `swift test` passes.

- [x] **Step 6: Commit**

```bash
git add app/Sources/VoiceInject/HistoryView.swift app/Sources/VoiceInject/AppModel.swift app/Sources/VoiceInject/MainWindow.swift
git commit -m "Add history tab with copy and privacy toggle"
```

---

## Self-Review (completed at plan time)

- **Spec/issue coverage:** every enabled transcript appends to file + list (T1 tests, acceptance 1/3), copy button via NSPasteboard (T2, acceptance 2), privacy toggle no-ops recording without touching dictation (T1 `testDisabledRecordingIsNoOp`, acceptance 5), persistence across restarts (T1 reload test, acceptance 4), corrupt-line tolerance (T1), daemon stateless — zero Go changes (Global Constraints), newest-first (T1 + acceptance 1).
- **Type consistency:** `TranscriptPayload` field names match #29 (`text`, `lang`, `durationMs`); `HistoryEntry.id` is a persisted UUID (a date-derived id would collide within the same second after an ISO8601 round-trip — caught in review, fixed, and regression-tested); `AppModel.history` name used identically in T2's view; MainWindow diff matches the exact #29 text including the placeholder comment.
- **Placeholder scan:** none — all code complete.
