import XCTest
@testable import VoiceInject

final class HUDStateTests: XCTestCase {
    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    func testHappyPathDictation() {
        var s = HUDState()
        XCTAssertEqual(s.display, .hidden)

        s.phaseChanged(.recording, now: t(0))
        XCTAssertEqual(s.display, .recording(started: t(0)))

        s.phaseChanged(.transcribing, now: t(3))
        XCTAssertEqual(s.display, .working)

        s.phaseChanged(.idle, now: t(5))
        XCTAssertEqual(s.display, .hidden)
    }

    func testErrorFlashSurvivesFollowingIdle() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.phaseChanged(.transcribing, now: t(3))
        s.errorOccurred(message: "model file not found", now: t(4))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // The daemon publishes idle right after the error; flash must persist.
        s.phaseChanged(.idle, now: t(4.1))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // Not yet expired.
        s.tick(now: t(5.9))
        XCTAssertEqual(s.display, .errorFlash(message: "model file not found", shownAt: t(4)))

        // Expired.
        s.tick(now: t(6.01))
        XCTAssertEqual(s.display, .hidden)
    }

    func testIdleAfterFlashExpiryHides() {
        var s = HUDState()
        s.errorOccurred(message: "x", now: t(0))
        s.phaseChanged(.idle, now: t(3)) // flash already expired at idle time
        XCTAssertEqual(s.display, .hidden)
    }

    func testNewRecordingReplacesErrorFlash() {
        var s = HUDState()
        s.errorOccurred(message: "x", now: t(0))
        s.phaseChanged(.recording, now: t(1))
        XCTAssertEqual(s.display, .recording(started: t(1)))
    }

    func testDisconnectedHides() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.phaseChanged(.disconnected, now: t(1))
        XCTAssertEqual(s.display, .hidden)
    }

    func testTickIsNoOpOutsideErrorFlash() {
        var s = HUDState()
        s.phaseChanged(.recording, now: t(0))
        s.tick(now: t(100))
        XCTAssertEqual(s.display, .recording(started: t(0)))
    }
}
