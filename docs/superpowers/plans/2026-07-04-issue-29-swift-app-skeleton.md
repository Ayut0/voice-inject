# Swift App Skeleton: Daemon Lifecycle + Settings (Issue #29) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftUI Dock app (`app/` in this repo) that spawns and supervises `voice-inject daemon -managed`, speaks the issue-#28 NDJSON protocol through a single `DaemonClient`, and offers a Settings tab backed by `getConfig`/`setConfig`.

**Architecture:** Swift Package Manager executable (no Xcode project — reviewable text files, built with `swift build`), assembled into `VoiceInject.app` by a shell script that bundles the Go daemon binary inside the app. Layering: `LineBuffer` (NDJSON framing) → `Protocol.swift` (message parsing) → `DaemonClient` (connection + request/response correlation + `@Observable` state, over a swappable `DaemonTransport`) → `AppModel` (process supervision + restart policy) → SwiftUI views. All logic below the views is unit-testable without a socket or a real daemon.

**Tech Stack:** Swift 5.10+, SwiftUI, `@Observable` (macOS 14+ deployment target), Network.framework for the Unix socket, Foundation `Process` for spawning. Zero third-party dependencies.

## Global Constraints

- All Swift code lives under `app/`; the Go module stays untouched by this issue except that the built Go binary is bundled by the packaging script
- Protocol wire shapes exactly match issue #28's plan: events `{"type":"event","name":…}` (single-key discriminated union on `name`), commands `{"type":"cmd","id":N,"name":…,"data":…}`, responses `{"type":"resp","id":N,"ok":…}`
- Config JSON field names exactly match Go `config.Wire`: `lang, model, minRecordMs, maxRecordMs, silenceTimeoutMs, minTextLength, maxTextLength, camelCaseRule, maxSymbolRatio`
- Socket path: `~/Library/Application Support/voice-inject/daemon.sock`
- The daemon is spawned with `-managed` and a stdin pipe held open; app death ⇒ stdin EOF ⇒ daemon exits (contract from #28 Task 7)
- Restart policy: auto-restart once; a second death within 10 s ⇒ stop retrying, surface last stderr lines (spec)
- Regular Dock app (`LSUIElement` = false), personal use, ad-hoc signing
- Tests: `swift test` under `app/`; imperative commit subjects

---

### Task 1: Package scaffold + protocol parsing

**Files:**
- Create: `app/Package.swift`
- Create: `app/Sources/VoiceInject/Protocol.swift`
- Test: `app/Tests/VoiceInjectTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: wire shapes from issue #28
- Produces (used by Tasks 2–7):
  - `enum DaemonEvent: Equatable { case recording, transcribing, idle, transcript(TranscriptPayload), error(stage: String, message: String) }`
  - `struct TranscriptPayload: Codable, Equatable { let text: String; let lang: String; let durationMs: Int64 }`
  - `struct DaemonConfig: Codable, Equatable` — all nine `config.Wire` fields, `var` properties
  - `struct ConfigPatch: Encodable` — all nine fields as Optionals (synthesized Codable omits nils)
  - `struct DaemonResponse: Equatable { let id: Int64; let ok: Bool; let error: String?; let rawLine: Data; func decodePayload<T: Decodable>(_ type: T.Type) throws -> T }`
  - `enum IncomingMessage: Equatable { case event(DaemonEvent), response(DaemonResponse) }`
  - `enum ProtocolError: Error { case malformed(String) }`
  - `func parseLine(_ line: Data) throws -> IncomingMessage`
  - `func encodeCommand(id: Int64, name: String, data: (some Encodable)?) throws -> Data` — one NDJSON line incl. trailing `\n`

- [ ] **Step 1: Create the package manifest**

`app/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceInject",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceInject", path: "Sources/VoiceInject"),
        .testTarget(name: "VoiceInjectTests", dependencies: ["VoiceInject"], path: "Tests/VoiceInjectTests"),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`app/Tests/VoiceInjectTests/ProtocolTests.swift` — golden strings copied verbatim from the #28 plan so both sides are tested against identical bytes:

```swift
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
```

