import Foundation
import Observation

/// The single object that speaks the daemon protocol. All UI state and
/// callbacks are delivered on the main actor.
@Observable @MainActor
final class DaemonClient {
    enum Phase: Equatable { case disconnected, idle, recording, transcribing }
    struct ErrorInfo: Equatable {
        let stage: String
        let message: String
        let at: Date
    }
    enum ClientError: Error, Equatable {
        case daemon(String)
        case disconnected
    }

    private(set) var phase: Phase = .disconnected
    private(set) var lastError: ErrorInfo?

    /// Hook for the History feature (issue #31). @MainActor closure
    /// types keep these callbacks valid under Swift 6 strict concurrency.
    var onTranscript: (@MainActor (TranscriptPayload) -> Void)?
    /// Hook for the first-run checklist (issue #32).
    var onErrorEvent: (@MainActor (_ stage: String, _ message: String) -> Void)?
    /// Fired on every phase transition. Owned by AppModel (fan-out).
    var onPhaseChange: (@MainActor (Phase) -> Void)?

    private var transport: DaemonTransport
    private var lines = LineBuffer()
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<DaemonResponse, Error>] = [:]

    init(transport: DaemonTransport) {
        self.transport = transport
        rebind(transport: transport)
    }

    // MARK: - Reconnection support (AppModel owns transport lifecycle)

    func rebind(transport: DaemonTransport) {
        handleClose(nil) // fail pending requests, phase = .disconnected
        self.transport = transport
        transport.onReceive = { [weak self] chunk in self?.receive(chunk) }
        transport.onClose = { [weak self] error in self?.handleClose(error) }
    }

    // MARK: - Requests

    func send<T: Decodable>(_ name: String, data: (some Encodable)?, expecting: T.Type) async throws -> T {
        let resp = try await request(name, data: data)
        return try resp.decodePayload(T.self)
    }

    func send(_ name: String, data: (some Encodable)?) async throws {
        _ = try await request(name, data: data)
    }

    func getConfig() async throws -> DaemonConfig {
        try await send("getConfig", data: Optional<ConfigPatch>.none, expecting: DaemonConfig.self)
    }

    func setConfig(_ patch: ConfigPatch) async throws {
        try await send("setConfig", data: patch)
    }

    private func request(_ name: String, data: (some Encodable)?) async throws -> DaemonResponse {
        let id = nextID
        nextID += 1
        let line = try encodeCommand(id: id, name: name, data: data)
        let resp: DaemonResponse = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            transport.send(line)
        }
        if !resp.ok {
            throw ClientError.daemon(resp.error ?? "unknown daemon error")
        }
        return resp
    }

    // MARK: - Incoming

    private func receive(_ chunk: Data) {
        for lineData in lines.append(chunk) {
            guard !lineData.isEmpty else { continue }
            let message: IncomingMessage
            do {
                message = try parseLine(lineData)
            } catch {
                // Malformed line: skip and continue, never disconnect.
                NSLog("[DaemonClient] skipping malformed line: \(error)")
                continue
            }
            handle(message)
        }
    }

    func handle(_ message: IncomingMessage) {
        switch message {
        case .event(.idle): setPhase(.idle)
        case .event(.recording): setPhase(.recording)
        case .event(.transcribing): setPhase(.transcribing)
        case .event(.transcript(let payload)):
            onTranscript?(payload)
        case .event(.error(let stage, let message)):
            lastError = ErrorInfo(stage: stage, message: message, at: Date())
            onErrorEvent?(stage, message)
        case .response(let resp):
            if let cont = pending.removeValue(forKey: resp.id) {
                cont.resume(returning: resp)
            } else {
                NSLog("[DaemonClient] response for unknown id \(resp.id)")
            }
        }
    }

    func handleClose(_ error: Error?) {
        setPhase(.disconnected)
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting {
            cont.resume(throwing: ClientError.disconnected)
        }
    }

    private func setPhase(_ new: Phase) {
        guard new != phase else { return }
        phase = new
        onPhaseChange?(new)
    }
}
