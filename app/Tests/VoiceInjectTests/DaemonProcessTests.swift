import XCTest
@testable import VoiceInject

final class DaemonProcessTests: XCTestCase {
    private var scriptURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in scriptURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func makeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-process-test-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scriptURLs.append(url)
        return url
    }

    func testStopClosesStdinAndExitsGracefullyWithoutFiringOnTermination() async throws {
        // Blocks on stdin; exits cleanly once EOF arrives (the -managed contract).
        let script = try makeScript("#!/bin/sh\ncat >/dev/null\nexit 0\n")
        let proc = DaemonProcess(binaryURL: script)
        var terminationFired = false
        proc.onTermination = { _, _ in terminationFired = true }

        try proc.start()
        XCTAssertTrue(proc.isRunning)

        await proc.stop(timeout: 1.0)

        XCTAssertFalse(proc.isRunning)
        XCTAssertFalse(terminationFired, "intentional stop must not be reported as a crash")
    }

    func testStopEscalatesToKillWhenChildIgnoresStdinEOF() async throws {
        // Never reads stdin, so it never notices EOF; must be hard-killed.
        let script = try makeScript("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 0.05; done\n")
        let proc = DaemonProcess(binaryURL: script)
        var terminationFired = false
        proc.onTermination = { _, _ in terminationFired = true }

        try proc.start()
        XCTAssertTrue(proc.isRunning)

        let start = Date()
        await proc.stop(timeout: 0.2) // short timeout: keeps the test fast
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(proc.isRunning)
        XCTAssertLessThan(elapsed, 2.0, "stop() must not hang indefinitely")
        XCTAssertFalse(terminationFired)
    }

    func testUnrequestedExitStillFiresOnTermination() async throws {
        // No stop() call: proves stopFlag doesn't mask a genuine crash.
        let script = try makeScript("#!/bin/sh\nexit 7\n")
        let proc = DaemonProcess(binaryURL: script)
        let exp = expectation(description: "onTermination fires")
        var code: Int32 = -1
        proc.onTermination = { c, _ in code = c; exp.fulfill() }

        try proc.start()
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(code, 7)
    }
}