(Note: `encodeCommand` uses `.sortedKeys` so the expected strings are deterministic. Go's `DecodeCommand` doesn't care about key order.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app && swift test`
Expected: FAIL — `Protocol.swift` doesn't exist; compile errors.

- [ ] **Step 4: Write the implementation**

`app/Sources/VoiceInject/Protocol.swift`:

```swift
import Foundation

enum ProtocolError: Error, Equatable {
    case malformed(String)
}

struct TranscriptPayload: Codable, Equatable {
    let text: String
    let lang: String
    let durationMs: Int64
}

enum DaemonEvent: Equatable {
    case recording
    case transcribing
    case idle
    case transcript(TranscriptPayload)
    case error(stage: String, message: String)
}

/// Mirrors Go `config.Wire` exactly — the config file and the
/// getConfig payload share this shape.
struct DaemonConfig: Codable, Equatable {
    var lang: String
    var model: String
    var minRecordMs: Int64
    var maxRecordMs: Int64
    var silenceTimeoutMs: Int64
    var minTextLength: Int
    var maxTextLength: Int
    var camelCaseRule: Bool
    var maxSymbolRatio: Double
}

/// Partial config update; synthesized Encodable omits nil fields, which
/// is exactly the Go ApplyPatch contract.
struct ConfigPatch: Encodable {
    var lang: String?
    var model: String?
    var minRecordMs: Int64?
    var maxRecordMs: Int64?
    var silenceTimeoutMs: Int64?
    var minTextLength: Int?
    var maxTextLength: Int?
    var camelCaseRule: Bool?
    var maxSymbolRatio: Double?
}

struct DaemonResponse: Equatable {
    let id: Int64
    let ok: Bool
    let error: String?
    /// The full NDJSON line, kept so callers can decode `data` as a
    /// concrete type without the envelope knowing every payload.
    let rawLine: Data

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        struct Envelope<P: Decodable>: Decodable { let data: P }
        return try JSONDecoder().decode(Envelope<T>.self, from: rawLine).data
    }
}

enum IncomingMessage: Equatable {
    case event(DaemonEvent)
    case response(DaemonResponse)
}

private struct ErrorPayload: Decodable {
    let stage: String
    let message: String
}

func parseLine(_ line: Data) throws -> IncomingMessage {
    struct Head: Decodable {
        let type: String
        let name: String?
        let id: Int64?
        let ok: Bool?
        let error: String?
    }
    struct DataEnvelope<P: Decodable>: Decodable { let data: P }

    let head: Head
    do {
        head = try JSONDecoder().decode(Head.self, from: line)
    } catch {
        throw ProtocolError.malformed("invalid json: \(error)")
    }

    switch head.type {
    case "event":
        switch head.name {
        case "recording": return .event(.recording)
        case "transcribing": return .event(.transcribing)
        case "idle": return .event(.idle)
        case "transcript":
            let p = try JSONDecoder().decode(DataEnvelope<TranscriptPayload>.self, from: line).data
            return .event(.transcript(p))
        case "error":
            let p = try JSONDecoder().decode(DataEnvelope<ErrorPayload>.self, from: line).data
            return .event(.error(stage: p.stage, message: p.message))
        default:
            throw ProtocolError.malformed("unknown event name: \(head.name ?? "nil")")
        }
    case "resp":
        guard let id = head.id, let ok = head.ok else {
            throw ProtocolError.malformed("resp missing id/ok")
        }
        return .response(DaemonResponse(id: id, ok: ok, error: head.error, rawLine: line))
    default:
        throw ProtocolError.malformed("unexpected type: \(head.type)")
    }
}

