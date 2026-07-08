import Foundation
import Network

/// NWConnection adapter over the daemon's Unix socket. Callbacks fire on
/// a private dispatch queue, so every call into `onReceive`/`onClose`
/// (both `@MainActor`-typed) hops via `Task { @MainActor in ... }`.
final class UnixSocketTransport: DaemonTransport {
    var onReceive: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor (Error?) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "voice-inject.socket")

    init(path: String) {
        let params = NWParameters.tcp // stream semantics; endpoint supplies the unix domain
        connection = NWConnection(to: .unix(path: path), using: params)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveNext()
            case .failed(let error):
                Task { @MainActor in self?.onClose?(error) }
            case .cancelled:
                Task { @MainActor in self?.onClose?(nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.onReceive?(data) }
            }
            if let error {
                Task { @MainActor in self?.onClose?(error) }
                return
            }
            if isComplete {
                Task { @MainActor in self?.onClose?(nil) }
                return
            }
            self?.receiveNext()
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}
