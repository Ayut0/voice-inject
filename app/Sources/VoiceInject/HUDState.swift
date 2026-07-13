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
