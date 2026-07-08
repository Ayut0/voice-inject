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
        return try JSONDecoder().decode(ResponseEnvelope<T>.self, from: rawLine).data
    }
}

private struct ResponseEnvelope<P: Decodable>: Decodable { let data: P }

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

private struct Cmd<P: Encodable>: Encodable {
    let type = "cmd"
    let id: Int64
    let name: String
    let data: P?
}

func encodeCommand(id: Int64, name: String, data: (some Encodable)?) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(Cmd(id: id, name: name, data: data))
    line.append(UInt8(ascii: "\n"))
    return line
}
