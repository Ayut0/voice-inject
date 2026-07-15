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
    let history = HistoryStore(fileURL: HistoryStore.defaultFileURL())
    private(set) var daemonStatus: DaemonStatus = .starting

    private var process: DaemonProcess?
    private var policy = RestartPolicy()
    private var pendingTransport: UnixSocketTransport?

    private let hud = HUDPanelController()
    private var hudState = HUDState()
    private var maxRecordMs: Int64 = 60_000 // refreshed from getConfig

    init() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client = DaemonClient(transport: transport)
        // Transport connects in startDaemon(), after the child binds the socket.
        self.pendingTransport = transport

        client.onPhaseChange = { [weak self] phase in
            self?.hudInput { $0.phaseChanged(phase, now: Date()) }
            if phase == .idle { self?.refreshMaxRecordMs() }
        }
        client.onErrorEvent = { [weak self] _, message in
            self?.hudInput { $0.errorOccurred(message: message, now: Date()) }
            // Issue #32 extends this fan-out with its checklist hook.
        }
        client.onTranscript = { [weak self] payload in
            self?.history.record(payload)
        }
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
            refreshMaxRecordMs()
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
}