func encodeCommand(id: Int64, name: String, data: (some Encodable)?) throws -> Data {
    struct Cmd<P: Encodable>: Encodable {
        let type = "cmd"
        let id: Int64
        let name: String
        let data: P?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(Cmd(id: id, name: name, data: data))
    line.append(UInt8(ascii: "\n"))
    return line
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd app && swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Package.swift app/Sources/VoiceInject/Protocol.swift app/Tests/VoiceInjectTests/ProtocolTests.swift
git commit -m "Add Swift package with daemon protocol parsing"
```

---

### Task 2: NDJSON line framing (`LineBuffer`)

**Files:**
- Create: `app/Sources/VoiceInject/LineBuffer.swift`
- Test: `app/Tests/VoiceInjectTests/LineBufferTests.swift`

**Interfaces:**
- Produces (used by Task 3): `struct LineBuffer { mutating func append(_ chunk: Data) -> [Data] }` — returns complete lines without their trailing `\n`; retains partial tail

- [ ] **Step 1: Write the failing test**

`app/Tests/VoiceInjectTests/LineBufferTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class LineBufferTests: XCTestCase {
    func testSplitsChunksIntoLines() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("{\"a\":1}\n{\"b\":".utf8)).map(str), ["{\"a\":1}"])
        XCTAssertEqual(buf.append(Data("2}\n".utf8)).map(str), ["{\"b\":2}"])
        XCTAssertEqual(buf.append(Data("\n\n".utf8)).map(str), ["", ""])
        XCTAssertEqual(buf.append(Data("tail-without-newline".utf8)), [])
        XCTAssertEqual(buf.append(Data("\n".utf8)).map(str), ["tail-without-newline"])
    }

    func testManyLinesInOneChunk() {
        var buf = LineBuffer()
        let lines = buf.append(Data("1\n2\n3\n".utf8)).map(str)
        XCTAssertEqual(lines, ["1", "2", "3"])
    }

    private func str(_ d: Data) -> String { String(data: d, encoding: .utf8)! }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test`
Expected: FAIL — `LineBuffer` undefined.

- [ ] **Step 3: Write the implementation**

`app/Sources/VoiceInject/LineBuffer.swift`:

```swift
import Foundation

/// Accumulates raw socket chunks and yields complete NDJSON lines.
struct LineBuffer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/LineBuffer.swift app/Tests/VoiceInjectTests/LineBufferTests.swift
git commit -m "Add NDJSON line framing buffer"
```

---

### Task 3: `DaemonClient` over a swappable transport

**Files:**
- Create: `app/Sources/VoiceInject/DaemonTransport.swift`
- Create: `app/Sources/VoiceInject/DaemonClient.swift`
- Test: `app/Tests/VoiceInjectTests/DaemonClientTests.swift`

**Interfaces:**
- Consumes: `parseLine`, `encodeCommand`, `LineBuffer`, protocol types (Tasks 1–2)
- Produces (**the contract issues #30/#31/#32 build against**):

```swift
protocol DaemonTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }   // raw chunks
    var onClose: ((Error?) -> Void)? { get set }
    func send(_ data: Data)
    func close()
}

@Observable @MainActor final class DaemonClient {
    enum Phase: Equatable { case disconnected, idle, recording, transcribing }
    struct ErrorInfo: Equatable { let stage: String; let message: String; let at: Date }

    private(set) var phase: Phase          // #30's HUD observes this
    private(set) var lastError: ErrorInfo? // #30 flashes it, #32 lists it
    var onTranscript: ((TranscriptPayload) -> Void)?           // #31 appends history
    var onErrorEvent: ((_ stage: String, _ message: String) -> Void)? // #32 checklist

    init(transport: DaemonTransport)
    func send<T: Decodable>(_ name: String, data: (some Encodable)?, expecting: T.Type) async throws -> T
    func send(_ name: String, data: (some Encodable)?) async throws  // ok/err only
    func getConfig() async throws -> DaemonConfig
    func setConfig(_ patch: ConfigPatch) async throws
    func handleClose(_ error: Error?)      // sets phase = .disconnected, fails pending requests

    enum ClientError: Error, Equatable { case daemon(String), disconnected }
}
```

- [ ] **Step 1: Write the failing test**

`app/Tests/VoiceInjectTests/DaemonClientTests.swift`:

```swift
import XCTest
@testable import VoiceInject

