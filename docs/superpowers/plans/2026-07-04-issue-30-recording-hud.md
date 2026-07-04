# Recording HUD Panel (Issue #30) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A floating, non-activating HUD panel that appears while dictating — pulse + elapsed-time bar during recording, spinner while transcribing, ~2 s error flash on failure — without ever stealing focus from the app being dictated into.

**Architecture:** A pure `HUDState` reducer (inputs: daemon phase changes, error events, clock ticks; output: one `HUDDisplay` value) is fully unit-tested with injected dates. A SwiftUI `HUDView` renders that value. An AppKit `HUDPanelController` owns a borderless non-activating `NSPanel` hosting the view and shows/hides it with fades. `AppModel` becomes the single fan-out point for `DaemonClient` callbacks (phase + error) so this feature and issue #32 never fight over the same closure.

**Tech Stack:** Swift 5.10+, SwiftUI + AppKit (`NSPanel`, `NSHostingView`), `@Observable`. Zero third-party dependencies. Builds on the issue #29 package under `app/`.

## Global Constraints

- Consume `DaemonClient.Phase` (`.disconnected, .idle, .recording, .transcribing`) and `ErrorInfo` from #29 — do not redefine them
- The HUD must never take key/main status or activate the app (`.nonactivatingPanel`, no `makeKey`)
- Elapsed time is computed app-side from when `.recording` was observed; the bar max comes from `DaemonConfig.maxRecordMs` (spec)
- There is no `injecting` event: everything between key-release and `idle` renders as the spinner (spec)
- Error flash lasts ~2 s, then the HUD hides (spec)
- No waveform/mic-level metering — deliberately out of scope for v1 (spec)
- All code under `app/Sources/VoiceInject/`, tests under `app/Tests/VoiceInjectTests/`; `swift test` must pass; imperative commit subjects

---

### Task 1: `HUDState` reducer

**Files:**
- Create: `app/Sources/VoiceInject/HUDState.swift`
- Test: `app/Tests/VoiceInjectTests/HUDStateTests.swift`

**Interfaces:**
- Consumes: `DaemonClient.Phase` from #29
- Produces (used by Tasks 2–3):
  - `enum HUDDisplay: Equatable { case hidden, recording(started: Date), working, errorFlash(message: String, shownAt: Date) }`
  - `struct HUDState { private(set) var display: HUDDisplay; static let errorFlashDuration: TimeInterval = 2.0; mutating func phaseChanged(_ phase: DaemonClient.Phase, now: Date); mutating func errorOccurred(message: String, now: Date); mutating func tick(now: Date) }`

Transition rules (encode exactly these):
- `.recording` phase → `.recording(started: now)`
- `.transcribing` phase → `.working`
- `.idle` / `.disconnected` phase → `.hidden`, **unless** an error flash is still live (< 2 s old) — the `idle` that follows a failed dictation must not eat the flash
- `errorOccurred` → `.errorFlash(message, shownAt: now)` from any display
- `tick(now:)` → `.hidden` only if the current display is an expired error flash; otherwise no-op

- [ ] **Step 1: Write the failing test**

`app/Tests/VoiceInjectTests/HUDStateTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class HUDStateTests: XCTestCase {
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    func testHappyPathDictation() {
        var s = HUDState()
        XCTAssertEqual(s.display, .hidden)

        s.phaseChanged(.recording, now: t(0))
        XCTAssertEqual(s.display, .recording(started: t(0)))

        s.phaseChanged(.transcribing, now: t(3))
        XCTAssertEqual(s.display, .working)

        s.phaseChanged(.idle, now: t(5))
        XCTAssertEqual(s.display, .hidden)
    }

    func testErrorFlashSurvivesFollowingIdle() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.phaseChanged(.transcribing, now: t(3))
        s.errorOccurred(message: "model file not found", now: t(4))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // The daemon publishes idle right after the error; flash must persist.
        s.phaseChanged(.idle, now: t(4.1))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // Not yet expired.
        s.tick(now: t(5.9))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // Expired.
        s.tick(now: t(6.01))
        XCTAssertEqual(s.display, .hidden)
    }

    func testIdleAfterFlashExpiryHides() {
        var s = HUDState()
        s.errorOccurred(message: "x", now: t(0))
        s.phaseChanged(.idle, now: t(3)) // flash already expired at idle time
        XCTAssertEqual(s.display, .hidden)
    }

    func testNewRecordingReplacesErrorFlash() {
        var s = HUDState()
        s.errorOccurred(message: "x", now: t(0))
        s.phaseChanged(.recording, now: t(1))
        XCTAssertEqual(s.display, .recording(started: t(1)))
    }

    func testDisconnectedHides() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.phaseChanged(.disconnected, now: t(1))
        XCTAssertEqual(s.display, .hidden)
    }

    func testTickIsNoOpOutsideErrorFlash() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.tick(now: t(100))
        XCTAssertEqual(s.display, .recording(started: t(0)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test --filter HUDStateTests`
Expected: FAIL — `HUDState` undefined.

- [ ] **Step 3: Write the implementation**

