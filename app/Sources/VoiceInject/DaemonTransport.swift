import Foundation

/// Byte-level transport to the daemon. Production: NWConnection over
/// the Unix socket (Task 4). Tests: MockTransport.
protocol DaemonTransport: AnyObject {
    /// Callbacks are `@MainActor`-typed so `DaemonClient` can invoke them
    /// synchronously; implementations that receive bytes off-actor (e.g.
    /// `UnixSocketTransport`'s NWConnection queue) are responsible for
    /// hopping to the main actor themselves before calling these.
    var onReceive: (@MainActor (Data) -> Void)? { get set }
    var onClose: (@MainActor (Error?) -> Void)? { get set }
    func send(_ data: Data)
    func close()
}
