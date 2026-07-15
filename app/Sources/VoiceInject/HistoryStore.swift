import Foundation
import Observation

struct HistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    let text: String
    let lang: String
    let durationMs: Int64

    init(id: UUID = UUID(), at: Date, text: String, lang: String, durationMs: Int64) {
        self.id = id
        self.at = at
        self.text = text
        self.lang = lang
        self.durationMs = durationMs
    }

    // ISO8601 truncates to whole seconds, so `at` cannot serve as the
    // identity; a missing id (line written by an older build) gets a
    // fresh UUID on load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        at = try c.decode(Date.self, forKey: .at)
        text = try c.decode(String.self, forKey: .text)
        lang = try c.decode(String.self, forKey: .lang)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
    }
}

/// Owns the transcript history JSONL file. The daemon never writes
/// history — entries come only from onTranscript events.
@Observable @MainActor
final class HistoryStore {
    private static let enabledKey = "historyRecordingEnabled"

    private(set) var entries: [HistoryEntry] = []

    var recordingEnabled: Bool {
        didSet { defaults.set(recordingEnabled, forKey: Self.enabledKey) }
    }

    private let fileURL: URL
    private let defaults: UserDefaults

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/voice-inject/history.jsonl")
    }

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.recordingEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
    }

    func record(_ payload: TranscriptPayload, at date: Date = Date()) {
        guard recordingEnabled else { return }
        let entry = HistoryEntry(at: date, text: payload.text, lang: payload.lang, durationMs: payload.durationMs)
        entries.insert(entry, at: 0)
        appendToFile(entry)
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = Self.decoder()
        var loaded: [HistoryEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) else {
                continue // corrupt line: skip, never fatal
            }
            loaded.append(entry)
        }
        entries = loaded.reversed() // file is oldest-first; UI is newest-first
    }

    private func appendToFile(_ entry: HistoryEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            NSLog("[HistoryStore] append failed: \(error)")
        }
    }
}
