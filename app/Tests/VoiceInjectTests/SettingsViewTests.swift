import XCTest
@testable import VoiceInject

final class ModelDisplayNameTests: XCTestCase {
    func testKnownGgmlNames() {
        XCTAssertEqual(modelDisplayName("/x/ggml-base.bin"), "base")
        XCTAssertEqual(modelDisplayName("/x/ggml-base.en.bin"), "base (English)")
        XCTAssertEqual(modelDisplayName("/x/ggml-large-v3.bin"), "large-v3")
    }

    func testFallsBackToFilenameForNonGgmlNames() {
        XCTAssertEqual(modelDisplayName("/x/my-custom-model.bin"), "my-custom-model")
        XCTAssertEqual(modelDisplayName("/m.bin"), "m")
    }
}