`app/Sources/VoiceInject/HUDState.swift`:

```swift
import Foundation

enum HUDDisplay: Equatable {
    case hidden
    case recording(started: Date)
    case working
    case errorFlash(message: String, shownAt: Date)
}

/// Pure HUD display logic. All inputs carry an explicit `now` so tests
/// control the clock; no timers or UI in here.
struct HUDState {
    static let errorFlashDuration: TimeInterval = 2.0

    private(set) var display: HUDDisplay = .hidden

    mutating func phaseChanged(_ phase: DaemonClient.Phase, now: Date) {
        switch phase {
        case .recording:
            display = .recording(started: now)
        case .transcribing:
            display = .working
        case .idle, .disconnected:
            if case .errorFlash(_, let shownAt) = display,
               now.timeIntervalSince(shownAt) < Self.errorFlashDuration {
                return // let the flash finish; tick() will hide it
            }
            display = .hidden
        }
    }

    mutating func errorOccurred(message: String, now: Date) {
        display = .errorFlash(message: message, shownAt: now)
    }

    mutating func tick(now: Date) {
        if case .errorFlash(_, let shownAt) = display,
           now.timeIntervalSince(shownAt) >= Self.errorFlashDuration {
            display = .hidden
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test --filter HUDStateTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/HUDState.swift app/Tests/VoiceInjectTests/HUDStateTests.swift
git commit -m "Add HUD display state reducer"
```

---

### Task 2: `HUDView` (SwiftUI rendering)

**Files:**
- Create: `app/Sources/VoiceInject/HUDView.swift`

**Interfaces:**
- Consumes: `HUDDisplay` (Task 1)
- Produces (used by Task 3): `struct HUDView: View { let display: HUDDisplay; let maxRecordMs: Int64 }`

Pure rendering — no logic worth unit-testing beyond what Task 1 covers; verified visually in Task 3's acceptance.

- [ ] **Step 1: Write the implementation**

`app/Sources/VoiceInject/HUDView.swift`:

```swift
import SwiftUI

struct HUDView: View {
    let display: HUDDisplay
    let maxRecordMs: Int64

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch display {
        case .hidden:
            EmptyView()

        case .recording(let started):
            HStack(spacing: 10) {
                PulsingDot()
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    let elapsed = context.date.timeIntervalSince(started)
                    let fraction = min(elapsed / (Double(maxRecordMs) / 1000.0), 1.0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "Recording  %.1fs", elapsed))
                            .font(.caption.monospacedDigit())
                        ProgressView(value: fraction)
                            .frame(width: 140)
                    }
                }
            }

        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption)
            }

        case .errorFlash(let message, _):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 260)
            }
        }
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulsing ? 1.35 : 0.85)
            .opacity(pulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
```

- [ ] **Step 2: Compile**

Run: `cd app && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/VoiceInject/HUDView.swift
git commit -m "Add HUD SwiftUI view"
```

---

### Task 3: `HUDPanelController` + AppModel fan-out wiring

**Files:**
- Create: `app/Sources/VoiceInject/HUDPanelController.swift`
- Modify: `app/Sources/VoiceInject/DaemonClient.swift` (add one callback)
- Modify: `app/Sources/VoiceInject/AppModel.swift` (fan-out wiring)

