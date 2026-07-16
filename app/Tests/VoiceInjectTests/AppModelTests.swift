import XCTest
@testable import VoiceInject

@MainActor
final class AppModelTests: XCTestCase {
    private var scriptURL: URL!
    private var markerURL: URL!
    private var previousBin: String?

    override func setUpWithError() throws {
        markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-test-marker-\(UUID().uuidString)")
        // Records one line per launch, then blocks on stdin until EOF
        // (the -managed contract) so we can count how many times
        // startDaemon() actually spawned a process.
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-test-daemon-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho spawned >> \"\(markerURL.path)\"\ncat >/dev/null\nexit 0\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        previousBin = ProcessInfo.processInfo.environment["VOICE_INJECT_BIN"]
        setenv("VOICE_INJECT_BIN", scriptURL.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousBin {
            setenv("VOICE_INJECT_BIN", previousBin, 1)
        } else {
            unsetenv("VOICE_INJECT_BIN")
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: markerURL)
    }

    private func spawnCount() -> Int {
        guard let contents = try? String(contentsOf: markerURL, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n").count
    }

    /// Regression test for #39: quitting must not race a daemon respawn.
    /// shutdown() sets isShuttingDown before stopping the daemon, so any
    /// startDaemon() call arriving after shutdown has begun (a racing
    /// daemonDied() restart, a stray scene re-.task) must no-op instead of
    /// spawning a replacement.
    func testStartDaemonNoOpsOnceShutdownHasBegun() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(spawnCount(), 1, "status: \(model.daemonStatus)")

        await model.shutdown()
        XCTAssertTrue(model.isShuttingDown)

        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(spawnCount(), 1, "startDaemon() must not spawn once shutdown has begun")
    }
}
