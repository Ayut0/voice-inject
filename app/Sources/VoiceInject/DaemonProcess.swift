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
            self?.onTermination?(proc.terminationStatus, tail.snapshot())
        }

        try p.run()
        process = p
        stdinPipe = stdin // hold the reference; never write, never close while running
    }

    func stop() {
        // Closing stdin asks the managed daemon to exit gracefully.
        try? stdinPipe?.fileHandleForWriting.close()
        process?.waitUntilExit()
        process = nil
        stdinPipe = nil
    }
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
