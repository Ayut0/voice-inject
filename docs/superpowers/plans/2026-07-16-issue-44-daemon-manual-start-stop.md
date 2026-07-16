# Manual Start/Stop Daemon Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user manually stop a healthy daemon and start it again from the app's main window, independent of the crash/`.failed` auto-restart path.

**Architecture:** Add two `AppModel.DaemonStatus` cases (`.stopping`, `.stopped`) and two `AppModel` methods (`stopDaemon()`, `startDaemonManually()`) that reuse `DaemonProcess.stop()`'s existing termination-suppression, so a manual stop never touches `RestartPolicy`. Extract the transport-rebind-and-start sequence (duplicated today in `restartDaemon()` and `daemonDied()`) into a shared private helper so the new start-after-stop path doesn't add a third copy. Wire two new banner rows into `MainWindow.swift`'s existing `statusBanner` switch.

**Tech Stack:** Swift 5, SwiftUI, `@Observable` (Observation framework), XCTest, SwiftPM (`app/Package.swift`).

## Global Constraints

- macOS only; no changes to the Go daemon or its wire protocol — this is a Swift-app-only feature.
- This repo has no SwiftUI view-rendering tests. `MainWindow.swift` changes are verified by running the app (`swift run` from `app/`), not by an automated test.
- Follow existing naming: MixedCaps for exported/public Swift identifiers, lowerCamel for unexported (matches the Go convention in `CLAUDE.md` and the existing Swift code).
- `DaemonStatus` transitions only ever happen inside `@MainActor`-isolated `AppModel` methods — don't introduce mutation from anywhere else.
- Run `swift test` from the `app/` directory for all test steps in this plan (the package lives at `app/Package.swift`).

---

### Task 1: Extract `rebindTransportAndStart()` helper

**Files:**
- Modify: `app/Sources/VoiceInject/AppModel.swift:102-134` (the `daemonDied(code:stderr:)` and `restartDaemon()` methods)

**Interfaces:**
- Produces: `private func rebindTransportAndStart()` on `AppModel` — no parameters, no return value. Creates a fresh `UnixSocketTransport`, rebinds `client` to it, stores it in `pendingTransport`, and calls `startDaemon()`. Later tasks (Task 2) call this from `startDaemonManually()`.

This is a pure refactor — behavior of `restartDaemon()` and the crash-triggered `.restart` path in `daemonDied()` must be identical before and after. There is no new test: the existing test suite (in particular `AppModelTests.testStartDaemonNoOpsOnceShutdownHasBegun`, plus all `DaemonProcessTests`) already exercises `startDaemon()`/`shutdown()` and must keep passing unchanged as a regression check.

- [ ] **Step 1: Read the current methods to confirm line numbers before editing**

Open `app/Sources/VoiceInject/AppModel.swift` and confirm `daemonDied(code:stderr:)` and `restartDaemon()` currently read:

```swift
    private func daemonDied(code: Int32, stderr: String) {
        switch policy.decide(now: Date()) {
        case .restart:
            daemonStatus = .restarting
            // Reconnect needs a fresh transport+client wiring; simplest
            // correct v1: recreate transport and rebind callbacks.
            let transport = UnixSocketTransport(path: Self.socketPath())
            client.rebind(transport: transport)
            pendingTransport = transport
            startDaemon()
        case .giveUp:
            daemonStatus = .failed(stderr: stderr)
        }
    }

    /// Manual restart from the failure banner: resets the policy and stops
    /// the current daemon before spawning its replacement. The stop is
    /// intentional, so `DaemonProcess` suppresses `onTermination` for it -
    /// `daemonDied()` is never invoked, and no `RestartPolicy` strike is
    /// consumed.
    func restartDaemon() {
        policy = RestartPolicy()
        Task { @MainActor in
            if let proc = process, proc.isRunning {
                await proc.stop()
            }
            process = nil
            let transport = UnixSocketTransport(path: Self.socketPath())
            client.rebind(transport: transport)
            pendingTransport = transport
            startDaemon()
        }
    }
```

If the surrounding code has drifted from this, adapt the following steps to match — the important part is the duplicated 3-line "fresh transport / rebind / pendingTransport" sequence in both methods.

- [ ] **Step 2: Replace both methods, adding the shared helper**

Replace the two methods above with:

