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
