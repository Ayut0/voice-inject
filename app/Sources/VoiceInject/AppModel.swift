import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum DaemonStatus: Equatable {
        case starting
        case running
        case restarting
        case failed(stderr: String)
    }

    let client: DaemonClient
    private(set) var daemonStatus: DaemonStatus = .starting

    private var process: DaemonProcess?
    private var policy = RestartPolicy()
    private var pendingTransport: UnixSocketTransport?

    init() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client = DaemonClient(transport: transport)
        // Transport connects in startDaemon(), after the child binds the socket.
        self.pendingTransport = transport
    }

    static func socketPath() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Library/Application Support/voice-inject/daemon.sock")
    }

    /// Resolution order: env override (dev) → bundled binary → repo build.
    static func daemonBinaryURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["VOICE_INJECT_BIN"] {
            return URL(fileURLWithPath: env)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/voice-inject")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // `swift run` from app/: the Go binary built at the repo root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("voice-inject")
    }

    func startDaemon() {
        let proc = DaemonProcess(binaryURL: Self.daemonBinaryURL())
        proc.onTermination = { [weak self] code, stderr in
            Task { @MainActor in self?.daemonDied(code: code, stderr: stderr) }
        }
        do {
            try proc.start()
        } catch {
            daemonStatus = .failed(stderr: "failed to launch: \(error.localizedDescription)")
            return
        }
        process = proc
        daemonStatus = .running
        // Give the daemon a beat to bind the socket, then connect.
        let transport = pendingTransport
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            transport?.connect()
        }
    }

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

    /// Manual restart from the failure banner: resets the policy.
    func restartDaemon() {
        policy = RestartPolicy()
        let transport = UnixSocketTransport(path: Self.socketPath())
        client.rebind(transport: transport)
        pendingTransport = transport
        startDaemon()
    }
}