```swift
    private func daemonDied(code: Int32, stderr: String) {
        switch policy.decide(now: Date()) {
        case .restart:
            daemonStatus = .restarting
            rebindTransportAndStart()
        case .giveUp:
            daemonStatus = .failed(stderr: stderr)
        }
    }

    /// Manual restart from the failure banner: resets the policy and stops
    /// the current daemon before spawning its replacement. The stop is
    /// intentional, so `DaemonProcess` suppresses `onTermination` for it -
    /// `daemonDied()` is never invoked, and no `RestartPolicy` strike is
    /// consumed.
    func restartDaemon() {
        policy = RestartPolicy()
        Task { @MainActor in
            if let proc = process, proc.isRunning {
                await proc.stop()
            }
            process = nil
            rebindTransportAndStart()
        }
    }

    /// Creates a fresh transport and rebinds the client to it, then starts
    /// the daemon. A fresh `UnixSocketTransport` is required on every
    /// restart because it wraps a single-use `NWConnection` - once
    /// cancelled/closed, the same instance can't reconnect.
    private func rebindTransportAndStart() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client.rebind(transport: transport)
        pendingTransport = transport
        startDaemon()
    }
```

- [ ] **Step 3: Build and run the full test suite to confirm no regression**

Run (from `app/`):
```bash
swift build && swift test
```
Expected: build succeeds, all existing tests pass (same pass count as before this change — no test was added or removed in this task).

- [ ] **Step 4: Commit**

```bash
git add app/Sources/VoiceInject/AppModel.swift
git commit -m "Extract rebindTransportAndStart() helper in AppModel

Removes the duplicated fresh-transport/rebind/startDaemon() sequence
from restartDaemon() and daemonDied()'s .restart case. No behavior
change; a later commit reuses this helper for manual daemon start."
```

---

### Task 2: Manual stop/start — state machine, AppModel methods, UI

**Files:**
- Modify: `app/Sources/VoiceInject/AppModel.swift` (the `DaemonStatus` enum, and add two new methods after `restartDaemon()`)
- Modify: `app/Sources/VoiceInject/MainWindow.swift` (the `statusBanner` computed property and `statusRow` helper)
- Test: `app/Tests/VoiceInjectTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `private func rebindTransportAndStart()` from Task 1.
- Produces: `func stopDaemon()` and `func startDaemonManually()` on `AppModel` (both `@MainActor`, no parameters, no return value). `DaemonStatus` gains `case stopping` and `case stopped`. Later tasks (Task 3) call `stopDaemon()` and `startDaemonManually()` from a test.

- [ ] **Step 1: Write the failing tests**

Open `app/Tests/VoiceInjectTests/AppModelTests.swift`. It currently ends with:

```swift
        XCTAssertEqual(spawnCount(), 1, "startDaemon() must not spawn once shutdown has begun")
    }
}
```

Insert three new test methods right before the final closing `}` of the class (i.e. replace that snippet with the following):

```swift
        XCTAssertEqual(spawnCount(), 1, "startDaemon() must not spawn once shutdown has begun")
    }

    /// Regression test for #44: manually stopping a healthy daemon must
    /// not respawn it, and must land on .stopped (not .failed) so the UI
    /// can distinguish an intentional stop from a crash.
    func testStopDaemonStopsWithoutRespawning() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.stopDaemon()
        XCTAssertEqual(model.daemonStatus, .stopping, "status must flip synchronously, before the async stop completes")

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)
        XCTAssertEqual(spawnCount(), 1, "stopDaemon() must not trigger a respawn")
    }

    /// Regression test for #44: starting again after a manual stop must
    /// spawn a fresh process and return to .running.
    func testStartDaemonManuallyRespawnsAfterStop() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)

        model.stopDaemon()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)
        XCTAssertEqual(spawnCount(), 1)

        model.startDaemonManually()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(model.daemonStatus, .running)
        XCTAssertEqual(spawnCount(), 2, "startDaemonManually() must spawn a fresh process")
    }

    /// startDaemonManually() must be a no-op outside .stopped - in
    /// particular, clicking it while already .running must not spawn a
    /// second process.
    func testStartDaemonManuallyNoOpsWhenNotStopped() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.startDaemonManually()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spawnCount(), 1, "startDaemonManually() must no-op unless daemonStatus is .stopped")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run (from `app/`):