@MainActor
final class MockTransport: DaemonTransport {
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test`
Expected: FAIL — `DaemonTransport`, `DaemonClient` undefined.

- [ ] **Step 3: Write the implementation**

`app/Sources/VoiceInject/DaemonTransport.swift`:

```swift
import Foundation

/// Byte-level transport to the daemon. Production: NWConnection over
/// the Unix socket (Task 4). Tests: MockTransport.
protocol DaemonTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func send(_ data: Data)
    func close()
}
```

`app/Sources/VoiceInject/DaemonClient.swift`:

```swift
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

    /// Hook for the History feature (issue #31).
    var onTranscript: ((TranscriptPayload) -> Void)?
    /// Hook for the first-run checklist (issue #32).
    var onErrorEvent: ((_ stage: String, _ message: String) -> Void)?

    private let transport: DaemonTransport
    private var lines = LineBuffer()
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<DaemonResponse, Error>] = [:]

    init(transport: DaemonTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] chunk in
            Task { @MainActor in self?.receive(chunk) }
        }
        transport.onClose = { [weak self] error in
            Task { @MainActor in self?.handleClose(error) }
        }
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
        case .event(.idle): phase = .idle
        case .event(.recording): phase = .recording
        case .event(.transcribing): phase = .transcribing
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
        phase = .disconnected
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting {
            cont.resume(throwing: ClientError.disconnected)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && swift test`
Expected: PASS. Note: `request()` throws `ClientError.daemon` *after* correlation, so the error-response test passes; the `resp.ok` check happens inside `request`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/VoiceInject/DaemonTransport.swift app/Sources/VoiceInject/DaemonClient.swift app/Tests/VoiceInjectTests/DaemonClientTests.swift
git commit -m "Add DaemonClient with request correlation over swappable transport"
```

---

### Task 4: Unix-socket transport (Network.framework)

**Files:**
- Create: `app/Sources/VoiceInject/UnixSocketTransport.swift`

**Interfaces:**
- Consumes: `DaemonTransport` (Task 3)
- Produces (used by Task 6): `final class UnixSocketTransport: DaemonTransport { init(path: String); func connect() }`

No unit test — this is the thin I/O adapter; it's exercised by the manual acceptance in Task 7 (and every day thereafter). Keep ALL logic out of it.

- [ ] **Step 1: Write the implementation**

`app/Sources/VoiceInject/UnixSocketTransport.swift`:

```swift
import Foundation
import Network

/// NWConnection adapter over the daemon's Unix socket.
final class UnixSocketTransport: DaemonTransport {
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

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
                self?.onClose?(error)
            case .cancelled:
                self?.onClose?(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.onReceive?(data)
            }
            if let error {
                self?.onClose?(error)
                return
            }
            if isComplete {
                self?.onClose?(nil)
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
```

- [ ] **Step 2: Compile**

Run: `cd app && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/VoiceInject/UnixSocketTransport.swift
git commit -m "Add Unix socket transport via Network.framework"
```

---

### Task 5: Daemon process supervision (`DaemonProcess` + restart policy)

**Files:**
- Create: `app/Sources/VoiceInject/DaemonProcess.swift`
- Create: `app/Sources/VoiceInject/RestartPolicy.swift`
- Test: `app/Tests/VoiceInjectTests/RestartPolicyTests.swift`

**Interfaces:**
- Produces (used by Task 6):
  - `final class DaemonProcess { init(binaryURL: URL); var onTermination: (@Sendable (Int32, String) -> Void)?; func start() throws; func stop(); var isRunning: Bool }` — spawns `voice-inject daemon -managed` with a held-open stdin pipe; captures a rolling tail of stderr (last 4 KiB) handed to `onTermination`
  - `struct RestartPolicy { mutating func decide(now: Date) -> Action; enum Action: Equatable { case restart, giveUp } }` — pure, injectable-clock logic: first death → `.restart`; another death within 10 s of that restart → `.giveUp`; death later than 10 s after a restart counts as a fresh first death

- [ ] **Step 1: Write the failing restart-policy test**

`app/Tests/VoiceInjectTests/RestartPolicyTests.swift`:

```swift
import XCTest
@testable import VoiceInject

final class RestartPolicyTests: XCTestCase {
    func testFirstDeathRestarts() {
        var p = RestartPolicy()
        XCTAssertEqual(p.decide(now: t(0)), .restart)
    }

    func testSecondDeathWithin10sGivesUp() {
        var p = RestartPolicy()
        XCTAssertEqual(p.decide(now: t(0)), .restart)
        XCTAssertEqual(p.decide(now: t(5)), .giveUp)
    }

    func testDeathAfter10sCountsAsFresh() {
        var p = RestartPolicy()
        XCTAssertEqual(p.decide(now: t(0)), .restart)
        XCTAssertEqual(p.decide(now: t(11)), .restart)
        XCTAssertEqual(p.decide(now: t(15)), .giveUp)
    }

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && swift test`
Expected: FAIL — `RestartPolicy` undefined.

- [ ] **Step 3: Implement `RestartPolicy`**

`app/Sources/VoiceInject/RestartPolicy.swift`:

```swift
import Foundation

/// "Restart once" policy from the spec: one automatic restart; a second
/// death within `window` of that restart means give up (no crash loop).
struct RestartPolicy {
    enum Action: Equatable { case restart, giveUp }

    private let window: TimeInterval
    private var lastRestartAt: Date?

    init(window: TimeInterval = 10) {
        self.window = window
    }

    mutating func decide(now: Date) -> Action {
        if let last = lastRestartAt, now.timeIntervalSince(last) < window {
            return .giveUp
        }
        lastRestartAt = now
        return .restart
    }
}
```

- [ ] **Step 4: Run test to verify it passes, then implement `DaemonProcess`**

Run: `cd app && swift test` → PASS. Then create `app/Sources/VoiceInject/DaemonProcess.swift`:

```swift
import Foundation

/// Spawns and supervises the Go daemon as a child process. The stdin
/// pipe is held open for the child's lifetime: if this app dies for any
/// reason, the pipe closes and `-managed` makes the daemon exit.
final class DaemonProcess {
    var onTermination: (@Sendable (Int32, String) -> Void)?

    private let binaryURL: URL
    private var process: Process?
    private var stdinPipe: Pipe?
    private let stderrTail = StderrTail()

    init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = ["daemon", "-managed"]

        let stdin = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        p.standardOutput = FileHandle.nullDevice

        let tail = stderrTail
        stderr.fileHandleForReading.readabilityHandler = { handle in
            tail.append(handle.availableData)
        }
        p.terminationHandler = { [weak self] proc in
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.onTermination?(proc.terminationStatus, tail.snapshot())
        }

        try p.run()
        process = p
        stdinPipe = stdin // hold the reference; never write, never close while running
    }

    func stop() {
        // Closing stdin asks the managed daemon to exit gracefully.
        try? stdinPipe?.fileHandleForWriting.close()
        process?.waitUntilExit()
        process = nil
        stdinPipe = nil
    }
}

/// Thread-safe rolling buffer of the last 4 KiB of stderr.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 4096

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap { data.removeFirst(data.count - cap) }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 5: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/VoiceInject/DaemonProcess.swift app/Sources/VoiceInject/RestartPolicy.swift app/Tests/VoiceInjectTests/RestartPolicyTests.swift
git commit -m "Add daemon process supervision with bounded restart policy"
```

---

### Task 6: App model, entry point, Settings tab

**Files:**
- Create: `app/Sources/VoiceInject/AppModel.swift`
- Create: `app/Sources/VoiceInject/VoiceInjectApp.swift`
- Create: `app/Sources/VoiceInject/MainWindow.swift`
- Create: `app/Sources/VoiceInject/SettingsView.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–5
- Produces (**used by issues #30/#31/#32**):
  - `@Observable @MainActor final class AppModel { let client: DaemonClient; enum DaemonStatus: Equatable { case starting, running, restarting, failed(stderr: String) }; private(set) var daemonStatus: DaemonStatus; func startDaemon(); func restartDaemon(); static func socketPath() -> String; static func daemonBinaryURL() -> URL }`
  - `MainWindow` hosts a `TabView`; #31 adds a History tab, #32 adds a Setup tab to it

- [ ] **Step 1: Implement `AppModel`**

`app/Sources/VoiceInject/AppModel.swift`:

```swift
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
    private(set) var daemonStatus: DaemonStatus = .starting

    private var process: DaemonProcess?
    private var policy = RestartPolicy()

    init() {
        let transport = UnixSocketTransport(path: Self.socketPath())
        client = DaemonClient(transport: transport)
        // Transport connects in startDaemon(), after the child binds the socket.
        self.pendingTransport = transport
    }
    private var pendingTransport: UnixSocketTransport?

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
}
```

This needs one addition to `DaemonClient` (append to the class from Task 3):

```swift
    // MARK: - Reconnection support (AppModel owns transport lifecycle)
    private(set) var transportRef: DaemonTransport?

    func rebind(transport: DaemonTransport) {
        handleClose(nil) // fail pending requests, phase = .disconnected
        transportRef = transport
        transport.onReceive = { [weak self] chunk in
            Task { @MainActor in self?.receive(chunk) }
        }
        transport.onClose = { [weak self] error in
            Task { @MainActor in self?.handleClose(error) }
        }
    }
