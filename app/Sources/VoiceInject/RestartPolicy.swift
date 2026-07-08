import Foundation

/// "Restart once" policy from the spec: one automatic restart; a second
/// death within `window` of that restart means give up (no crash loop).
struct RestartPolicy {
    enum Action: Equatable { case restart, giveUp }

    private let window: TimeInterval
    private var lastRestartAt: Date?

    init(window: TimeInterval = 10) {
        self.window = window
    }

    mutating func decide(now: Date) -> Action {
        if let last = lastRestartAt, now.timeIntervalSince(last) < window {
            return .giveUp
        }
        lastRestartAt = now
        return .restart
    }
}
