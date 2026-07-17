import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum DaemonStatus: Equatable {
        case starting
        case running
        case restarting
        case stopping
        case stopped
        case failed(stderr: String)
    }

    let client: DaemonClient
    let history = HistoryStore(fileURL: HistoryStore.defaultFileURL())
    private(set) var daemonStatus: DaemonStatus = .starting

    private var process: DaemonProcess?
    private var policy = RestartPolicy()
    private var pendingTransport: UnixSocketTransport?
    private(set) var isShuttingDown = false

    private let hud = HUDPanelController()
    private var hudState = HUDState()
    private(set) var config: DaemonConfig?

    init() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client = DaemonClient(transport: transport)
        // Transport connects in startDaemon(), after the child binds the socket.
        self.pendingTransport = transport
        wireClientCallbacks()
    }

    /// Test-only entry point: skips daemon-process/transport setup so
    /// config loading/saving can be exercised against a MockTransport-
    /// backed client without a live daemon socket (see AppModelTests).
    init(client: DaemonClient) {
        self.client = client
        wireClientCallbacks()
    }

    private func wireClientCallbacks() {
        client.onPhaseChange = { [weak self] phase in
            self?.hudInput { $0.phaseChanged(phase, now: Date()) }
            if phase == .idle {
                Task { @MainActor [weak self] in try? await self?.loadConfig() }
            }
        }
        client.onErrorEvent = { [weak self] _, message in
            self?.hudInput { $0.errorOccurred(message: message, now: Date()) }
            // Issue #32 extends this fan-out with its checklist hook.
        }
        client.onTranscript = { [weak self] payload in
            self?.history.record(payload)
        }
    }

    func loadConfig() async throws {
        config = try await client.getConfig()
    }

    func saveConfig(_ newConfig: DaemonConfig) async throws {
        var patch = ConfigPatch()
        patch.lang = newConfig.lang
        patch.model = newConfig.model
        patch.minRecordMs = newConfig.minRecordMs
        patch.maxRecordMs = newConfig.maxRecordMs
        patch.silenceTimeoutMs = newConfig.silenceTimeoutMs
        patch.minTextLength = newConfig.minTextLength
        patch.maxTextLength = newConfig.maxTextLength
        patch.camelCaseRule = newConfig.camelCaseRule
        patch.maxSymbolRatio = newConfig.maxSymbolRatio
        try await client.setConfig(patch)
        config = newConfig
    }

    static func socketPath() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Library/Application Support/voice-inject/daemon.sock")
    }

    /// Resolution order: env override (dev) → bundled binary → repo build.
    ///
    /// The bundled binary lives under `Contents/Resources/`, not
    /// `Contents/MacOS/`: `CFBundleGetMainBundle()` identifies an
    /// executable's bundle by walking up from its own path looking for the
    /// `Foo.app/Contents/MacOS/<exe>` shape, regardless of whether `<exe>`
    /// matches `CFBundleExecutable`. A `voice-inject` binary placed in
    /// `Contents/MacOS/` alongside `VoiceInjectApp` therefore matches that
    /// shape and inherits the app's own `CFBundleIdentifier` once it touches
    /// any Cocoa/Carbon API (as the hotkey registration does) - so both
    /// processes register with LaunchServices under the same identifier,
    /// and an Apple Event `quit` addressed to that identifier can be
    /// delivered to the daemon instead of the app (see #39).
    static func daemonBinaryURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["VOICE_INJECT_BIN"] {
            return URL(fileURLWithPath: env)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/voice-inject")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // `swift run` from app/: the Go binary built at the repo root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("voice-inject")
    }

    func startDaemon() {
        if isShuttingDown { return }
        if process?.isRunning == true { return }
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
            try? await loadConfig()
        }
    }

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

    /// Orderly shutdown for app termination: sets `isShuttingDown` first so
    /// `startDaemon()` can't respawn a replacement (whether via a racing
    /// `daemonDied()` restart or a stray scene re-`.task`), then stops the
    /// daemon via its graceful path. `DaemonProcess.stop()` suppresses its
    /// own `onTermination`, so this never triggers `daemonDied()` either.
    func shutdown() async {
        isShuttingDown = true
        if let proc = process, proc.isRunning {
            await proc.stop()
        }
    }

    private func hudInput(_ mutate: (inout HUDState) -> Void) {
        mutate(&hudState)
        hud.apply(hudState.display, maxRecordMs: config?.maxRecordMs ?? 60_000)
        if case .errorFlash = hudState.display {
            hud.scheduleErrorExpiry(after: HUDState.errorFlashDuration) { [weak self] in
                self?.hudInput { $0.tick(now: Date()) }
            }
        }
    }

}