```bash
swift test 2>&1 | tail -30
```
Expected: a compile error, e.g. `value of type 'AppModel' has no member 'stopDaemon'` (and/or `type 'AppModel.DaemonStatus' has no member 'stopping'`). This is the RED state — the test file references symbols that don't exist yet.

- [ ] **Step 3: Add the two new `DaemonStatus` cases**

In `app/Sources/VoiceInject/AppModel.swift`, the enum currently reads:

```swift
    enum DaemonStatus: Equatable {
        case starting
        case running
        case restarting
        case failed(stderr: String)
    }
```

Replace it with:

```swift
    enum DaemonStatus: Equatable {
        case starting
        case running
        case restarting
        case stopping
        case stopped
        case failed(stderr: String)
    }
```

- [ ] **Step 4: Add `stopDaemon()` and `startDaemonManually()`**

Immediately after the `restartDaemon()` method (and before `rebindTransportAndStart()` from Task 1, or after it — either position is fine as long as it's inside the class), add:

```swift
    /// Manual stop from the running banner: treated as intentional, same
    /// as `restartDaemon()`'s stop - `DaemonProcess.stop()` suppresses its
    /// own `onTermination`, so `daemonDied()` never fires and no
    /// `RestartPolicy` strike is consumed.
    func stopDaemon() {
        guard let proc = process, proc.isRunning else { return }
        daemonStatus = .stopping
        Task { @MainActor in
            await proc.stop()
            process = nil
            daemonStatus = .stopped
        }
    }

    /// Manual start from the stopped banner. Only valid from .stopped -
    /// the button that calls this is only shown in that state, but the
    /// guard makes the method safe to call directly too.
    func startDaemonManually() {
        guard case .stopped = daemonStatus else { return }
        rebindTransportAndStart()
    }
```

- [ ] **Step 5: Run the tests to verify they still fail (MainWindow.swift is now non-exhaustive)**

Run (from `app/`):
```bash
swift test 2>&1 | tail -30
```
Expected: a new compile error in `MainWindow.swift`, e.g. `switch must be exhaustive` — adding the two enum cases broke the existing switch in `statusBanner`. This is expected; fixed in the next step.

- [ ] **Step 6: Update `MainWindow.swift`'s status banner**

Open `app/Sources/VoiceInject/MainWindow.swift`. It currently reads:

```swift
    @ViewBuilder
    private var statusBanner: some View {
        switch model.daemonStatus {
        case .running:
            statusRow("Daemon running — hold ⌥Space to dictate", color: .green)
        case .starting:
            statusRow("Starting daemon…", color: .orange)
        case .restarting:
            statusRow("Daemon stopped unexpectedly — restarting…", color: .orange)
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

    private func statusRow(_ text: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
            Spacer()
        }
        .padding(8)
    }
```

Replace both with:

```swift
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
```

- [ ] **Step 7: Run the tests to verify they pass**

Run (from `app/`):
```bash
swift build && swift test 2>&1 | tail -30
```
Expected: build succeeds, all tests pass, including the three new ones from Step 1.

- [ ] **Step 8: Manually verify the UI**

From `app/`, run:
```bash
swift run
```
In the app window:
1. Wait for the green "Daemon running…" row — confirm a "Stop Daemon" button appears on the right.
2. Click it — confirm the row briefly shows "Stopping daemon…" (orange), then settles on "Daemon stopped" (gray) with a "Start Daemon" button.
3. Click "Start Daemon" — confirm the row returns to the green "Daemon running…" state and dictation works again (hold ⌥Space).

Quit the app (⌘Q) when done.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/VoiceInject/AppModel.swift app/Sources/VoiceInject/MainWindow.swift app/Tests/VoiceInjectTests/AppModelTests.swift
git commit -m "Add manual start/stop daemon control (#44)

Adds .stopping/.stopped DaemonStatus cases and
stopDaemon()/startDaemonManually() AppModel methods, reusing
DaemonProcess.stop()'s existing onTermination suppression so a
manual stop never consumes a RestartPolicy strike. Wires a 'Stop
Daemon' button into the .running banner row and a 'Start Daemon'
button into the new .stopped row."
```

---

### Task 3: Regression test — manual stop doesn't spend the RestartPolicy budget

**Files:**
- Test: `app/Tests/VoiceInjectTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.stopDaemon()`, `AppModel.startDaemonManually()`, `AppModel.startDaemon()`, `AppModel.daemonStatus` (all from Task 2 / pre-existing).

`RestartPolicy` (see `app/Sources/VoiceInject/RestartPolicy.swift`) allows exactly one automatic restart; a second death within its 10s window gives up. `stopDaemon()`/`startDaemonManually()` never call `policy.decide()`, so by construction a manual stop can't spend that budget — but this is a real invariant worth locking in with a test, since a future refactor that accidentally routes a manual stop through `daemonDied()` would silently break it. This task adds that regression test. No production code is expected to change; if the test fails, it means Task 2 was implemented incorrectly (a manual stop is reaching `daemonDied()`) and that should be fixed in `AppModel.swift`, not worked around here.

- [ ] **Step 1: Write the test**

Add this test method to `app/Tests/VoiceInjectTests/AppModelTests.swift`, immediately before the final closing `}` of the class (after `testStartDaemonManuallyNoOpsWhenNotStopped` from Task 2):

```swift

    /// Regression test for #44: a manual stop must not spend
    /// RestartPolicy's one-time restart budget. The daemon script here
    /// runs normally on its 1st and 3rd launches (blocks on stdin) but
    /// crashes immediately on its 2nd launch (exit 7, no stdin wait).
    /// Sequence: start (spawn 1, healthy) -> stopDaemon() (intentional,
    /// must not touch policy) -> startDaemonManually() (spawn 2, crashes
    /// immediately) -> if stopDaemon() had wrongly gone through
    /// daemonDied(), the policy's one restart would already be spent and
    /// this crash would land on .failed instead of auto-restarting to a
    /// healthy spawn 3.
    func testManualStopDoesNotConsumeRestartPolicyBudget() async throws {
        try """
        #!/bin/sh
        echo spawned >> "\(markerURL.path)"
        n=$(wc -l < "\(markerURL.path)" | tr -d ' ')
        if [ "$n" = "2" ]; then exit 7; fi
        cat >/dev/null
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.stopDaemon()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)

        model.startDaemonManually() // spawn 2: crashes immediately (exit 7)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(model.daemonStatus, .running, "the crash must still get its one automatic restart (spawn 3)")
        XCTAssertEqual(spawnCount(), 3)
    }
```

- [ ] **Step 2: Run the test to verify it passes**

Run (from `app/`):
```bash
swift test --filter AppModelTests.testManualStopDoesNotConsumeRestartPolicyBudget 2>&1 | tail -20
```
Expected: PASS. (This test is not expected to start red — Task 2's implementation should already satisfy it. If it fails, stop and re-check `stopDaemon()`/`startDaemonManually()` in `AppModel.swift` for an accidental call into `daemonDied()` or `policy.decide()` before continuing.)

- [ ] **Step 3: Run the full suite once more**

Run (from `app/`):
```bash
swift build && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass (Task 1's existing suite + Task 2's three tests + this task's one test).

- [ ] **Step 4: Commit**

```bash
git add app/Tests/VoiceInjectTests/AppModelTests.swift
git commit -m "Add regression test: manual stop must not spend RestartPolicy budget (#44)

Locks in that stopDaemon()/startDaemonManually() never route through
daemonDied(), so a crash after a manual stop+restart still gets its
one automatic RestartPolicy retry."
```

---

## Self-Review Notes

- **Spec coverage:** `.stopping`/`.stopped` states (Task 2 Step 3) ✓; `stopDaemon()` reusing `DaemonProcess.stop()`'s suppression (Task 2 Step 4) ✓; `rebindTransportAndStart()` extraction (Task 1) used by `startDaemonManually()` (Task 2 Step 4) ✓; banner UI for both new states plus the `.running` Stop button (Task 2 Step 6) ✓; manual UI verification since no view tests exist (Task 2 Step 8) ✓; RestartPolicy non-consumption regression test (Task 3) ✓. Menu-bar controls and app-quit lifecycle are explicitly out of scope per the spec and untouched by this plan.
- **Placeholder scan:** no TBD/TODO; every step shows complete, runnable code and exact commands.
- **Type consistency:** `stopDaemon()` / `startDaemonManually()` names and signatures match between Task 2 (definition) and Task 3 (usage). `DaemonStatus.stopping` / `.stopped` names match between Task 2's enum, `MainWindow.swift`'s switch, and all test assertions.
