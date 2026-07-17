import XCTest
@testable import VoiceInject

final class HistoryClearDisabledTests: XCTestCase {
    func testDisabledWhenRecordingOffEvenWithEntries() {
        XCTAssertTrue(historyClearDisabled(recordingEnabled: false, entriesIsEmpty: false))
    }

    func testDisabledWhenEntriesEmptyEvenWhileRecording() {
        XCTAssertTrue(historyClearDisabled(recordingEnabled: true, entriesIsEmpty: true))
    }

    func testEnabledWhenRecordingOnAndEntriesPresent() {
        XCTAssertFalse(historyClearDisabled(recordingEnabled: true, entriesIsEmpty: false))
    }
}
