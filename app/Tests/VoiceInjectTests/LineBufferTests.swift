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
