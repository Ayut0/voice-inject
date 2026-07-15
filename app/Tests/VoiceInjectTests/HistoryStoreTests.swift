import XCTest
@testable import VoiceInject

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        suiteName = "HistoryStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName) // no plist litter
    }

    private func payload(_ text: String) -> TranscriptPayload {
        TranscriptPayload(text: text, lang: "en", durationMs: 1200)
    }

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    func testRecordAppendsNewestFirstAndPersists() throws {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("first"), at: t(0))
        store.record(payload("second"), at: t(10))

        XCTAssertEqual(store.entries.map(\.text), ["second", "first"])

        // A fresh store (app restart) loads the same entries.
        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.text), ["second", "first"])
        XCTAssertEqual(reloaded.entries[1].durationMs, 1200)
        XCTAssertEqual(reloaded.entries[1].lang, "en")
    }

    func testSameSecondEntriesKeepDistinctIDsAcrossReload() {
        // ISO8601 truncates to whole seconds; ids must not collide.
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("a"), at: t(0))
        store.record(payload("b"), at: t(0.5))

        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(Set(reloaded.entries.map(\.id)).count, 2)
    }

    func testCorruptLinesAreSkipped() throws {
        let good = #"{"at":"2026-07-04T12:00:00Z","text":"kept","lang":"en","durationMs":900}"#
        try Data("not json\n\(good)\n{broken\n".utf8).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.entries.map(\.text), ["kept"])
    }

    func testMissingFileMeansEmptyHistory() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.entries, [])
    }

    func testDisabledRecordingIsNoOp() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.recordingEnabled = false
        store.record(payload("secret"), at: t(0))

        XCTAssertEqual(store.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The toggle persists across restarts.
        let reloaded = HistoryStore(fileURL: fileURL, defaults: defaults)
        XCTAssertFalse(reloaded.recordingEnabled)
    }

    func testClearRemovesEntriesAndFile() {
        let store = HistoryStore(fileURL: fileURL, defaults: defaults)
        store.record(payload("bye"), at: t(0))
        store.clear()
        XCTAssertEqual(store.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