```

…and change `DaemonClient.init`/`request` to use a settable transport: replace `private let transport: DaemonTransport` with `private var transport: DaemonTransport` and have `rebind` assign it. Update `init` to call `rebind(transport:)` instead of duplicating the wiring.

- [ ] **Step 2: Implement the app entry and windows**

`app/Sources/VoiceInject/VoiceInjectApp.swift`:

```swift
import SwiftUI

@main
struct VoiceInjectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("VoiceInject") {
            MainWindow()
                .environment(model)
                .task { model.startDaemon() }
        }
    }
}
```

`app/Sources/VoiceInject/MainWindow.swift`:

```swift
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            TabView {
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                // Issue #31 adds History here; issue #32 adds Setup.
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.daemonStatus {
        case .running:
            statusRow("Daemon running — hold ⌥Space to dictate", color: .green)
        case .starting:
            statusRow("Starting daemon…", color: .orange)
        case .restarting:
            statusRow("Daemon stopped unexpectedly — restarting…", color: .orange)
        case .failed(let stderr):
            VStack(alignment: .leading, spacing: 8) {
                statusRow("Daemon failed to stay running", color: .red)
                if !stderr.isEmpty {
                    ScrollView {
                        Text(stderr)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                Button("Restart Daemon") { model.restartDaemon() }
            }
            .padding()
        }
    }

    private func statusRow(_ text: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
            Spacer()
        }
        .padding(8)
    }
}
```

`app/Sources/VoiceInject/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var config: DaemonConfig?
    @State private var loadError: String?
    @State private var saveState: SaveState = .idle

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        Form {
            if var cfg = config {
                Picker("Language", selection: Binding(
                    get: { cfg.lang },
                    set: { cfg.lang = $0; config = cfg }
                )) {
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                }

                TextField("Whisper model path", text: Binding(
                    get: { cfg.model },
                    set: { cfg.model = $0; config = cfg }
                ))
                .font(.system(.body, design: .monospaced))

                Stepper("Max recording: \(cfg.maxRecordMs / 1000)s",
                        value: Binding(
                            get: { cfg.maxRecordMs },
                            set: { cfg.maxRecordMs = $0; config = cfg }
                        ), in: 5_000...120_000, step: 5_000)

                Stepper("Silence timeout: \(cfg.silenceTimeoutMs / 1000)s",
                        value: Binding(
                            get: { cfg.silenceTimeoutMs },
                            set: { cfg.silenceTimeoutMs = $0; config = cfg }
                        ), in: 1_000...10_000, step: 1_000)

                HStack {
                    Button("Save") { save(cfg) }
                        .disabled(saveState == .saving)
                    switch saveState {
                    case .saved: Text("Saved ✓").foregroundStyle(.green)
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    default: EmptyView()
                    }
                }
            } else if let loadError {
                Text("Could not load config: \(loadError)").foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading config…")
            }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            config = try await model.client.getConfig()
        } catch {
            loadError = "\(error)"
        }
    }

    private func save(_ cfg: DaemonConfig) {
        saveState = .saving
        Task {
            do {
                var patch = ConfigPatch()
                patch.lang = cfg.lang
                patch.model = cfg.model
                patch.maxRecordMs = cfg.maxRecordMs
                patch.silenceTimeoutMs = cfg.silenceTimeoutMs
                try await model.client.setConfig(patch)
                saveState = .saved
            } catch {
                saveState = .failed("\(error)")
            }
        }
    }
}
```

- [ ] **Step 3: Compile and run all tests**

Run: `cd app && swift build && swift test`
Expected: builds clean, all tests PASS (fix the `DaemonClient` transport refactor fallout from Step 1 if any — the Task 3 tests must still pass unchanged except constructing via `init(transport:)`).

- [ ] **Step 4: Commit**

```bash
git add app/Sources/VoiceInject/AppModel.swift app/Sources/VoiceInject/VoiceInjectApp.swift app/Sources/VoiceInject/MainWindow.swift app/Sources/VoiceInject/SettingsView.swift app/Sources/VoiceInject/DaemonClient.swift
git commit -m "Add app model, entry point, and Settings tab"
```

---

### Task 7: App bundle packaging + manual acceptance

**Files:**
- Create: `app/make-app.sh`
- Create: `app/Info.plist`
- Modify: `.gitignore` (add `app/.build` and `app/VoiceInject.app`)

- [ ] **Step 1: Create `app/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.yuto.voiceinject</string>
    <key>CFBundleName</key>
    <string>VoiceInject</string>
    <key>CFBundleExecutable</key>
    <string>VoiceInjectApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceInject records your voice while you hold the hotkey so it can transcribe it locally.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>VoiceInject pastes transcribed text into the frontmost app.</string>