**Interfaces:**
- Consumes: `HUDState`, `HUDView` (Tasks 1–2); `DaemonClient`, `AppModel` (#29)
- Produces:
  - **One addition to #29's `DaemonClient` surface:** `var onPhaseChange: ((Phase) -> Void)?` — fired whenever `phase` is assigned a new value
  - `@MainActor final class HUDPanelController { init(); func apply(_ display: HUDDisplay, maxRecordMs: Int64); func scheduleErrorExpiry(after: TimeInterval, tick: @escaping () -> Void) }`
  - **Convention for issue #32:** `AppModel` is the sole owner of `client.onErrorEvent` and `client.onPhaseChange`; it fans out to features. #32 must hook into `AppModel`, not set `client.onErrorEvent` itself.

- [ ] **Step 1: Add the phase callback to `DaemonClient`**

In `app/Sources/VoiceInject/DaemonClient.swift`, add alongside the other hooks:

```swift
    /// Fired on every phase transition. Owned by AppModel (fan-out).
    var onPhaseChange: ((Phase) -> Void)?
```

and change the three phase assignments in `handle(_:)` to route through one helper; replace:

```swift
        case .event(.idle): phase = .idle
        case .event(.recording): phase = .recording
        case .event(.transcribing): phase = .transcribing
```

with:

```swift
        case .event(.idle): setPhase(.idle)
        case .event(.recording): setPhase(.recording)
        case .event(.transcribing): setPhase(.transcribing)
```

then add the helper and use it in `handleClose` too (`phase = .disconnected` → `setPhase(.disconnected)`):

```swift
    private func setPhase(_ new: Phase) {
        guard new != phase else { return }
        phase = new
        onPhaseChange?(new)
    }
```

- [ ] **Step 2: Add a regression test for the callback**

Append to `app/Tests/VoiceInjectTests/DaemonClientTests.swift`:

```swift
    func testPhaseChangeCallbackFiresOncePerTransition() {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        var seen: [DaemonClient.Phase] = []
        client.onPhaseChange = { seen.append($0) }

        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n")
        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n") // duplicate: no callback
        transport.push("{\"type\":\"event\",\"name\":\"recording\"}\n")

        XCTAssertEqual(seen, [.idle, .recording])
    }
```

Run: `cd app && swift test --filter DaemonClientTests`
Expected: PASS (all pre-existing DaemonClient tests must still pass).

- [ ] **Step 3: Write the panel controller**

`app/Sources/VoiceInject/HUDPanelController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the floating NSPanel. Non-activating: showing it never steals
/// focus from the app being dictated into.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<HUDView>
    private var expiryTask: Task<Void, Never>?

    init() {
        hosting = NSHostingView(rootView: HUDView(display: .hidden, maxRecordMs: 60_000))
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
    }

    func apply(_ display: HUDDisplay, maxRecordMs: Int64) {
        hosting.rootView = HUDView(display: display, maxRecordMs: maxRecordMs)

        switch display {
        case .hidden:
            fadeOut()
        default:
            position()
            fadeIn()
        }
    }

    /// One-shot expiry for the error flash; the closure re-enters the
    /// reducer via tick().
    func scheduleErrorExpiry(after seconds: TimeInterval, tick: @escaping @MainActor () -> Void) {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            tick()
        }
    }

    private func position() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func fadeIn() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }
}
```

- [ ] **Step 4: Wire the fan-out in `AppModel`**

In `app/Sources/VoiceInject/AppModel.swift`, add stored properties:

```swift
    private let hud = HUDPanelController()
    private var hudState = HUDState()
    private var maxRecordMs: Int64 = 60_000 // refreshed from getConfig
```

Add to the end of `init()`:

```swift
        client.onPhaseChange = { [weak self] phase in
            self?.hudInput { $0.phaseChanged(phase, now: Date()) }
            if phase == .idle { self?.refreshMaxRecordMs() }
        }
        client.onErrorEvent = { [weak self] _, message in
            self?.hudInput { $0.errorOccurred(message: message, now: Date()) }
            // Issue #32 extends this fan-out with its checklist hook.
        }
```

Add the two helpers to `AppModel`:

```swift
    private func hudInput(_ mutate: (inout HUDState) -> Void) {
        mutate(&hudState)
        hud.apply(hudState.display, maxRecordMs: maxRecordMs)
        if case .errorFlash = hudState.display {
            hud.scheduleErrorExpiry(after: HUDState.errorFlashDuration) { [weak self] in
                self?.hudInput { $0.tick(now: Date()) }
            }
        }
    }

    /// The bar max tracks live config (user may change it in Settings).
    private func refreshMaxRecordMs() {
        Task { @MainActor in
            if let cfg = try? await client.getConfig() {
                maxRecordMs = cfg.maxRecordMs
            }
        }
    }
```

- [ ] **Step 5: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: PASS

- [ ] **Step 6: Manual acceptance (issue #30 criteria)**

Rebuild the bundle: `app/make-app.sh && open app/VoiceInject.app`, then:

1. Click into a text field in another app (e.g. Notes). Hold ⌥Space → HUD appears bottom-center with pulsing dot and a counting elapsed bar; **the Notes window stays focused** (its title bar does not dim, the caret keeps blinking).
2. Keep holding past a few seconds → the bar fills proportionally toward the configured max (default 60 s).
3. Release → HUD switches to "Transcribing…" spinner → text pastes into Notes → HUD fades out.
4. Induce an error: in Settings set the model path to `/nonexistent.bin`, Save, dictate → HUD flashes "model file not found"-style message for ~2 s, then hides. Restore the model path after.
5. Dictate while a full-screen app is frontmost → HUD still appears (joins all Spaces).
6. `swift test` passes; `go test ./...` at repo root untouched/passing.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/VoiceInject/HUDPanelController.swift app/Sources/VoiceInject/DaemonClient.swift app/Sources/VoiceInject/AppModel.swift app/Tests/VoiceInjectTests/DaemonClientTests.swift
git commit -m "Add floating recording HUD panel"
```

---

## Self-Review (completed at plan time)

- **Spec/issue coverage:** appears on recording without stealing focus (T3 panel flags + acceptance 1), recording→transcribing→idle transitions (T1 tests + acceptance 3), elapsed bar app-side with config max (T1 `started` date + T2 TimelineView + `refreshMaxRecordMs`), ~2 s error flash with auto-dismiss (T1 expiry rules + T3 `scheduleErrorExpiry` + acceptance 4), induced-error verification (acceptance 4), no waveform (Global Constraints).
- **Type consistency:** `HUDDisplay`/`HUDState` names match across T1/T2/T3; `DaemonClient.Phase` cases match #29; the one interface addition (`onPhaseChange`) is flagged and regression-tested; the AppModel fan-out convention for #32 is stated where it's created.
- **Placeholder scan:** none — every code step is complete.
