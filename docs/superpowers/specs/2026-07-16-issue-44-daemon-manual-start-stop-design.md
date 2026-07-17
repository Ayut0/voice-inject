# Manual Start/Stop Control for the Daemon (Issue #44)

**Date:** 2026-07-16
**Status:** Approved design, pending implementation plan

## Problem

`MainWindow.swift`'s status banner only ever shows a control when the daemon has already died: a "Restart Daemon" button, visible exclusively in the `.failed` case. When the daemon is healthy (`.running`), the banner shows a plain green status line with no buttons — there is no way to manually stop a running daemon, or start one that isn't running, short of quitting/relaunching the whole app.

## Solution overview

Add a "Stop Daemon" button to the `.running` row and a "Start Daemon" button to a new `.stopped` row in the existing status banner (`MainWindow.swift`) — no new UI surface (no menu bar item). A transient `.stopping` status mirrors the existing `.restarting` case, giving visual feedback during the ~2.5s graceful-stop-then-SIGKILL window and preventing a second click from racing the first.

Manual stop reuses `DaemonProcess.stop()`, which already suppresses its own `onTermination` callback (the mechanism `restartDaemon()` relies on for the same reason) — so `daemonDied()` is never invoked for a manual stop, and no `RestartPolicy` strike is consumed.

Explicitly rejected: a menu-bar Start/Stop item (this app has no menu bar customization today; bigger addition than the issue calls for) and a plain instant flip to `.stopped` with no transient state (loses feedback during the multi-second stop and risks a double-click before the button disables).

## State machine changes

`AppModel.DaemonStatus` gains two cases:

```swift
enum DaemonStatus: Equatable {
    case starting
    case running
    case restarting
    case stopping           // new: transient, stop() in flight
    case stopped            // new: terminal until user acts
    case failed(stderr: String)
}
```

- `.stopping` — set the instant the user clicks "Stop Daemon"; cleared once `proc.stop()` returns.
- `.stopped` — daemon not running, no auto-restart pending, distinct from `.failed` (not a crash).

## AppModel changes (`AppModel.swift`)

### New method: `stopDaemon()`

```swift
func stopDaemon() {
    guard let proc = process, proc.isRunning else { return }
    daemonStatus = .stopping
    Task { @MainActor in
        await proc.stop()
        process = nil
        daemonStatus = .stopped
    }
}
```

Guarded to only act when a process is actually running (mirrors the `.failed`-only guard already implicit in `restartDaemon()`'s button placement). Because `DaemonProcess.stop()` sets its internal `stopFlag` before awaiting, the termination handler's `onTermination` closure never fires — `daemonDied()` is not invoked, so `RestartPolicy` is untouched by a manual stop, consistent with how `restartDaemon()` already behaves.

### New method: `startDaemonManually()`

```swift
func startDaemonManually() {
    guard case .stopped = daemonStatus else { return }
    rebindTransportAndStart()
}
```

Guarded to `.stopped` only — the "Start Daemon" button is only rendered in that row, but the guard keeps the method safe to call directly too.

### Refactor: extract `rebindTransportAndStart()`

`restartDaemon()` and `daemonDied()`'s `.restart` case currently duplicate the same three-step sequence: create a fresh `UnixSocketTransport`, `client.rebind(transport:)`, set `pendingTransport`, call `startDaemon()`. This is required because `UnixSocketTransport` wraps a single-use `NWConnection` — once `close()`/cancel fires, the same transport instance cannot reconnect. `startDaemonManually()` needs the identical sequence, so rather than adding a third copy:

```swift
private func rebindTransportAndStart() {
    let transport = UnixSocketTransport(path: Self.socketPath())
    client.rebind(transport: transport)
    pendingTransport = transport
    startDaemon()
}
```

`restartDaemon()` and the `.restart` branch of `daemonDied()` both call this helper instead of inlining the sequence. No behavior change to either existing flow.

## UI changes (`MainWindow.swift`)

`statusBanner`'s switch gains two arms and the `.running` arm changes:

- `.running`: existing green row, plus a "Stop Daemon" button (`model.stopDaemon()`).
- `.stopping`: "Stopping daemon…" (orange), no button — mirrors `.restarting`'s row.
- `.stopped`: "Daemon stopped" (gray/neutral — visually distinct from `.failed`'s red), with a "Start Daemon" button (`model.startDaemonManually()`).
- `.starting`, `.restarting`, `.failed`: unchanged.

## Testing

This repo has no SwiftUI view-rendering tests (`SettingsViewTests.swift` only covers a pure helper function, `modelDisplayName`) — `MainWindow` banner changes are verified manually via `swift run`, consistent with existing convention.

`AppModelTests.swift` gains coverage using the existing spawn-counting test-double pattern (a shell script that records a marker line per launch and blocks on stdin until EOF):

- `stopDaemon()` transitions `.running → .stopping → .stopped`, actually stops the child process, and does not trigger a respawn (spawn count stays at 1 through the stop).
- After `stopDaemon()`, `startDaemonManually()` spawns a new process (spawn count increments to 2) and `daemonStatus` returns to `.running`.
- A manual stop does not consume a `RestartPolicy` strike — verified indirectly: after `stopDaemon()` → `startDaemonManually()` → a genuine crash of the new process, the crash still triggers one automatic restart (proving the policy's single-restart budget wasn't already spent by the manual stop).

## Out of scope

- App-quit lifecycle (tracked in #39 — already merged into `main` as of this branch).
- Daemon accumulation / idempotent restart (already fixed in #38).
- Menu bar controls.