</dict>
</plist>
```

- [ ] **Step 2: Create `app/make-app.sh`**

```sh
#!/bin/sh
# Assembles VoiceInject.app: SwiftUI app + bundled Go daemon.
set -eu

cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)

echo "Building Go daemon..."
(cd "$REPO_ROOT" && go build ./cmd/voice-inject)

echo "Building Swift app..."
swift build -c release

APP=VoiceInject.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/VoiceInject "$APP/Contents/MacOS/VoiceInjectApp"
cp "$REPO_ROOT/voice-inject" "$APP/Contents/MacOS/voice-inject"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
```

Then: `chmod +x app/make-app.sh`, and append to `.gitignore`:

```
app/.build
app/VoiceInject.app
```

- [ ] **Step 3: Build the bundle and grant permissions**

```bash
app/make-app.sh && open app/VoiceInject.app
```

First run: grant Accessibility and Microphone to **VoiceInject** in System Settings › Privacy & Security (the daemon inherits the app's permission context as its child).

- [ ] **Step 4: Manual acceptance (issue #29 criteria)**

1. Launch the app → status banner turns green "Daemon running"; `pgrep -fl "voice-inject daemon"` shows one process with `-managed`.
2. Hold ⌥Space in another app, speak, release → text pastes (pipeline unchanged through the app).
3. Settings shows the live config; change language to Japanese, Save → `cat ~/Library/Application\ Support/voice-inject/config.json` shows `"lang": "ja"`; quit and relaunch the app → Settings still shows Japanese.
4. `kill <daemon pid>` → banner flips to "restarting…", then green again; new pid visible. `kill` the new one within 10 s → banner shows the failure state with stderr and a Restart button; the button recovers.
5. Force-quit the app (⌥⌘Esc) → within ~1 s `pgrep -fl "voice-inject daemon"` shows nothing (stdin-EOF contract).
6. `swift test` under `app/` passes; `go test ./...` at the repo root still passes.

- [ ] **Step 5: Commit**

```bash
git add app/make-app.sh app/Info.plist .gitignore
git commit -m "Add app bundle packaging script"
```

---

## Self-Review (completed at plan time)

- **Spec/issue coverage:** spawn+supervise (T5/T6), ~2 s socket retry is covered by the 300 ms delayed connect plus NWConnection's own connect behavior — if this proves flaky in T7, add one retry loop in `AppModel.startDaemon`; restart-once policy (T5, pure and tested); stdin-EOF (T5 pipe held + #28's `-managed`); `DaemonClient` parses all shapes (T1/T3 tests); Settings read/write + persistence across restart (T6/T7-step 3); unit tests for parsing with canned input (T1/T3).
- **Type consistency:** `DaemonConfig` fields = Go `config.Wire` JSON names; `Phase` in Task 3 matches what `MainWindow`/#30 consume; `AppModel.daemonStatus` cases used verbatim in `MainWindow`; the Task 6 `rebind` refactor is called out where it modifies Task 3 code.
- **Known simplification:** `pendingTransport` double-bookkeeping in `AppModel` is v1-pragmatic; if it grows warts during #30–#32, fold transport ownership fully into `DaemonClient`.
