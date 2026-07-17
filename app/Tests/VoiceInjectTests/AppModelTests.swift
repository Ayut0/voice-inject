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

    /// Regression test for #44: manually stopping a healthy daemon must
    /// not respawn it, and must land on .stopped (not .failed) so the UI
    /// can distinguish an intentional stop from a crash.
    func testStopDaemonStopsWithoutRespawning() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.stopDaemon()
        XCTAssertEqual(model.daemonStatus, .stopping, "status must flip synchronously, before the async stop completes")

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)
        XCTAssertEqual(spawnCount(), 1, "stopDaemon() must not trigger a respawn")
    }

    /// Regression test for #44: starting again after a manual stop must
    /// spawn a fresh process and return to .running.
    func testStartDaemonManuallyRespawnsAfterStop() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)

        model.stopDaemon()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)
        XCTAssertEqual(spawnCount(), 1)

        model.startDaemonManually()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(model.daemonStatus, .running)
        XCTAssertEqual(spawnCount(), 2, "startDaemonManually() must spawn a fresh process")
    }

    /// startDaemonManually() must be a no-op outside .stopped - in
    /// particular, clicking it while already .running must not spawn a
    /// second process.
    func testStartDaemonManuallyNoOpsWhenNotStopped() async throws {
        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.startDaemonManually()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spawnCount(), 1, "startDaemonManually() must no-op unless daemonStatus is .stopped")
    }

    /// Regression test for #44: a manual stop must not spend
    /// RestartPolicy's one-time restart budget. The daemon script here
    /// runs normally on its 1st and 3rd launches (blocks on stdin) but
    /// crashes immediately on its 2nd launch (exit 7, no stdin wait).
    /// Sequence: start (spawn 1, healthy) -> stopDaemon() (intentional,
    /// must not touch policy) -> startDaemonManually() (spawn 2, crashes
    /// immediately) -> if stopDaemon() had wrongly gone through
    /// daemonDied(), the policy's one restart would already be spent and
    /// this crash would land on .failed instead of auto-restarting to a
    /// healthy spawn 3.
    func testManualStopDoesNotConsumeRestartPolicyBudget() async throws {
        try """
        #!/bin/sh
        echo spawned >> "\(markerURL.path)"
        n=$(wc -l < "\(markerURL.path)" | tr -d ' ')
        if [ "$n" = "2" ]; then exit 7; fi
        cat >/dev/null
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let model = AppModel()
        model.startDaemon()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.daemonStatus, .running)

        model.stopDaemon()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.daemonStatus, .stopped)

        model.startDaemonManually() // spawn 2: crashes immediately (exit 7)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(model.daemonStatus, .running, "the crash must still get its one automatic restart (spawn 3)")
        XCTAssertEqual(spawnCount(), 3)
    }

    func testLoadConfigPopulatesConfig() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        async let load: Void = model.loadConfig()
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true,\"data\":{\"lang\":\"en\",\"model\":\"/m\",\"minRecordMs\":700,\"maxRecordMs\":60000,\"silenceTimeoutMs\":4000,\"minTextLength\":3,\"maxTextLength\":5000,\"camelCaseRule\":false,\"maxSymbolRatio\":0.5}}\n")

        try await load
        XCTAssertEqual(model.config?.lang, "en")
        XCTAssertEqual(model.config?.maxRecordMs, 60_000)
    }

    func testSaveConfigUpdatesConfigOnSuccess() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        let newConfig = DaemonConfig(lang: "ja", model: "/m2", minRecordMs: 700, maxRecordMs: 45_000, silenceTimeoutMs: 3_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)

        async let save: Void = model.saveConfig(newConfig)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(String(data: transport.sent[0], encoding: .utf8)!.contains("\"name\":\"setConfig\""))
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true}\n")

        try await save
        XCTAssertEqual(model.config, newConfig)
    }

    func testSaveConfigLeavesConfigUnchangedOnFailure() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        let model = AppModel(client: client)

        async let load: Void = model.loadConfig()
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true,\"data\":{\"lang\":\"en\",\"model\":\"/m\",\"minRecordMs\":700,\"maxRecordMs\":60000,\"silenceTimeoutMs\":4000,\"minTextLength\":3,\"maxTextLength\":5000,\"camelCaseRule\":false,\"maxSymbolRatio\":0.5}}\n")
        try await load
        let original = model.config

        let badConfig = DaemonConfig(lang: "xx", model: "/m", minRecordMs: 700, maxRecordMs: 60_000, silenceTimeoutMs: 4_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)

        async let save: Void = model.saveConfig(badConfig)
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":2,\"ok\":false,\"error\":\"unsupported language\"}\n")

        do {
            try await save
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertEqual(model.config, original)
    }
}
