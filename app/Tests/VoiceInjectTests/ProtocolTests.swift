import XCTest
@testable import VoiceInject

final class ProtocolTests: XCTestCase {
    private func parse(_ s: String) throws -> IncomingMessage {
        try parseLine(Data(s.utf8))
    }

    func testParsesStateEvents() throws {
        XCTAssertEqual(try parse(#"{"type":"event","name":"recording"}"#), .event(.recording))
        XCTAssertEqual(try parse(#"{"type":"event","name":"transcribing"}"#), .event(.transcribing))
        XCTAssertEqual(try parse(#"{"type":"event","name":"idle"}"#), .event(.idle))
    }

    func testParsesTranscriptEvent() throws {
        let msg = try parse(#"{"type":"event","name":"transcript","data":{"text":"hello world","lang":"en","durationMs":2300}}"#)
        XCTAssertEqual(msg, .event(.transcript(TranscriptPayload(text: "hello world", lang: "en", durationMs: 2300))))
    }

    func testParsesErrorEvent() throws {
        let msg = try parse(#"{"type":"event","name":"error","data":{"stage":"transcribe","message":"model file not found"}}"#)
        XCTAssertEqual(msg, .event(.error(stage: "transcribe", message: "model file not found")))
    }

    func testParsesOKResponseWithPayload() throws {
        let line = #"{"type":"resp","id":1,"ok":true,"data":{"lang":"en","model":"/m.bin","minRecordMs":700,"maxRecordMs":60000,"silenceTimeoutMs":4000,"minTextLength":3,"maxTextLength":5000,"camelCaseRule":false,"maxSymbolRatio":0.5}}"#
        guard case .response(let resp) = try parse(line) else { return XCTFail("not a response") }
        XCTAssertEqual(resp.id, 1)
        XCTAssertTrue(resp.ok)
        let cfg = try resp.decodePayload(DaemonConfig.self)
        XCTAssertEqual(cfg.lang, "en")
        XCTAssertEqual(cfg.maxRecordMs, 60000)
    }

    func testParsesErrorResponse() throws {
        guard case .response(let resp) = try parse(#"{"type":"resp","id":4,"ok":false,"error":"unsupported language: \"xx\""}"#) else {
            return XCTFail("not a response")
        }
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, #"unsupported language: "xx""#)
    }

    func testRejectsGarbageAndUnknownShapes() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse(#"{"type":"cmd","id":1,"name":"status"}"#)) // cmd is outbound-only
        XCTAssertThrowsError(try parse(#"{"type":"event","name":"neverHeardOfIt"}"#))
    }

    func testEncodeCommandShapes() throws {
        let noData = try encodeCommand(id: 1, name: "status", data: Optional<ConfigPatch>.none)
        XCTAssertEqual(String(data: noData, encoding: .utf8), #"{"id":1,"name":"status","type":"cmd"}"# + "\n")

        var patch = ConfigPatch()
        patch.lang = "ja"
        let withData = try encodeCommand(id: 2, name: "setConfig", data: patch)
        XCTAssertEqual(String(data: withData, encoding: .utf8), #"{"data":{"lang":"ja"},"id":2,"name":"setConfig","type":"cmd"}"# + "\n")
    }
}
