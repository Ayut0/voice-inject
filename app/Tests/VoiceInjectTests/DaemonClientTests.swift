import XCTest
@testable import VoiceInject

@MainActor
final class MockTransport: DaemonTransport {
    var onReceive: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor (Error?) -> Void)?
    var sent: [Data] = []
    func send(_ data: Data) { sent.append(data) }
    func close() {}

    /// Simulate the daemon pushing bytes.
    func push(_ s: String) { onReceive?(Data(s.utf8)) }
}

@MainActor
final class DaemonClientTests: XCTestCase {
    func testEventsDrivePhase() {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        XCTAssertEqual(client.phase, .disconnected)

        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n")
        XCTAssertEqual(client.phase, .idle)
        transport.push("{\"type\":\"event\",\"name\":\"recording\"}\n")
        XCTAssertEqual(client.phase, .recording)
        transport.push("{\"type\":\"event\",\"name\":\"transcribing\"}\n")
        XCTAssertEqual(client.phase, .transcribing)
    }

    func testTranscriptAndErrorCallbacks() {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)

        var transcripts: [TranscriptPayload] = []
        var errors: [(String, String)] = []
        client.onTranscript = { transcripts.append($0) }
        client.onErrorEvent = { errors.append(($0, $1)) }

        transport.push("{\"type\":\"event\",\"name\":\"transcript\",\"data\":{\"text\":\"hi\",\"lang\":\"en\",\"durationMs\":900}}\n")
        transport.push("{\"type\":\"event\",\"name\":\"error\",\"data\":{\"stage\":\"inject\",\"message\":\"nope\"}}\n")

        XCTAssertEqual(transcripts, [TranscriptPayload(text: "hi", lang: "en", durationMs: 900)])
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(client.lastError?.stage, "inject")
    }

    func testRequestResponseCorrelationSurvivesInterleavedEvents() async throws {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)

        async let cfg = client.getConfig()
        // Let the request register, then interleave an event BEFORE the response.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, 1)
        let sentLine = String(data: transport.sent[0], encoding: .utf8)!
        XCTAssertTrue(sentLine.contains("\"name\":\"getConfig\""))

        transport.push("{\"type\":\"event\",\"name\":\"recording\"}\n")
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":true,\"data\":{\"lang\":\"ja\",\"model\":\"/m\",\"minRecordMs\":700,\"maxRecordMs\":60000,\"silenceTimeoutMs\":4000,\"minTextLength\":3,\"maxTextLength\":5000,\"camelCaseRule\":false,\"maxSymbolRatio\":0.5}}\n")

        let got = try await cfg
        XCTAssertEqual(got.lang, "ja")
        XCTAssertEqual(client.phase, .recording) // the event was not eaten by correlation
    }

    func testDaemonErrorResponseThrows() async {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)

        var patch = ConfigPatch(); patch.lang = "xx"
        async let result: Void = client.setConfig(patch)
        try? await Task.sleep(nanoseconds: 50_000_000)
        transport.push("{\"type\":\"resp\",\"id\":1,\"ok\":false,\"error\":\"unsupported language\"}\n")

        do {
            try await result
            XCTFail("expected throw")
        } catch let e as DaemonClient.ClientError {
            XCTAssertEqual(e, .daemon("unsupported language"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testCloseFailsPendingAndSetsDisconnected() async {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n")

        async let result = client.getConfig()
        try? await Task.sleep(nanoseconds: 50_000_000)
        transport.onClose?(nil)

        do { _ = try await result; XCTFail("expected throw") }
        catch let e as DaemonClient.ClientError { XCTAssertEqual(e, .disconnected) }
        catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(client.phase, .disconnected)
    }

    func testMalformedLineIsSkippedNotFatal() {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        transport.push("garbage\n{\"type\":\"event\",\"name\":\"idle\"}\n")
        XCTAssertEqual(client.phase, .idle)
    }

    func testPhaseChangeCallbackFiresOncePerTransition() {
        let transport = MockTransport()
        let client = DaemonClient(transport: transport)
        var seen: [DaemonClient.Phase] = []
        client.onPhaseChange = { seen.append($0) }

        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n")
        transport.push("{\"type\":\"event\",\"name\":\"idle\"}\n") // duplicate: no callback
        transport.push("{\"type\":\"event\",\"name\":\"recording\"}\n")

        XCTAssertEqual(seen, [.idle, .recording])
    }
}
