import Darwin
import Foundation

/// Spawns and supervises the Go daemon as a child process. The stdin
/// pipe is held open for the child's lifetime: if this app dies for any
/// reason, the pipe closes and `-managed` makes the daemon exit.
final class DaemonProcess {
    var onTermination: (@Sendable (Int32, String) -> Void)?

    private let binaryURL: URL
    private var process: Process?
    private var stdinPipe: Pipe?
    private let stderrTail = StderrTail()
    private let stopFlag = StopFlag()

    init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = ["daemon", "-managed"]

        let stdin = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        p.standardOutput = FileHandle.nullDevice

        let tail = stderrTail
        stderr.fileHandleForReading.readabilityHandler = { handle in
            tail.append(handle.availableData)
        }
        p.terminationHandler = { [weak self] proc in
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self, !self.stopFlag.get() else { return }
            self.onTermination?(proc.terminationStatus, tail.snapshot())
        }

        try p.run()
        process = p
        stdinPipe = stdin // hold the reference; never write, never close while running
    }

    /// Requests a graceful stop (closes stdin - the `-managed` contract), then
    /// escalates to SIGKILL if the child hasn't exited within `timeout`. Never
    /// fires `onTermination` for this intentional exit. Non-blocking: waits via
    /// `Task.sleep` polling, not `waitUntilExit()`, so it's safe to await from
    /// `@MainActor` code.
    ///
    /// Does not clear `process`/`stdinPipe`: this is a `nonisolated` async
    /// function, so code after `await` may resume on a different thread than
    /// the caller's - mutating those properties here would race with the
    /// caller's own access to them. The caller drops its reference instead.
    func stop(timeout: TimeInterval = 2.0) async {
        guard let proc = process, proc.isRunning else { return }
        stopFlag.set()
        try? stdinPipe?.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if proc.isRunning {
            Darwin.kill(proc.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

/// Thread-safe: set once by stop() (on the caller's thread) and read from
/// the termination handler, which Foundation always fires on an arbitrary
/// background thread - a real cross-thread access, same as StderrTail below.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe rolling buffer of the last 4 KiB of stderr.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 4096

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap { data.removeFirst(data.count - cap) }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
